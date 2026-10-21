package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type agentOptions struct {
	dir, singBox, frpc, linkFile     string
	mappingID, targetIP, visitorList string
	visitorsSpecified                bool
	service, bindAddress, outputFile string
	enabled                          bool
	targetPort, bindPort             int
	socksPort, httpPort, adminPort   int
	interval                         time.Duration
	runtimeWait                      time.Duration
}

func Agent(command string, args []string) error {
	o := agentOptions{}
	f := flag.NewFlagSet(command, flag.ContinueOnError)
	f.StringVar(&o.dir, "dir", "/etc/stargate-remote", "private configuration directory")
	f.StringVar(&o.singBox, "sing-box", "/usr/bin/sing-box", "sing-box executable")
	f.StringVar(&o.frpc, "frpc", "/usr/bin/frpc", "frpc executable")
	f.StringVar(&o.linkFile, "link-file", "", "private enrollment link file")
	f.IntVar(&o.socksPort, "socks-port", 10830, "loopback SOCKS port")
	f.IntVar(&o.httpPort, "http-port", 10831, "loopback HTTP proxy port")
	f.IntVar(&o.adminPort, "admin-port", 17400, "loopback frpc administration port")
	f.DurationVar(&o.interval, "interval", 60*time.Second, "configuration polling interval")
	f.StringVar(&o.mappingID, "id", "", "mapping identifier")
	f.StringVar(&o.targetIP, "target-ip", "", "private mapping target")
	f.IntVar(&o.targetPort, "target-port", 3389, "target TCP port")
	f.IntVar(&o.bindPort, "bind-port", 13389, "visitor loopback TCP port")
	f.StringVar(&o.visitorList, "visitors", "", "comma separated visitor identifiers")
	f.StringVar(&o.service, "service", "", "service key PROVIDER/ID")
	f.StringVar(&o.bindAddress, "bind-address", "127.0.0.1", "visitor loopback address")
	f.StringVar(&o.outputFile, "output", "", "private export file")
	f.BoolVar(&o.enabled, "enabled", true, "enable service or binding")
	if err := f.Parse(args); err != nil {
		return err
	}
	f.Visit(func(option *flag.Flag) {
		if option.Name == "visitors" {
			o.visitorsSpecified = true
		}
	})
	if f.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if err := o.validate(); err != nil {
		return err
	}
	switch command {
	case "enroll":
		return o.enroll()
	case "sync":
		return o.sync()
	case "watch":
		return o.watch()
	case "transport":
		return o.transport()
	case "status":
		return o.status()
	case "mapping-add", "mapping-delete":
		return o.mappingChange(command)
	case "prepare":
		return o.prepare()
	case "service-publish", "service-delete", "grant-set", "binding-add", "binding-delete":
		return o.serviceChange(command)
	case "proxy-export":
		return o.proxyExport()
	default:
		return errors.New("unknown agent command")
	}
}

func (o agentOptions) validate() error {
	if !filepath.IsAbs(o.dir) {
		return errors.New("configuration directory must be absolute")
	}
	seen := map[int]bool{}
	for _, p := range []int{o.socksPort, o.httpPort, o.adminPort} {
		if p < 1024 || p > 65535 || seen[p] {
			return errors.New("invalid or conflicting agent ports")
		}
		seen[p] = true
	}
	if o.interval < time.Second {
		return errors.New("polling interval must be at least one second")
	}
	return nil
}

func controlPort(raw string) (int, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() != "127.0.0.1" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || u.RawPath != "" {
		return 0, errors.New("controller URL must be https://127.0.0.1:PORT")
	}
	p, err := strconv.Atoi(u.Port())
	if err != nil || p < 1 || p > 65535 {
		return 0, errors.New("controller URL requires a valid explicit port")
	}
	return p, nil
}

func validateProfile(p Profile) error {
	if p.Schema != SchemaVersion || validateID(p.DeviceID) != nil || (p.Role != "provider" && p.Role != "visitor" && p.Role != "both" && p.Role != "none") || len(p.DeviceToken) < 32 || len(p.FRPToken) < 32 || p.FRPPort < 1 || p.FRPPort > 65535 {
		return errors.New("invalid device profile")
	}
	if p.Role == "none" && (p.Capabilities == nil || p.Capabilities.Publish || p.Capabilities.Bind) {
		return errors.New("inactive profile requires explicit disabled capabilities")
	}
	if err := validateNode(p.Node); err != nil {
		return err
	}
	if err := validateTransport(p.Transport); err != nil {
		return err
	}
	if _, err := controlPort(p.ControllerURL); err != nil {
		return err
	}
	_, err := pinnedTLS(p.Certificate)
	return err
}

