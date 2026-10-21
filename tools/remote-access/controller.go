package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const defaultRemoteDir = "/etc/stargate-remote"

type serverDevice struct {
	ID              string        `json:"id"`
	Role            string        `json:"role"`
	Token           string        `json:"token"`
	Enabled         bool          `json:"enabled"`
	Report          Report        `json:"report"`
	LastSeen        int64         `json:"last_seen"`
	AllowedVisitors []string      `json:"allowed_visitors,omitempty"`
	Capabilities    *Capabilities `json:"capabilities,omitempty"`
}

type serverEnrollment struct {
	DeviceID        string        `json:"device_id"`
	Role            string        `json:"role"`
	ExpiresAt       int64         `json:"expires_at"`
	AllowedVisitors []string      `json:"allowed_visitors,omitempty"`
	Capabilities    *Capabilities `json:"capabilities,omitempty"`
	Version         int           `json:"version,omitempty"`
}

type serverState struct {
	Schema       int                         `json:"schema"`
	Revision     uint64                      `json:"revision"`
	Node         Node                        `json:"node"`
	Listen       string                      `json:"listen"`
	PluginListen string                      `json:"plugin_listen"`
	PluginPath   string                      `json:"plugin_path"`
	FRPPort      int                         `json:"frp_port"`
	FRPToken     string                      `json:"frp_token"`
	AdminToken   string                      `json:"admin_token"`
	Certificate  string                      `json:"certificate"`
	Devices      map[string]serverDevice     `json:"devices"`
	Enrollments  map[string]serverEnrollment `json:"enrollments"`
	Mappings     map[string]Mapping          `json:"mappings"`
	Format       int                         `json:"format,omitempty"`
	Transport    Transport                   `json:"transport"`
	Services     map[string]Service          `json:"services"`
	Grants       map[string]Grant            `json:"grants"`
	Bindings     map[string]Binding          `json:"bindings"`
}

type controller struct {
	mu    sync.Mutex
	dir   string
	state serverState
	now   func() time.Time
}

func newFlags(name string) *flag.FlagSet {
	f := flag.NewFlagSet(name, flag.ContinueOnError)
	f.SetOutput(io.Discard)
	return f
}

func ServerInit(args []string) error {
	f := newFlags("server-init")
	dir := f.String("dir", defaultRemoteDir, "private state directory")
	nodeFile := f.String("node-file", "", "AnyTLS node JSON")
	listen := f.String("listen", "127.0.0.1:17443", "controller TLS listener")
	pluginListen := f.String("plugin-listen", "127.0.0.1:17444", "frp HTTP plugin listener")
	frpPort := f.Int("frp-port", 17000, "frps loopback port")
	transportID := f.String("transport-id", "default", "fixed AnyTLS transport identifier")
	transportName := f.String("transport-name", "server", "fixed AnyTLS transport name")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || *nodeFile == "" {
		return errors.New("server-init requires --node-file")
	}
	if validateID(*transportID) != nil || *transportName == "" || len(*transportName) > 128 {
		return errors.New("invalid transport metadata")
	}
	if err := requireLoopback(*listen); err != nil {
		return err
	}
	if err := requireLoopback(*pluginListen); err != nil {
		return err
	}
	if *frpPort < 1024 || *frpPort > 65535 {
		return errors.New("invalid frp port")
	}
	_, controlPort, _ := net.SplitHostPort(*listen)
	_, pluginPort, _ := net.SplitHostPort(*pluginListen)
	if controlPort == "0" || pluginPort == "0" || controlPort == pluginPort || controlPort == fmt.Sprint(*frpPort) || pluginPort == fmt.Sprint(*frpPort) {
		return errors.New("listeners need distinct nonzero ports")
	}
	var node Node
	if err := readJSON(*nodeFile, &node); err != nil {
		return err
	}
	if err := validateNode(node); err != nil {
		return err
	}
	absolute, err := filepath.Abs(*dir)
	if err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(absolute, "server.json")); err == nil {
		return errors.New("server already initialized")
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(absolute, 0700); err != nil {
		return err
	}
	if err := os.Chmod(absolute, 0700); err != nil {
		return err
	}
	cert, key, err := controllerCertificate()
	if err != nil {
		return err
	}
	state := serverState{
		Schema: SchemaVersion, Revision: 1, Node: node, Listen: *listen,
		PluginListen: *pluginListen, PluginPath: "/frp/" + randomToken(),
		FRPPort: *frpPort, FRPToken: randomToken(), AdminToken: randomToken(),
		Certificate: string(cert), Devices: map[string]serverDevice{},
		Enrollments: map[string]serverEnrollment{}, Mappings: map[string]Mapping{},
		Format: ServiceFormat, Transport: Transport{ID: *transportID, Name: *transportName}, Services: map[string]Service{}, Grants: map[string]Grant{}, Bindings: map[string]Binding{},
	}
	if err := atomicFile(filepath.Join(absolute, "server.crt"), cert, 0600); err != nil {
		return err
	}
	if err := atomicFile(filepath.Join(absolute, "server.key"), key, 0600); err != nil {
		return err
	}
	if err := atomicFile(filepath.Join(absolute, "admin.token"), []byte(state.AdminToken+"\n"), 0600); err != nil {
		return err
	}
	if err := atomicJSON(filepath.Join(absolute, "frps.json"), frpsConfig(absolute, state)); err != nil {
		return err
	}
	return atomicJSON(filepath.Join(absolute, "server.json"), state)
}

func frpsConfig(dir string, state serverState) map[string]any {
	return map[string]any{
		"bindAddr": "127.0.0.1", "bindPort": state.FRPPort, "proxyBindAddr": "127.0.0.1",
		"auth":        map[string]any{"method": "token", "token": state.FRPToken, "additionalScopes": []string{"HeartBeats", "NewWorkConns"}},
		"transport":   map[string]any{"tls": map[string]any{"force": true, "certFile": filepath.Join(dir, "server.crt"), "keyFile": filepath.Join(dir, "server.key")}},
		"httpPlugins": []any{map[string]any{"name": "stargate-device-authorization", "addr": state.PluginListen, "path": state.PluginPath, "ops": []string{"Login", "NewProxy", "Ping", "NewWorkConn", "NewUserConn"}}},
		"log":         map[string]any{"to": "console", "level": "warn", "disablePrintColor": true},
	}
}

func PrepareServer(args []string) error {
	f := newFlags("prepare-server")
	dir := f.String("dir", defaultRemoteDir, "private state directory")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || !filepath.IsAbs(*dir) {
		return errors.New("prepare-server requires an absolute directory and no positional arguments")
	}
	if err := CheckServer([]string{"--dir", *dir}); err != nil {
		return err
	}
	c, err := loadController(*dir)
	if err != nil {
		return err
	}
	return atomicJSON(filepath.Join(*dir, "frps.json"), frpsConfig(*dir, c.state))
}

func controllerCertificate() ([]byte, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return nil, nil, err
	}
	now := time.Now()
	template := x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "Stargate remote access"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true, IsCA: true,
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
		DNSNames:    []string{"localhost"},
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), nil
}

func loadController(dir string) (*controller, error) {
	var state serverState
	if err := readJSON(filepath.Join(dir, "server.json"), &state); err != nil {
		return nil, err
	}
	if state.Schema != SchemaVersion || state.Revision == 0 || len(state.AdminToken) < 32 || len(state.FRPToken) < 32 || len(state.PluginPath) < 32 {
		return nil, errors.New("invalid server state")
	}
	if state.Format != 0 && state.Format != ServiceFormat {
		return nil, errors.New("unsupported server state format")
	}
	if err := requireLoopback(state.Listen); err != nil {
		return nil, err
	}
	if err := requireLoopback(state.PluginListen); err != nil {
		return nil, err
	}
	if err := validateNode(state.Node); err != nil {
		return nil, err
	}
	if state.Devices == nil || state.Enrollments == nil || state.Mappings == nil {
		return nil, errors.New("invalid server collections")
	}
	migrateServerState(&state)
	return &controller{dir: dir, state: state, now: time.Now}, nil
}

func CheckServer(args []string) error {
	f := newFlags("check-server")
	dir := f.String("dir", defaultRemoteDir, "private state directory")
	health := f.Bool("health", false, "check the configured HTTPS listener")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("unexpected check-server arguments")
	}
	c, err := loadController(*dir)
	if err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(filepath.Join(*dir, "server.crt"), filepath.Join(*dir, "server.key"))
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(c.state.Certificate)) {
		return errors.New("invalid controller certificate")
	}
	certificate, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return err
	}
	host, _, err := net.SplitHostPort(c.state.Listen)
	if err != nil {
		return err
	}
	if _, err = certificate.Verify(x509.VerifyOptions{Roots: pool, DNSName: host}); err != nil {
		return fmt.Errorf("controller certificate does not match pinned identity: %w", err)
	}
	if !*health {
		return nil
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}, Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return errors.New("health redirects are not allowed") }}
	response, err := client.Get("https://" + c.state.Listen + "/health")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("controller health rejected (HTTP %d)", response.StatusCode)
	}
	return nil
}