func pinnedTLS(certPEM string) (*tls.Config, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(certPEM)) {
		return nil, errors.New("invalid pinned controller certificate")
	}
	// A private trust store prevents interception even if the outer AnyTLS allows insecure TLS.
	return &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}, nil
}

func (o agentOptions) client(certPEM string) (*http.Client, error) {
	t, err := pinnedTLS(certPEM)
	if err != nil {
		return nil, err
	}
	proxy, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(o.httpPort))
	return &http.Client{Timeout: 40 * time.Second, Transport: &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: t, DisableKeepAlives: true}, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("controller redirects are forbidden") }}, nil
}

func agentRequest(client *http.Client, base, method, path, token string, body, result any) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, strings.TrimRight(base, "/")+path, reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := client.Do(req)
	if err != nil {
		return errors.New("controller connection or TLS verification failed")
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return &agentHTTPError{Status: res.StatusCode}
	}
	if result == nil {
		_, err = io.Copy(io.Discard, io.LimitReader(res.Body, 4<<20))
		return err
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, (4<<20)+1))
	if err != nil || len(b) > 4<<20 {
		return errors.New("invalid controller response size")
	}
	if err = json.Unmarshal(b, result); err != nil {
		return errors.New("invalid controller JSON response")
	}
	return nil
}

func (o agentOptions) transportConfig(n Node, control, frp int) map[string]any {
	return map[string]any{
		"log": map[string]any{"level": "warn"},
		"inbounds": []any{
			map[string]any{"type": "socks", "tag": "remote-socks", "listen": "127.0.0.1", "listen_port": o.socksPort},
			map[string]any{"type": "http", "tag": "remote-http", "listen": "127.0.0.1", "listen_port": o.httpPort},
		},
		"outbounds": []any{
			map[string]any{"type": "anytls", "tag": "remote-anytls", "server": n.Server, "server_port": n.Port, "password": n.Password, "tls": map[string]any{"enabled": true, "server_name": n.ServerName, "insecure": n.Insecure}},
			map[string]any{"type": "block", "tag": "remote-block"},
		},
		"route": map[string]any{"rules": []any{map[string]any{"inbound": []string{"remote-socks", "remote-http"}, "ip_cidr": []string{"127.0.0.1/32"}, "port": []int{control, frp}, "action": "route", "outbound": "remote-anytls"}}, "final": "remote-block"},
	}
}

func safeTool(program string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	// Validation tools may print embedded credentials; expose only the operation and exit result.
	if err := exec.CommandContext(ctx, program, args...).Run(); err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("%s operation timed out", filepath.Base(program))
		}
		return fmt.Errorf("%s operation failed", filepath.Base(program))
	}
	return nil
}