func Serve(args []string) error {
	f := newFlags("serve")
	dir := f.String("dir", defaultRemoteDir, "private state directory")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("unexpected serve arguments")
	}
	c, err := loadController(*dir)
	if err != nil {
		return err
	}
	if err := c.commit(c.state); err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(filepath.Join(*dir, "server.crt"), filepath.Join(*dir, "server.key"))
	if err != nil {
		return err
	}
	controlListener, err := net.Listen("tcp", c.state.Listen)
	if err != nil {
		return err
	}
	defer controlListener.Close()
	pluginListener, err := net.Listen("tcp", c.state.PluginListen)
	if err != nil {
		return err
	}
	defer pluginListener.Close()
	controlServer := boundedHTTPServer(c.controlHandler())
	pluginServer := boundedHTTPServer(c.pluginHandler())
	errorsCh := make(chan error, 2)
	go func() {
		errorsCh <- controlServer.Serve(tls.NewListener(controlListener, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}))
	}()
	go func() { errorsCh <- pluginServer.Serve(pluginListener) }()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	select {
	case <-ctx.Done():
	case err = <-errorsCh:
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	controlServer.Shutdown(shutdown)
	pluginServer.Shutdown(shutdown)
	return err
}

func boundedHTTPServer(handler http.Handler) *http.Server {
	return &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8192}
}

func decodeRequest(w http.ResponseWriter, r *http.Request, target any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return errors.New("invalid request body")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return errors.New("invalid request body")
	}
	return nil
}

func jsonResponse(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}

func apiError(w http.ResponseWriter, status int, message string) {
	jsonResponse(w, status, map[string]string{"error": message})
}

func tokenEqual(a, b string) bool {
	return len(a) != 0 && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func bearer(r *http.Request) string {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return ""
	}
	return strings.TrimPrefix(value, "Bearer ")
}

// A candidate is committed to disk before it becomes visible to other requests.
func (c *controller) candidate() serverState {
	b, _ := json.Marshal(c.state)
	var next serverState
	json.Unmarshal(b, &next)
	return next
}

func (c *controller) commit(next serverState) error {
	migrateServerState(&next)
	syncLegacyMappings(&next)
	if err := atomicJSON(filepath.Join(c.dir, "server.json"), next); err != nil {
		return err
	}
	c.state = next
	return nil
}

func (c *controller) device(token string) (serverDevice, bool) {
	for _, device := range c.state.Devices {
		if device.Enabled && tokenEqual(token, device.Token) {
			return device, true
		}
	}
	return serverDevice{}, false
}

func (c *controller) controlHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.mu.Lock()
		defer c.mu.Unlock()
		if !c.ensureCanonical(w) {
			return
		}
		if r.URL.Path == "/health" && r.Method == http.MethodGet {
			jsonResponse(w, http.StatusOK, map[string]any{"schema": SchemaVersion, "ok": true})
			return
		}
		if (r.URL.Path == "/v1/enroll" || r.URL.Path == "/v2/enroll") && r.Method == http.MethodPost {
			c.enroll(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/admin/") {
			if !tokenEqual(bearer(r), c.state.AdminToken) {
				apiError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
			c.adminAPI(w, r)
			return
		}
		device, ok := c.device(bearer(r))
		if !ok {
			apiError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v2/") {
			c.v2API(w, r, device)
			return
		}
		switch {
		case r.URL.Path == "/v1/mappings" && r.Method == http.MethodPost:
			if !deviceCapabilities(device).Publish {
				apiError(w, http.StatusForbidden, "provider required")
				return
			}
			c.saveMapping(w, r, &device)
		case strings.HasPrefix(r.URL.Path, "/v1/mappings/") && r.Method == http.MethodDelete:
			if !deviceCapabilities(device).Publish {
				apiError(w, http.StatusForbidden, "provider required")
				return
			}
			c.deleteMapping(w, strings.TrimPrefix(r.URL.Path, "/v1/mappings/"), &device)
		case r.URL.Path == "/v1/config" && r.Method == http.MethodGet:
			jsonResponse(w, http.StatusOK, c.desired(device))
		case r.URL.Path == "/v1/report" && r.Method == http.MethodPost:
			var report Report
			if err := decodeRequest(w, r, &report); err != nil {
				apiError(w, http.StatusBadRequest, err.Error())
				return
			}
			if len(report.State) > 64 || len(report.Message) > 1024 || report.Revision > c.state.Revision {
				apiError(w, http.StatusBadRequest, "invalid report")
				return
			}
			next := c.candidate()
			device.Report = report
			device.LastSeen = c.now().Unix()
			next.Devices[device.ID] = device
			if err := c.commit(next); err != nil {
				apiError(w, http.StatusInternalServerError, "failed to save report")
				return
			}
			jsonResponse(w, http.StatusOK, map[string]bool{"ok": true})
		default:
			apiError(w, http.StatusNotFound, "not found")
		}
	})
}

func (c *controller) desired(device serverDevice) Desired {
	return c.legacyDesired(device)
}

func containsID(ids []string, id string) bool {
	for _, value := range ids {
		if value == id {
			return true
		}
	}
	return false
}

func (c *controller) enroll(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeRequest(w, r, &req); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	enrollment, ok := c.state.Enrollments[req.Token]
	if !ok || enrollment.ExpiresAt <= c.now().Unix() {
		apiError(w, http.StatusUnauthorized, "invalid or expired enrollment")
		return
	}
	if _, exists := c.state.Devices[enrollment.DeviceID]; exists {
		apiError(w, http.StatusConflict, "device already exists")
		return
	}
	next := c.candidate()
	caps := roleCapabilities(enrollment.Role)
	if enrollment.Capabilities != nil {
		caps = *enrollment.Capabilities
	}
	device := serverDevice{ID: enrollment.DeviceID, Role: capabilityRole(caps), Token: randomToken(), Enabled: true, AllowedVisitors: enrollment.AllowedVisitors, Capabilities: &caps}
	next.Devices[device.ID] = device
	delete(next.Enrollments, req.Token)
	next.Revision++
	if err := c.commit(next); err != nil {
		apiError(w, http.StatusInternalServerError, "failed to enroll device")
		return
	}
	jsonResponse(w, http.StatusOK, Profile{Schema: SchemaVersion, DeviceID: device.ID, Role: device.Role, DeviceToken: device.Token, Node: c.state.Node, ControllerURL: "https://" + c.state.Listen, Certificate: c.state.Certificate, FRPPort: c.state.FRPPort, FRPToken: c.state.FRPToken, Transport: &c.state.Transport, Capabilities: &caps})
}

func (c *controller) adminAPI(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/v1/admin/enrollment" && r.Method == http.MethodPost:
		c.createEnrollment(w, r)
	case r.URL.Path == "/v1/admin/capabilities" && r.Method == http.MethodPost:
		c.changeCapabilities(w, r)
	case r.URL.Path == "/v1/admin/mapping" && r.Method == http.MethodPost:
		c.saveMapping(w, r, nil)
	case strings.HasPrefix(r.URL.Path, "/v1/admin/mapping/") && r.Method == http.MethodDelete:
		c.deleteMapping(w, strings.TrimPrefix(r.URL.Path, "/v1/admin/mapping/"), nil)
	case r.URL.Path == "/v1/admin/revoke" && r.Method == http.MethodPost:
		c.revokeDevice(w, r)
	case r.URL.Path == "/v1/admin/status" && r.Method == http.MethodGet:
		c.status(w)
	default:
		apiError(w, http.StatusNotFound, "not found")
	}
}