func (o agentOptions) lock() (func(), error) {
	if o.dir == defaultRemoteDir && os.Getenv("STARGATE_REMOTE_LOCK_HELD") != "1" {
		if _, err := os.Stat("/var/lock/stargate-remote-install"); err == nil {
			return nil, errors.New("remote-access maintenance is active; retry after it finishes")
		} else if !os.IsNotExist(err) {
			return nil, err
		}
	}
	if err := os.MkdirAll(o.dir, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(o.dir, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(o.dir, ".update-lock")
	err := os.Mkdir(path, 0700)
	if os.IsExist(err) {
		if st, e := os.Stat(path); e == nil && time.Since(st.ModTime()) > 5*time.Minute {
			_ = os.RemoveAll(path)
			err = os.Mkdir(path, 0700)
		}
	}
	if err != nil {
		return nil, errors.New("another configuration update is active; stale locks expire after five minutes")
	}
	if err = atomicJSON(filepath.Join(path, "owner.json"), map[string]any{"pid": os.Getpid(), "created_at": time.Now().UTC()}); err != nil {
		_ = os.RemoveAll(path)
		return nil, err
	}
	return func() { _ = os.RemoveAll(path) }, nil
}

func privateRead(path string) ([]byte, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 {
		return nil, errors.New("credential file must be a regular file with mode 0600")
	}
	if st.Size() > 4<<20 {
		return nil, errors.New("credential file too large")
	}
	return os.ReadFile(path)
}

func (o agentOptions) profile() (Profile, error) {
	var p Profile
	b, err := privateRead(filepath.Join(o.dir, "profile.json"))
	if err != nil {
		return p, err
	}
	if err = json.Unmarshal(b, &p); err != nil {
		return p, errors.New("invalid stored profile")
	}
	return p, validateProfile(p)
}

func portAvailable(p int) bool {
	l, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(p))
	if err != nil {
		return false
	}
	_ = l.Close()
	return true
}

func (o agentOptions) enroll() error {
	unlock, err := o.lock()
	if err != nil {
		return err
	}
	defer unlock()
	if _, err = os.Lstat(filepath.Join(o.dir, "profile.json")); err == nil {
		return errors.New("device already enrolled; use a new private directory for another device")
	} else if !os.IsNotExist(err) {
		return err
	}
	if o.linkFile == "" {
		return errors.New("enroll requires --link-file")
	}
	b, err := privateRead(o.linkFile)
	if err != nil {
		return err
	}
	link := strings.TrimSpace(string(b))
	const prefix = "stargate://enroll/"
	if !strings.HasPrefix(link, prefix) {
		return errors.New("invalid enrollment link")
	}
	b, err = base64.RawURLEncoding.DecodeString(strings.TrimPrefix(link, prefix))
	if err != nil {
		return errors.New("invalid enrollment payload")
	}
	var bootstrap Bootstrap
	if json.Unmarshal(b, &bootstrap) != nil || (bootstrap.Schema != SchemaVersion && bootstrap.Schema != EnrollmentVersion) || len(bootstrap.EnrollmentToken) < 32 {
		return errors.New("invalid enrollment bootstrap")
	}
	if err = validateNode(bootstrap.Node); err != nil {
		return err
	}
	if err = validateTransport(bootstrap.Transport); err != nil {
		return err
	}
	control, err := controlPort(bootstrap.ControllerURL)
	if err != nil {
		return err
	}
	client, err := o.client(bootstrap.Certificate)
	if err != nil {
		return err
	}
	if !portAvailable(o.socksPort) || !portAvailable(o.httpPort) {
		return errors.New("dedicated transport ports are already occupied")
	}
	stage, err := os.MkdirTemp(o.dir, ".enroll-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	transport := filepath.Join(stage, "transport.json")
	if err = atomicJSON(transport, o.transportConfig(bootstrap.Node, control, 17000)); err != nil {
		return err
	}
	if err = safeTool(o.singBox, "check", "-c", transport); err != nil {
		return err
	}
	cmd := exec.Command(o.singBox, "run", "-c", transport)
	if err = cmd.Start(); err != nil {
		return errors.New("could not start dedicated AnyTLS transport")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	defer func() { _ = cmd.Process.Kill(); <-done }()
	ready := false
	for i := 0; i < 100; i++ {
		c, e := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(o.httpPort), 100*time.Millisecond)
		if e == nil {
			_ = c.Close()
			ready = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		return errors.New("dedicated AnyTLS transport did not become ready")
	}
	var p Profile
	enrollPath := "/v1/enroll"
	if bootstrap.Schema == EnrollmentVersion {
		enrollPath = "/v2/enroll"
	}
	if err = agentRequest(client, bootstrap.ControllerURL, "POST", enrollPath, "", map[string]string{"token": bootstrap.EnrollmentToken}, &p); err != nil {
		return fmt.Errorf("enrollment failed: %w; if the token was consumed, issue a new link", err)
	}
	if err = validateProfile(p); err != nil {
		return err
	}
	if p.Node != bootstrap.Node || p.ControllerURL != bootstrap.ControllerURL || p.Certificate != bootstrap.Certificate {
		return errors.New("enrollment profile does not match bootstrap identity")
	}
	if bootstrap.Transport != nil && !reflect.DeepEqual(p.Transport, bootstrap.Transport) {
		return errors.New("enrollment transport identity differs from bootstrap")
	}
	if err = atomicJSON(transport, o.transportConfig(p.Node, control, p.FRPPort)); err != nil {
		return err
	}
	if err = safeTool(o.singBox, "check", "-c", transport); err != nil {
		return err
	}
	base, err := o.frpcConfig(p, Desired{Schema: SchemaVersion})
	if err != nil {
		return err
	}
	if err = atomicFile(filepath.Join(o.dir, "ca.pem"), []byte(p.Certificate), 0600); err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(o.dir, "transport.json"), o.transportConfig(p.Node, control, p.FRPPort)); err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(o.dir, "frpc.json"), base); err != nil {
		return err
	}
	// Saving the profile last commits enrollment; incomplete attempts cannot start services.
	if err = atomicJSON(filepath.Join(o.dir, "profile.json"), p); err != nil {
		return err
	}
	fmt.Printf("enrolled %s (%s); start the dedicated transport and frpc services, then sync\n", p.DeviceID, p.Role)
	return nil
}

func (o agentOptions) validateDesired(p Profile, d Desired) error {
	if d.Format == ServiceFormat {
		return o.validateDesiredV2(p, d)
	}
	if d.Format != 0 && d.Format != 1 {
		return errors.New("unsupported desired format")
	}
	if d.Schema != SchemaVersion || len(d.Mappings) > 128 {
		return errors.New("invalid desired schema or mapping count")
	}
	ids, ports := map[string]bool{}, map[int]bool{o.socksPort: true, o.httpPort: true, o.adminPort: true}
	visitorIDs := map[string]bool{}
	if len(d.VisitorIDs) > 4096 {
		return errors.New("too many visitor identifiers")
	}
	for _, id := range d.VisitorIDs {
		if validateID(id) != nil || visitorIDs[id] {
			return errors.New("invalid visitor identifiers")
		}
		visitorIDs[id] = true
	}
	for _, m := range d.Mappings {
		if err := validateMapping(m); err != nil {
			return err
		}
		if ids[m.ID] {
			return errors.New("duplicate mapping identifier")
		}
		ids[m.ID] = true
		if m.Provider == p.DeviceID && effectiveCapabilities(p, d).Publish {
		} else {
			if !effectiveCapabilities(p, d).Bind {
				return errors.New("device is not authorized to bind mapping")
			}
			allowed := false
			for _, id := range m.Visitors {
				if id == p.DeviceID {
					allowed = true
				}
			}
			if !allowed {
				return errors.New("visitor is not authorized for mapping")
			}
			if ports[m.BindPort] {
				return errors.New("visitor listener port conflict")
			}
			ports[m.BindPort] = true
		}
	}
	return nil
}

func (o agentOptions) frpcConfig(p Profile, d Desired) (map[string]any, error) {
	if err := o.validateDesired(p, d); err != nil {
		return nil, err
	}
	if d.Format == ServiceFormat {
		return o.frpcConfigV2(p, d)
	}
	h := sha256.Sum256([]byte("stargate-frpc-admin:" + p.DeviceToken))
	cfg := map[string]any{
		"serverAddr": "127.0.0.1", "serverPort": p.FRPPort, "user": p.DeviceID,
		"loginFailExit": false,
		"auth":          map[string]any{"method": "token", "token": p.FRPToken, "additionalScopes": []string{"HeartBeats", "NewWorkConns"}},
		"metadatas":     map[string]string{"device_token": p.DeviceToken},
		"transport":     map[string]any{"protocol": "tcp", "proxyURL": "socks5://127.0.0.1:" + strconv.Itoa(o.socksPort), "tls": map[string]any{"enable": true, "trustedCaFile": filepath.Join(o.dir, "ca.pem"), "serverName": "127.0.0.1"}},
		"webServer":     map[string]any{"addr": "127.0.0.1", "port": o.adminPort, "user": p.DeviceID, "password": hex.EncodeToString(h[:])},
		"log":           map[string]any{"level": "warn"},
		"proxies":       []any{}, "visitors": []any{},
	}
	for _, m := range d.Mappings {
		if m.Provider == p.DeviceID && effectiveCapabilities(p, d).Publish {
			cfg["proxies"] = append(cfg["proxies"].([]any), map[string]any{"name": m.ID, "type": "stcp", "localIP": m.LocalIP, "localPort": m.LocalPort, "secretKey": m.Secret, "allowUsers": m.Visitors})
		} else {
			cfg["visitors"] = append(cfg["visitors"].([]any), map[string]any{"name": m.ID, "type": "stcp", "serverUser": m.Provider, "serverName": m.ID, "secretKey": m.Secret, "bindAddr": "127.0.0.1", "bindPort": m.BindPort})
		}
	}
	return cfg, nil
}

func (o agentOptions) sync() error {
	unlock, err := o.lock()
	if err != nil {
		return err
	}
	defer unlock()
	return o.syncUnlocked()
}

func (o agentOptions) syncUnlocked() error {
	p, err := o.profile()
	if err != nil {
		return err
	}
	client, err := o.client(p.Certificate)
	if err != nil {
		return err
	}
	var desired Desired
	if err = o.fetchDesired(client, p, &desired); err != nil {
		return err
	}
	if err = o.validateDesired(p, desired); err != nil {
		return err
	}
	var previous Desired
	previousPath := filepath.Join(o.dir, "desired.json")
	err = readJSON(previousPath, &previous)
	if err != nil && !os.IsNotExist(err) {
		return errors.New("cannot read previous desired configuration")
	}
	havePrevious := err == nil
	if havePrevious && desired.Revision < previous.Revision {
		return errors.New("controller attempted to replay an older revision")
	}
	if havePrevious && desired.Revision == previous.Revision && !reflect.DeepEqual(desired, previous) && !(previous.Format != ServiceFormat && desired.Format == ServiceFormat) {
		return errors.New("controller changed an existing revision")
	}
	newConfig, err := o.frpcConfig(p, desired)
	if err != nil {
		return err
	}
	changed := !havePrevious
	if havePrevious {
		oldProjected, projectionErr := o.frpcConfig(p, previous)
		if projectionErr != nil {
			return errors.New("invalid previous desired configuration")
		}
		changed = !projectedConfigEqual(newConfig, oldProjected)
	}
	conn, dialErr := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(o.adminPort), time.Second)
	running := dialErr == nil
	if running {
		_ = conn.Close()
	}
	state := "staged"
	if running {
		state = "configured"
	}
	report := func(state, message string) {
		if e := agentRequest(client, p.ControllerURL, "POST", "/v1/report", p.DeviceToken, Report{Revision: desired.Revision, State: state, Message: message}, nil); e != nil {
			fmt.Fprintln(os.Stderr, "configuration retained; status report could not reach controller")
		}
	}
	path := filepath.Join(o.dir, "frpc.json")
	var oldConfig []byte
	rollback := func() error {
		if err := atomicFile(path, oldConfig, 0600); err != nil {
			return errors.New("restoring previous stored configuration failed")
		}
		if running {
			return safeTool(o.frpc, "reload", "-c", path)
		}
		return nil
	}
	if changed {
		cfg := newConfig
		oldConfig, err = privateRead(path)
		if err != nil {
			return errors.New("cannot back up current frpc configuration")
		}
		if err = retainUnchangedProxies(cfg, oldConfig); err != nil {
			return err
		}
		candidate := filepath.Join(o.dir, "frpc.next.json")
		if err = atomicJSON(candidate, cfg); err != nil {
			return err
		}
		defer os.Remove(candidate)
		if err = safeTool(o.frpc, "verify", "-c", candidate); err != nil {
			report("error", "candidate validation failed")
			return err
		}
		// frpc's reload API reads the path used when the service started, not the CLI's -c candidate.
		if err = atomicJSON(path, cfg); err != nil {
			_ = rollback()
			return err
		}
		if running {
			if err = safeTool(o.frpc, "reload", "-c", path); err != nil {
				rollbackErr := rollback()
				report("error", "frpc reload failed")
				if rollbackErr != nil {
					return errors.New("frpc reload failed and restoring the previous runtime failed; stored configuration is retained")
				}
				return errors.New("frpc reload failed; previous configuration restored")
			}
		}
	}
	if running && (effectiveCapabilities(p, desired).Publish || len(activePublications(p, previous)) > 0) {
		if err = o.waitProvider(p, desired); err != nil {
			var rollbackErr error
			if changed {
				rollbackErr = rollback()
			}
			report("error", "provider mappings did not reach running state")
			if rollbackErr != nil {
				return errors.New("provider registration failed; restoring previous runtime also failed")
			}
			if changed {
				return errors.New("provider registration failed; previous configuration restored")
			}
			return errors.New("provider mappings are not registered; stored configuration retained")
		}
		if len(activePublications(p, desired)) > 0 {
			state = "applied"
		}
	}
	if err = atomicJSON(previousPath, desired); err != nil {
		if changed {
			_ = rollback()
		}
		return err
	}
	message := ""
	if state == "configured" {
		message = "configuration loaded; end-to-end reachability requires a separate connection probe"
	}
	report(state, message)
	fmt.Printf("revision %d %s\n", desired.Revision, state)
	return nil
}