func (c *controller) createEnrollment(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string   `json:"device_id"`
		Role     string   `json:"role"`
		TTL      int64    `json:"ttl_seconds"`
		Visitors []string `json:"allowed_visitors"`
		Version  int      `json:"new_schema"`
	}
	if err := decodeRequest(w, r, &req); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	if validateID(req.DeviceID) != nil || (req.Role != "provider" && req.Role != "visitor" && req.Role != "both") {
		apiError(w, http.StatusBadRequest, "invalid device identifier or role")
		return
	}
	if !roleCapabilities(req.Role).Publish && len(req.Visitors) > 0 {
		apiError(w, http.StatusBadRequest, "only providers may receive visitor grants")
		return
	}
	if req.Version != 0 && req.Version != SchemaVersion && req.Version != EnrollmentVersion {
		apiError(w, http.StatusBadRequest, "unsupported enrollment version")
		return
	}
	if err := validateVisitorGrants(c.state, serverDevice{ID: req.DeviceID, Role: req.Role}, req.Visitors, true, c.now().Unix()); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.TTL == 0 {
		req.TTL = 3600
	}
	if req.TTL < 60 || req.TTL > 86400 {
		apiError(w, http.StatusBadRequest, "ttl_seconds must be 60..86400")
		return
	}
	if len(c.state.Devices) >= 256 {
		apiError(w, http.StatusConflict, "device capacity reached")
		return
	}
	if _, exists := c.state.Devices[req.DeviceID]; exists {
		apiError(w, http.StatusConflict, "device already exists; use a new identifier")
		return
	}
	next := c.candidate()
	for token, enrollment := range next.Enrollments {
		if enrollment.ExpiresAt <= c.now().Unix() || enrollment.DeviceID == req.DeviceID {
			delete(next.Enrollments, token)
		}
	}
	if len(next.Enrollments) >= 256 {
		apiError(w, http.StatusConflict, "enrollment capacity reached")
		return
	}
	token := randomToken()
	caps := roleCapabilities(req.Role)
	next.Enrollments[token] = serverEnrollment{DeviceID: req.DeviceID, Role: req.Role, ExpiresAt: c.now().Unix() + req.TTL, AllowedVisitors: req.Visitors, Capabilities: &caps, Version: req.Version}
	version := req.Version
	if version == 0 {
		version = SchemaVersion
	}
	bootstrap := Bootstrap{Schema: version, Node: next.Node, ControllerURL: "https://" + next.Listen, Certificate: next.Certificate, EnrollmentToken: token}
	if version == EnrollmentVersion {
		bootstrap.Transport = &next.Transport
	}
	b, err := json.Marshal(bootstrap)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "failed to encode enrollment")
		return
	}
	if err := c.commit(next); err != nil {
		apiError(w, http.StatusInternalServerError, "failed to save enrollment")
		return
	}
	jsonResponse(w, http.StatusOK, map[string]any{"link": "stargate://enroll/" + base64.RawURLEncoding.EncodeToString(b), "expires_at": next.Enrollments[token].ExpiresAt})
}

func (c *controller) saveMapping(w http.ResponseWriter, r *http.Request, actor *serverDevice) {
	var mapping Mapping
	if err := decodeRequest(w, r, &mapping); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	old, exists := c.state.Mappings[mapping.ID]
	if actor != nil {
		if (mapping.Provider != "" && mapping.Provider != actor.ID) || (exists && old.Provider != actor.ID) {
			apiError(w, http.StatusForbidden, "mapping belongs to another provider")
			return
		}
		if mapping.Secret != "" {
			apiError(w, http.StatusBadRequest, "mapping secret is managed by the server")
			return
		}
		mapping.Provider = actor.ID
		for _, id := range mapping.Visitors {
			if !containsID(actor.AllowedVisitors, id) {
				apiError(w, http.StatusForbidden, "visitor is outside provider grants")
				return
			}
		}
	}
	if !exists && len(c.state.Mappings) >= 256 {
		apiError(w, http.StatusConflict, "mapping capacity reached")
		return
	}
	if mapping.Secret == "" {
		if exists {
			mapping.Secret = old.Secret
		} else {
			mapping.Secret = randomToken()
		}
	}
	// Removing a visitor must invalidate the configuration they already downloaded.
	if exists {
		for _, visitor := range old.Visitors {
			if !containsID(mapping.Visitors, visitor) {
				mapping.Secret = randomToken()
				break
			}
		}
		if mapping.Provider != old.Provider {
			mapping.Secret = randomToken()
		}
	}
	if err := validateMapping(mapping); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	provider, ok := c.state.Devices[mapping.Provider]
	if !ok || !provider.Enabled || !deviceCapabilities(provider).Publish {
		apiError(w, http.StatusBadRequest, "provider must be an enabled provider device")
		return
	}
	for _, id := range mapping.Visitors {
		visitor, ok := c.state.Devices[id]
		if !ok || !visitor.Enabled || !deviceCapabilities(visitor).Bind {
			apiError(w, http.StatusBadRequest, "visitors must be enabled visitor devices")
			return
		}
		for _, current := range c.state.Mappings {
			if current.ID != mapping.ID && current.BindPort == mapping.BindPort && containsID(current.Visitors, id) {
				apiError(w, http.StatusConflict, "visitor bind port conflicts with another mapping")
				return
			}
		}
	}
	if !c.withinMappingQuota(mapping) {
		apiError(w, http.StatusConflict, "per-device mapping capacity reached (128)")
		return
	}
	next := c.candidate()
	if err := bridgeLegacyMapping(&next, mapping, old, exists); err != nil {
		apiError(w, http.StatusConflict, err.Error())
		return
	}
	next.Revision++
	if err := c.commit(next); err != nil {
		apiError(w, http.StatusInternalServerError, "failed to save mapping")
		return
	}
	jsonResponse(w, http.StatusOK, map[string]any{"id": mapping.ID, "revision": c.state.Revision})
}