type frpcProxyStatus struct {
	Name      string `json:"name"`
	Type      string `json:"type"`
	Status    string `json:"status"`
	Err       string `json:"err"`
	LocalAddr string `json:"local_addr"`
}

func (o agentOptions) frpcStatuses(p Profile) (map[string][]frpcProxyStatus, error) {
	client := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("frpc redirects forbidden") }}
	req, err := http.NewRequest("GET", "http://127.0.0.1:"+strconv.Itoa(o.adminPort)+"/api/status", nil)
	if err != nil {
		return nil, err
	}
	h := sha256.Sum256([]byte("stargate-frpc-admin:" + p.DeviceToken))
	req.SetBasicAuth(p.DeviceID, hex.EncodeToString(h[:]))
	res, err := client.Do(req)
	if err != nil {
		return nil, errors.New("frpc status request failed")
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, errors.New("frpc status authentication or request failed")
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, (4<<20)+1))
	if err != nil || len(body) > 4<<20 {
		return nil, errors.New("invalid frpc status response")
	}
	var statuses map[string][]frpcProxyStatus
	if json.Unmarshal(body, &statuses) != nil {
		return nil, errors.New("invalid frpc status JSON")
	}
	if statuses == nil {
		return nil, errors.New("invalid frpc status object")
	}
	return statuses, nil
}