func (c *controller) withinMappingQuota(mapping Mapping) bool {
	counts := map[string]int{mapping.Provider: 1}
	for _, id := range mapping.Visitors {
		counts[id] = 1
	}
	for _, current := range c.state.Mappings {
		if current.ID == mapping.ID {
			continue
		}
		if _, tracked := counts[current.Provider]; tracked {
			counts[current.Provider]++
		}
		for _, id := range current.Visitors {
			if _, tracked := counts[id]; tracked {
				counts[id]++
			}
		}
	}
	for _, count := range counts {
		if count > 128 {
			return false
		}
	}
	return true
}

func (c *controller) deleteMapping(w http.ResponseWriter, id string, actor *serverDevice) {
	if validateID(id) != nil {
		apiError(w, http.StatusBadRequest, "invalid mapping identifier")
		return
	}
	mapping, exists := c.state.Mappings[id]
	if !exists {
		apiError(w, http.StatusNotFound, "mapping not found")
		return
	}
	if actor != nil && mapping.Provider != actor.ID {
		apiError(w, http.StatusForbidden, "mapping belongs to another provider")
		return
	}
	next := c.candidate()
	delete(next.Mappings, id)
	removeService(&next, serviceKey(mapping.Provider, mapping.ID))
	next.Revision++
	if err := c.commit(next); err != nil {
		apiError(w, http.StatusInternalServerError, "failed to delete mapping")
		return
	}
	jsonResponse(w, http.StatusOK, map[string]uint64{"revision": c.state.Revision})
}

func (c *controller) revokeDevice(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string `json:"device_id"`
	}
	if err := decodeRequest(w, r, &req); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	device, exists := c.state.Devices[req.DeviceID]
	if !exists {
		apiError(w, http.StatusNotFound, "device not found")
		return
	}
	next := c.candidate()
	device.Enabled = false
	next.Devices[device.ID] = device
	c.reduceDeviceAccess(&next, device.ID, deviceCapabilities(device), Capabilities{})
	for token, enrollment := range next.Enrollments {
		if enrollment.DeviceID == device.ID {
			delete(next.Enrollments, token)
		}
	}
	next.Revision++
	if err := c.commit(next); err != nil {
		apiError(w, http.StatusInternalServerError, "failed to revoke device")
		return
	}
	jsonResponse(w, http.StatusOK, map[string]any{"revision": c.state.Revision, "existing_connections": "not forcibly terminated; authorization changes require provider configuration synchronization"})
}

func (c *controller) status(w http.ResponseWriter) {
	type deviceStatus struct {
		ID              string       `json:"id"`
		Role            string       `json:"role"`
		Enabled         bool         `json:"enabled"`
		LastSeen        int64        `json:"last_seen"`
		Report          Report       `json:"report"`
		Capabilities    Capabilities `json:"capabilities"`
		AllowedVisitors []string     `json:"allowed_visitors,omitempty"`
	}
	type mappingStatus struct {
		ID        string   `json:"id"`
		Provider  string   `json:"provider"`
		LocalIP   string   `json:"local_ip"`
		LocalPort int      `json:"local_port"`
		BindPort  int      `json:"bind_port"`
		Visitors  []string `json:"visitors"`
	}
	devices := []deviceStatus{}
	mappings := []mappingStatus{}
	for _, d := range c.state.Devices {
		devices = append(devices, deviceStatus{d.ID, d.Role, d.Enabled, d.LastSeen, d.Report, deviceCapabilities(d), d.AllowedVisitors})
	}
	for _, m := range c.state.Mappings {
		mappings = append(mappings, mappingStatus{m.ID, m.Provider, m.LocalIP, m.LocalPort, m.BindPort, m.Visitors})
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].ID < devices[j].ID })
	sort.Slice(mappings, func(i, j int) bool { return mappings[i].ID < mappings[j].ID })
	services := []map[string]any{}
	bindings := []Binding{}
	for key, s := range c.state.Services {
		services = append(services, map[string]any{"id": s.ID, "provider": s.Provider, "local_ip": s.LocalIP, "local_port": s.LocalPort, "enabled": s.Enabled, "visitors": stateServiceVisitors(c.state, key)})
	}
	for _, b := range c.state.Bindings {
		bindings = append(bindings, b)
	}
	sort.Slice(services, func(i, j int) bool {
		return serviceKey(services[i]["provider"].(string), services[i]["id"].(string)) < serviceKey(services[j]["provider"].(string), services[j]["id"].(string))
	})
	sort.Slice(bindings, func(i, j int) bool {
		return bindingKey(bindings[i].DeviceID, bindings[i].ID) < bindingKey(bindings[j].DeviceID, bindings[j].ID)
	})
	jsonResponse(w, http.StatusOK, map[string]any{"schema": SchemaVersion, "format": ServiceFormat, "transport": c.state.Transport, "services": services, "bindings": bindings, "revision": c.state.Revision, "devices": devices, "mappings": mappings, "revocation": "device API and new provider work denied immediately; visitor secret changes need provider synchronization; established streams are not forcibly closed"})
}

type pluginUser struct {
	User  string            `json:"user"`
	Metas map[string]string `json:"metas"`
}

func (c *controller) pluginDevice(user pluginUser) (serverDevice, bool) {
	device, ok := c.state.Devices[user.User]
	return device, ok && device.Enabled && tokenEqual(user.Metas["device_token"], device.Token)
}

func (c *controller) pluginHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.mu.Lock()
		defer c.mu.Unlock()
		if !c.ensureCanonical(w) {
			return
		}
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || r.URL.Path != c.state.PluginPath || r.Method != http.MethodPost {
			apiError(w, http.StatusNotFound, "not found")
			return
		}
		var request struct {
			Version string          `json:"version"`
			Op      string          `json:"op"`
			Content json.RawMessage `json:"content"`
		}
		if err := decodeRequest(w, r, &request); err != nil {
			jsonResponse(w, http.StatusOK, map[string]any{"reject": true, "reject_reason": "invalid request"})
			return
		}
		if request.Op != "" && request.Op != r.URL.Query().Get("op") {
			jsonResponse(w, http.StatusOK, map[string]any{"reject": true, "reject_reason": "operation mismatch"})
			return
		}
		allowed := false
		if r.URL.Query().Get("op") == "Login" {
			var user pluginUser
			if json.Unmarshal(request.Content, &user) == nil {
				_, allowed = c.pluginDevice(user)
			}
		} else {
			var content struct {
				User       pluginUser `json:"user"`
				ProxyName  string     `json:"proxy_name"`
				ProxyType  string     `json:"proxy_type"`
				Secret     string     `json:"sk"`
				AllowUsers []string   `json:"allow_users"`
			}
			if json.Unmarshal(request.Content, &content) == nil {
				device, valid := c.pluginDevice(content.User)
				if valid {
					switch r.URL.Query().Get("op") {
					case "Ping":
						allowed = true
					case "NewWorkConn":
						allowed = deviceCapabilities(device).Publish
					case "NewProxy", "NewUserConn":
						if deviceCapabilities(device).Publish && content.ProxyType == "stcp" {
							for key, service := range c.state.Services {
								visitors := stateServiceVisitors(c.state, key)
								if service.Provider == device.ID && content.ProxyName == device.ID+"."+service.ID && stateServiceActive(c.state, service) && len(visitors) > 0 {
									allowed = r.URL.Query().Get("op") == "NewUserConn" || (tokenEqual(content.Secret, service.Secret) && sameIDs(content.AllowUsers, visitors))
									break
								}
							}
							// NewUserConn identifies the provider, not the visitor; STCP validates its own visitor secret.
						}
					}
				}
			}
		}
		if !allowed {
			jsonResponse(w, http.StatusOK, map[string]any{"reject": true, "reject_reason": "device or mapping not authorized"})
			return
		}
		jsonResponse(w, http.StatusOK, map[string]bool{"reject": false, "unchange": true})
	})
}

func (c *controller) mappingActive(mapping Mapping) bool {
	return len(c.activeVisitors(mapping)) > 0
}