func (o agentOptions) providerRunning(p Profile, d Desired) (bool, error) {
	statuses, err := o.frpcStatuses(p)
	if err != nil {
		return false, err
	}
	return providerStatusesRunning(p, d, statuses)
}

func providerStatusesRunning(p Profile, d Desired, statuses map[string][]frpcProxyStatus) (bool, error) {
	publications := activePublications(p, d)
	if len(statuses["stcp"]) != len(publications) {
		return false, nil
	}
	byName := map[string]frpcProxyStatus{}
	for kind, entries := range statuses {
		if kind != "stcp" && len(entries) > 0 {
			return false, nil
		}
		for _, entry := range entries {
			if _, exists := byName[entry.Name]; exists {
				return false, nil
			}
			byName[entry.Name] = entry
		}
	}
	for _, m := range publications {
		// frpc 0.71 reports local config names; frps adds the user prefix when authorizing proxies.
		entry, ok := byName[m.ID]
		if !ok || entry.Type != "stcp" || entry.Status != "running" || entry.Err != "" || entry.LocalAddr != net.JoinHostPort(m.LocalIP, strconv.Itoa(m.LocalPort)) {
			return false, nil
		}
	}
	return true, nil
}

func (o agentOptions) waitProvider(p Profile, d Desired) error {
	duration := o.runtimeWait
	if duration == 0 {
		duration = 30 * time.Second
	}
	deadline := time.Now().Add(duration)
	for {
		ready, err := o.providerRunning(p, d)
		if err != nil {
			return err
		}
		if ready {
			return nil
		}
		if !time.Now().Before(deadline) {
			return errors.New("provider registration timed out")
		}
		pause := 250 * time.Millisecond
		if remaining := time.Until(deadline); remaining < pause {
			pause = remaining
		}
		time.Sleep(pause)
	}
}