func (c *controller) activeVisitors(mapping Mapping) []string {
	visitors := []string{}
	for _, id := range mapping.Visitors {
		visitor, ok := c.state.Devices[id]
		if ok && visitor.Enabled && deviceCapabilities(visitor).Bind {
			visitors = append(visitors, id)
		}
	}
	return visitors
}

func sameIDs(actual, expected []string) bool {
	if len(actual) != len(expected) {
		return false
	}
	seen := map[string]bool{}
	for _, id := range actual {
		if seen[id] || !containsID(expected, id) {
			return false
		}
		seen[id] = true
	}
	return true
}

func Admin(args []string) error {
	f := newFlags("admin")
	dir := f.String("dir", defaultRemoteDir, "private server directory")
	if err := f.Parse(args); err != nil {
		return err
	}
	rest := f.Args()
	if len(rest) == 0 {
		return errors.New("admin requires enrollment|mapping|delete|status|revoke")
	}
	op := rest[0]
	opFlags := newFlags("admin " + op)
	device := opFlags.String("device", "", "device identifier")
	role := opFlags.String("role", "", "provider, visitor or both")
	output := opFlags.String("output", "", "private enrollment link file")
	file := opFlags.String("file", "", "mapping JSON file")
	id := opFlags.String("id", "", "mapping identifier")
	ttl := opFlags.Int64("ttl", 3600, "enrollment validity seconds")
	visitors := opFlags.String("visitors", "", "comma-separated provider visitor grants")
	newSchema := opFlags.Int("new-schema", SchemaVersion, "enrollment link version 1 or 2")
	publish := opFlags.String("publish", "", "true or false publish capability")
	bind := opFlags.String("bind", "", "true or false bind capability")
	if err := opFlags.Parse(rest[1:]); err != nil {
		return err
	}
	if opFlags.NArg() != 0 {
		return errors.New("unexpected admin arguments")
	}
	c, err := loadController(*dir)
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(c.state.Certificate)) {
		return errors.New("invalid controller certificate")
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}, Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return errors.New("redirect denied") }}
	method, path := http.MethodPost, "/v1/admin/"+op
	var body any
	switch op {
	case "enrollment":
		if *output == "" {
			return errors.New("enrollment requires --output for private link")
		}
		grants := []string{}
		if *visitors != "" {
			grants = strings.Split(*visitors, ",")
		}
		body = map[string]any{"device_id": *device, "role": *role, "ttl_seconds": *ttl, "allowed_visitors": grants, "new_schema": *newSchema}
	case "capabilities":
		request := map[string]any{"device_id": *device}
		for name, value := range map[string]string{"publish": *publish, "bind": *bind} {
			if value != "" {
				parsed, err := strconv.ParseBool(value)
				if err != nil {
					return errors.New("capabilities require true or false")
				}
				request[name] = parsed
			}
		}
		opFlags.Visit(func(f *flag.Flag) {
			if f.Name == "visitors" {
				ids := []string{}
				if *visitors != "" {
					ids = strings.Split(*visitors, ",")
				}
				request["allowed_visitors"] = ids
			}
		})
		if len(request) == 1 {
			return errors.New("capabilities requires --publish, --bind or --visitors")
		}
		body = request
	case "mapping":
		if *file == "" {
			return errors.New("mapping requires --file")
		}
		var mapping Mapping
		if err := readJSON(*file, &mapping); err != nil {
			return err
		}
		body = mapping
	case "delete":
		if validateID(*id) != nil {
			return errors.New("delete requires valid --id")
		}
		method = http.MethodDelete
		path = "/v1/admin/mapping/" + *id
	case "status":
		method = http.MethodGet
	case "revoke":
		body = map[string]string{"device_id": *device}
	default:
		return errors.New("unknown admin operation")
	}
	b, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(method, "https://"+c.state.Listen+path, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.state.AdminToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("admin request rejected (HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	if op == "enrollment" {
		var result struct {
			Link string `json:"link"`
		}
		if err := json.Unmarshal(data, &result); err != nil || !strings.HasPrefix(result.Link, "stargate://enroll/") {
			return errors.New("invalid enrollment response")
		}
		if err := atomicFile(*output, []byte(result.Link+"\n"), 0600); err != nil {
			return err
		}
		fmt.Println("enrollment saved to", *output)
		return nil
	}
	_, err = os.Stdout.Write(data)
	return err
}