func (o agentOptions) watch() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	delay := o.interval
	for {
		if err := o.sync(); err != nil {
			fmt.Fprintln(os.Stderr, "sync:", err)
			delay *= 2
			if delay > 10*time.Minute {
				delay = 10 * time.Minute
			}
		} else {
			delay = o.interval
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
}

func (o agentOptions) transport() error {
	if _, err := o.profile(); err != nil {
		return err
	}
	path := filepath.Join(o.dir, "transport.json")
	if err := safeTool(o.singBox, "check", "-c", path); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cmd := exec.CommandContext(ctx, o.singBox, "run", "-c", path)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil && ctx.Err() == nil {
		return errors.New("dedicated AnyTLS transport stopped unexpectedly")
	}
	return nil
}

func (o agentOptions) status() error {
	p, err := o.profile()
	if err != nil {
		return err
	}
	var d Desired
	err = readJSON(filepath.Join(o.dir, "desired.json"), &d)
	if err != nil && !os.IsNotExist(err) {
		return errors.New("invalid stored desired configuration")
	}
	return json.NewEncoder(os.Stdout).Encode(o.statusDocument(p, d))
}

func (o agentOptions) mappingChange(command string) error {
	unlock, err := o.lock()
	if err != nil {
		return err
	}
	defer unlock()
	p, err := o.profile()
	if err != nil {
		return err
	}
	if p.Role != "provider" {
		return errors.New("only providers can manage mappings")
	}
	if err = validateID(o.mappingID); err != nil {
		return err
	}
	client, err := o.client(p.Certificate)
	if err != nil {
		return err
	}
	if command == "mapping-delete" {
		err = agentRequest(client, p.ControllerURL, "DELETE", "/v1/mappings/"+o.mappingID, p.DeviceToken, nil, nil)
	} else {
		visitors := strings.Split(o.visitorList, ",")
		for i := range visitors {
			visitors[i] = strings.TrimSpace(visitors[i])
		}
		m := Mapping{ID: o.mappingID, Provider: p.DeviceID, LocalIP: o.targetIP, LocalPort: o.targetPort, BindPort: o.bindPort, Visitors: visitors, Secret: strings.Repeat("x", 32)}
		if err = validateMapping(m); err != nil {
			return err
		}
		body := map[string]any{"id": m.ID, "local_ip": m.LocalIP, "local_port": m.LocalPort, "bind_port": m.BindPort, "visitors": m.Visitors}
		err = agentRequest(client, p.ControllerURL, "POST", "/v1/mappings", p.DeviceToken, body, nil)
	}
	if err != nil {
		return err
	}
	if err = o.syncUnlocked(); err != nil {
		return fmt.Errorf("mapping saved on controller; synchronization failed: %w", err)
	}
	return nil
}

func (o agentOptions) prepare() error {
	unlock, err := o.lock()
	if err != nil {
		return err
	}
	defer unlock()
	p, err := o.profile()
	if err != nil {
		return err
	}
	if !portAvailable(o.adminPort) || !portAvailable(o.socksPort) || !portAvailable(o.httpPort) {
		return errors.New("stop dedicated remote access services before preparing configuration")
	}
	var d Desired
	err = readJSON(filepath.Join(o.dir, "desired.json"), &d)
	if os.IsNotExist(err) {
		d = Desired{Schema: SchemaVersion}
	} else if err != nil {
		return errors.New("invalid stored desired configuration")
	}
	control, err := controlPort(p.ControllerURL)
	if err != nil {
		return err
	}
	stage, err := os.MkdirTemp(o.dir, ".prepare-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	transport := o.transportConfig(p.Node, control, p.FRPPort)
	if err = atomicJSON(filepath.Join(stage, "transport.json"), transport); err != nil {
		return err
	}
	if err = safeTool(o.singBox, "check", "-c", filepath.Join(stage, "transport.json")); err != nil {
		return err
	}
	if err = atomicFile(filepath.Join(stage, "ca.pem"), []byte(p.Certificate), 0600); err != nil {
		return err
	}
	cfg, err := o.frpcConfig(p, d)
	if err != nil {
		return err
	}
	tmpOptions := o
	tmpOptions.dir = stage
	checkCfg, err := tmpOptions.frpcConfig(p, d)
	if err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(stage, "frpc.json"), checkCfg); err != nil {
		return err
	}
	if err = safeTool(o.frpc, "verify", "-c", filepath.Join(stage, "frpc.json")); err != nil {
		return err
	}
	if err = atomicFile(filepath.Join(o.dir, "ca.pem"), []byte(p.Certificate), 0600); err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(o.dir, "transport.json"), transport); err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(o.dir, "frpc.json"), cfg); err != nil {
		return err
	}
	fmt.Println("dedicated transport and frpc configuration prepared")
	return nil
}
