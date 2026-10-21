package main

import (
	"bytes"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func testController(t *testing.T) *controller {
	t.Helper()
	root := t.TempDir()
	nodeFile := filepath.Join(root, "node.json")
	if err := atomicJSON(nodeFile, Node{Server: "example.com", Port: 443, Password: randomToken()}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, "state")
	if err := ServerInit([]string{"--dir", dir, "--node-file", nodeFile}); err != nil {
		t.Fatal(err)
	}
	c, err := loadController(dir)
	if err != nil {
		t.Fatal(err)
	}
	c.now = func() time.Time { return time.Unix(1700000000, 0) }
	return c
}

func controllerRequest(t *testing.T, c *controller, method, path, token string, payload any) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	c.controlHandler().ServeHTTP(w, r)
	return w
}

func expectCode(t *testing.T, result *httptest.ResponseRecorder, code int) {
	t.Helper()
	if result.Code != code {
		t.Fatalf("HTTP %d, expected %d", result.Code, code)
	}
}

func testDevices(t *testing.T, c *controller) {
	t.Helper()
	c.state.Devices = map[string]serverDevice{
		"router":      {ID: "router", Role: "provider", Enabled: true, Token: randomToken(), AllowedVisitors: []string{"laptop", "tablet"}},
		"otherrouter": {ID: "otherrouter", Role: "provider", Enabled: true, Token: randomToken(), AllowedVisitors: []string{"other"}},
		"laptop":      {ID: "laptop", Role: "visitor", Enabled: true, Token: randomToken()},
		"tablet":      {ID: "tablet", Role: "visitor", Enabled: true, Token: randomToken()},
		"other":       {ID: "other", Role: "visitor", Enabled: true, Token: randomToken()},
	}
	if err := atomicJSON(filepath.Join(c.dir, "server.json"), c.state); err != nil {
		t.Fatal(err)
	}
}

func sampleMapping() Mapping {
	return Mapping{ID: "windows", Provider: "router", LocalIP: "10.23.0.10", LocalPort: 3389, BindPort: 13389, Visitors: []string{"laptop", "tablet"}}
}

func TestServerInitialization(t *testing.T) {
	c := testController(t)
	for _, filename := range []string{"server.json", "admin.token", "server.crt", "server.key", "frps.json"} {
		info, err := os.Stat(filepath.Join(c.dir, filename))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0600 {
			t.Errorf("%s permission = %o", filename, info.Mode().Perm())
		}
	}
	info, _ := os.Stat(c.dir)
	if info.Mode().Perm() != 0700 {
		t.Error("state directory is not private")
	}
	block, _ := pem.Decode([]byte(c.state.Certificate))
	if block == nil {
		t.Fatal("missing certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if err := cert.VerifyHostname("127.0.0.1"); err != nil {
		t.Fatal(err)
	}
	if cert.NotAfter.Sub(cert.NotBefore) < 9*365*24*time.Hour {
		t.Error("certificate lifetime too short")
	}
	var config struct {
		BindAddr      string `json:"bindAddr"`
		ProxyBindAddr string `json:"proxyBindAddr"`
		Transport     struct {
			TLS struct {
				Force bool   `json:"force"`
				Cert  string `json:"certFile"`
				Key   string `json:"keyFile"`
			} `json:"tls"`
		} `json:"transport"`
		Plugins []struct {
			Addr string   `json:"addr"`
			Path string   `json:"path"`
			Ops  []string `json:"ops"`
		} `json:"httpPlugins"`
	}
	if err := readJSON(filepath.Join(c.dir, "frps.json"), &config); err != nil {
		t.Fatal(err)
	}
	if config.BindAddr != "127.0.0.1" || config.ProxyBindAddr != "127.0.0.1" || !config.Transport.TLS.Force {
		t.Error("frps is not loopback TLS only")
	}
	if !filepath.IsAbs(config.Transport.TLS.Cert) || !filepath.IsAbs(config.Transport.TLS.Key) {
		t.Error("certificate paths are not absolute")
	}
	if len(config.Plugins) != 1 || len(config.Plugins[0].Path) < 32 || len(config.Plugins[0].Ops) != 5 {
		t.Error("invalid plugin authorization configuration")
	}
	for _, bad := range []string{"0.0.0.0:17443", "example.com:17443"} {
		if err := ServerInit([]string{"--dir", c.dir, "--node-file", filepath.Join(filepath.Dir(c.dir), "node.json"), "--listen", bad}); err == nil {
			t.Error("accepted a public listener")
		}
	}
	if err := ServerInit([]string{"--dir", c.dir, "--node-file", filepath.Join(filepath.Dir(c.dir), "node.json")}); err == nil {
		t.Error("overwrote an existing server")
	}
	expectCode(t, controllerRequest(t, c, http.MethodGet, "/health", "", nil), http.StatusOK)
}

func enrollmentToken(t *testing.T, c *controller, id, role string, visitors []string) string {
	t.Helper()
	r := controllerRequest(t, c, http.MethodPost, "/v1/admin/enrollment", c.state.AdminToken, map[string]any{"device_id": id, "role": role, "ttl_seconds": 60, "allowed_visitors": visitors})
	expectCode(t, r, http.StatusOK)
	var result struct {
		Link string `json:"link"`
	}
	if err := json.Unmarshal(r.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(result.Link, "stargate://enroll/"))
	if err != nil {
		t.Fatal(err)
	}
	var bootstrap Bootstrap
	if err := json.Unmarshal(data, &bootstrap); err != nil {
		t.Fatal(err)
	}
	if bootstrap.Node.Password != c.state.Node.Password || bootstrap.Certificate != c.state.Certificate {
		t.Error("bootstrap omitted transport trust")
	}
	return bootstrap.EnrollmentToken
}

func TestEnrollmentOnceAndExpiration(t *testing.T) {
	c := testController(t)
	token := enrollmentToken(t, c, "laptop", "visitor", nil)
	// A provider can be granted an identity whose visitor enrollment is still pending.
	providerToken := enrollmentToken(t, c, "router", "provider", []string{"laptop"})
	r := controllerRequest(t, c, http.MethodPost, "/v1/enroll", "", map[string]string{"token": token})
	expectCode(t, r, http.StatusOK)
	var profile Profile
	if err := json.Unmarshal(r.Body.Bytes(), &profile); err != nil {
		t.Fatal(err)
	}
	if profile.Role != "visitor" || profile.DeviceID != "laptop" || len(profile.DeviceToken) < 32 {
		t.Error("invalid profile")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/enroll", "", map[string]string{"token": token}), http.StatusUnauthorized)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/enroll", "", map[string]string{"token": providerToken}), http.StatusOK)
	if !containsID(c.state.Devices["router"].AllowedVisitors, "laptop") {
		t.Error("lost visitor grant")
	}
	expired := enrollmentToken(t, c, "tablet", "visitor", nil)
	c.now = func() time.Time { return time.Unix(1700000060, 0) }
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/enroll", "", map[string]string{"token": expired}), http.StatusUnauthorized)
	expectCode(t, controllerRequest(t, c, http.MethodGet, "/v1/config", c.state.AdminToken, nil), http.StatusUnauthorized)
}

func TestConcurrentEnrollmentOnlyOneSucceeds(t *testing.T) {
	c := testController(t)
	token := enrollmentToken(t, c, "laptop", "visitor", nil)
	var wg sync.WaitGroup
	codes := make(chan int, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes <- controllerRequest(t, c, http.MethodPost, "/v1/enroll", "", map[string]string{"token": token}).Code
		}()
	}
	wg.Wait()
	close(codes)
	success := 0
	for code := range codes {
		if code == http.StatusOK {
			success++
		} else if code != http.StatusUnauthorized {
			t.Error("unexpected enrollment result")
		}
	}
	if success != 1 {
		t.Errorf("successful redemptions = %d", success)
	}
}

func TestProviderMappingScopesAndPortConflicts(t *testing.T) {
	c := testController(t)
	testDevices(t, c)
	providerToken := c.state.Devices["router"].Token
	map1 := sampleMapping()
	map1.Provider = ""
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", providerToken, map1), http.StatusOK)
	first := c.state.Mappings[map1.ID]
	if first.Provider != "router" || len(first.Secret) < 32 {
		t.Error("server did not fill provider and secret")
	}
	other := sampleMapping()
	other.ID = "otherwindows"
	other.Provider = "otherrouter"
	other.Visitors = []string{"other"}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, other), http.StatusOK)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", providerToken, other), http.StatusForbidden)
	expectCode(t, controllerRequest(t, c, http.MethodDelete, "/v1/mappings/otherwindows", providerToken, nil), http.StatusForbidden)
	map1.Visitors = []string{"other"}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", providerToken, map1), http.StatusForbidden)
	map1.Visitors = []string{"laptop"}
	map1.Secret = randomToken()
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", providerToken, map1), http.StatusBadRequest)
	map1.Secret = ""
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", providerToken, map1), http.StatusOK)
	if c.state.Mappings[map1.ID].Secret == first.Secret {
		t.Error("removing a visitor retained their old secret")
	}
	duplicate := map1
	duplicate.ID = "duplicate"
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", providerToken, duplicate), http.StatusConflict)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", c.state.Devices["laptop"].Token, duplicate), http.StatusForbidden)
	for id, count := range map[string]int{"router": 1, "laptop": 1, "tablet": 0, "other": 1} {
		r := controllerRequest(t, c, http.MethodGet, "/v1/config", c.state.Devices[id].Token, nil)
		expectCode(t, r, http.StatusOK)
		var desired Desired
		if err := json.Unmarshal(r.Body.Bytes(), &desired); err != nil {
			t.Fatal(err)
		}
		if len(desired.Mappings) != count {
			t.Errorf("%s sees %d mappings, expected %d", id, len(desired.Mappings), count)
		}
		if id == "router" && len(desired.VisitorIDs) != 2 {
			t.Error("missing provider grants")
		}
	}
	expectCode(t, controllerRequest(t, c, http.MethodDelete, "/v1/mappings/windows", providerToken, nil), http.StatusOK)
}

func TestPerDeviceMappingQuota(t *testing.T) {
	for _, scenario := range []string{"provider", "visitor"} {
		t.Run(scenario, func(t *testing.T) {
			c := testController(t)
			testDevices(t, c)
			otherProvider := c.state.Devices["otherrouter"]
			otherProvider.AllowedVisitors = []string{"laptop", "tablet"}
			c.state.Devices[otherProvider.ID] = otherProvider
			for i := 0; i < 128; i++ {
				m := sampleMapping()
				m.ID = fmt.Sprintf("mapping%03d", i)
				m.BindPort = 10000 + i
				m.Visitors = []string{"laptop"}
				m.Secret = randomToken()
				if scenario == "visitor" && i%2 == 1 {
					m.Provider = "otherrouter"
				}
				c.state.Mappings[m.ID] = m
			}
			c.state.Format = 0
			migrateServerState(&c.state)
			if err := atomicJSON(filepath.Join(c.dir, "server.json"), c.state); err != nil {
				t.Fatal(err)
			}
			next := sampleMapping()
			next.ID = "overflow"
			next.BindPort = 15000
			next.Visitors = []string{"tablet"}
			if scenario == "visitor" {
				next.Visitors = []string{"laptop"}
			}
			before, _ := json.Marshal(c.state)
			for _, path := range []string{"/v1/admin/mapping", "/v1/mappings"} {
				token := c.state.AdminToken
				if path == "/v1/mappings" {
					token = c.state.Devices["router"].Token
				}
				expectCode(t, controllerRequest(t, c, http.MethodPost, path, token, next), http.StatusConflict)
			}
			after, _ := json.Marshal(c.state)
			if !bytes.Equal(before, after) {
				t.Error("quota rejection changed state")
			}
			// Updating an existing mapping at the limit does not allocate a second slot.
			update := c.state.Mappings["mapping000"]
			update.Secret = ""
			update.LocalPort = 3390
			expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, update), http.StatusOK)
			expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", c.state.Devices["router"].Token, update), http.StatusOK)
			if scenario == "visitor" {
				// A modification that grants a full visitor one more mapping is also rejected.
				extra := sampleMapping()
				extra.ID = "othermapping"
				extra.BindPort = 15001
				extra.Visitors = []string{"tablet"}
				expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, extra), http.StatusOK)
				extra.Visitors = []string{"laptop", "tablet"}
				for _, path := range []string{"/v1/admin/mapping", "/v1/mappings"} {
					token := c.state.AdminToken
					if path == "/v1/mappings" {
						token = c.state.Devices["router"].Token
					}
					expectCode(t, controllerRequest(t, c, http.MethodPost, path, token, extra), http.StatusConflict)
				}
			} else {
				// Reassigning another provider's mapping cannot overflow the receiving provider.
				extra := sampleMapping()
				extra.ID = "othermapping"
				extra.Provider = "otherrouter"
				extra.BindPort = 15001
				extra.Visitors = []string{"tablet"}
				expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, extra), http.StatusOK)
				extra.Provider = "router"
				expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, extra), http.StatusConflict)
			}
		})
	}
}

func pluginRequest(t *testing.T, c *controller, op string, content any, remote string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]any{"version": "0.1.0", "op": op, "content": content})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, c.state.PluginPath+"?version=0.1.0&op="+op, bytes.NewReader(body))
	r.RemoteAddr = remote
	w := httptest.NewRecorder()
	c.pluginHandler().ServeHTTP(w, r)
	return w
}

func pluginAllowed(t *testing.T, c *controller, op string, content any) bool {
	t.Helper()
	w := pluginRequest(t, c, op, content, "127.0.0.1:43210")
	expectCode(t, w, http.StatusOK)
	var response struct {
		Reject bool `json:"reject"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return !response.Reject
}

func TestPluginAuthorizationAndRevocation(t *testing.T) {
	c := testController(t)
	testDevices(t, c)
	mapping := sampleMapping()
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, mapping), http.StatusOK)
	mapping = c.state.Mappings[mapping.ID]
	user := pluginUser{User: "router", Metas: map[string]string{"device_token": c.state.Devices["router"].Token}}
	if !pluginAllowed(t, c, "Login", user) {
		t.Error("provider login rejected")
	}
	forged := pluginUser{User: "otherrouter", Metas: user.Metas}
	if pluginAllowed(t, c, "Login", forged) {
		t.Error("accepted token under another device identity")
	}
	content := map[string]any{"user": user, "proxy_name": "router.windows", "proxy_type": "stcp", "sk": mapping.Secret, "allow_users": mapping.Visitors}
	if !pluginAllowed(t, c, "NewProxy", content) {
		t.Error("valid STCP registration rejected")
	}
	for _, invalid := range [][]string{nil, {"*"}, {"laptop", "*"}, {"laptop", "other"}, {"laptop"}, {"laptop", "laptop"}} {
		content["allow_users"] = invalid
		if pluginAllowed(t, c, "NewProxy", content) {
			t.Error("accepted unauthorized visitor registration")
		}
	}
	content["allow_users"] = []string{"tablet", "laptop"}
	if !pluginAllowed(t, c, "NewProxy", content) {
		t.Error("valid unordered visitor set rejected")
	}
	content["allow_users"] = mapping.Visitors
	for _, op := range []string{"Ping", "NewWorkConn", "NewUserConn"} {
		if !pluginAllowed(t, c, op, content) {
			t.Errorf("valid %s rejected", op)
		}
	}
	content["proxy_type"] = "tcp"
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("accepted a public TCP proxy")
	}
	content["proxy_type"] = "stcp"
	content["sk"] = randomToken()
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("accepted wrong mapping secret")
	}
	content["sk"] = mapping.Secret
	content["proxy_name"] = "otherrouter.windows"
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("accepted another provider mapping namespace")
	}
	content["proxy_name"] = "router.windows"
	expectCode(t, pluginRequest(t, c, "Login", user, "203.0.113.1:43210"), http.StatusNotFound)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/revoke", c.state.AdminToken, map[string]string{"device_id": "laptop"}), http.StatusOK)
	if c.state.Mappings["windows"].Secret == mapping.Secret {
		t.Error("visitor revocation retained mapping secret")
	}
	expectCode(t, controllerRequest(t, c, http.MethodGet, "/v1/config", c.state.Devices["laptop"].Token, nil), http.StatusUnauthorized)
	// NewUserConn carries provider identity; another enabled visitor keeps this mapping active.
	if !pluginAllowed(t, c, "NewUserConn", content) {
		t.Error("NewUserConn incorrectly assumed visitor identity")
	}
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("old secret registration allowed after rotation")
	}
	content["sk"] = c.state.Mappings["windows"].Secret
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("registration retained revoked visitor in allow_users")
	}
	content["allow_users"] = []string{"tablet"}
	if !pluginAllowed(t, c, "NewProxy", content) {
		t.Error("synchronized active visitor set rejected")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/revoke", c.state.AdminToken, map[string]string{"device_id": "router"}), http.StatusOK)
	for _, op := range []string{"Ping", "NewWorkConn", "NewUserConn"} {
		if pluginAllowed(t, c, op, content) {
			t.Errorf("revoked provider permitted %s", op)
		}
	}
}

func TestFailedPersistenceDoesNotChangeMemory(t *testing.T) {
	c := testController(t)
	testDevices(t, c)
	before, _ := json.Marshal(c.state)
	if err := os.Remove(filepath.Join(c.dir, "server.json")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(c.dir, "server.json"), 0700); err != nil {
		t.Fatal(err)
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, sampleMapping()), http.StatusInternalServerError)
	after, _ := json.Marshal(c.state)
	if !bytes.Equal(before, after) {
		t.Error("failed persistent mutation polluted memory")
	}
}

func TestStatusHidesCredentialsAndReportKeepsRevision(t *testing.T) {
	c := testController(t)
	testDevices(t, c)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/mapping", c.state.AdminToken, sampleMapping()), http.StatusOK)
	revision := c.state.Revision
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/report", c.state.Devices["router"].Token, Report{Revision: revision, State: "applied"}), http.StatusOK)
	if c.state.Revision != revision {
		t.Error("report changed desired configuration revision")
	}
	r := controllerRequest(t, c, http.MethodGet, "/v1/admin/status", c.state.AdminToken, nil)
	expectCode(t, r, http.StatusOK)
	for _, secret := range []string{c.state.AdminToken, c.state.FRPToken, c.state.Node.Password, c.state.Devices["router"].Token, c.state.Mappings["windows"].Secret} {
		if strings.Contains(r.Body.String(), secret) {
			t.Error("status leaked a credential")
		}
	}
	expectCode(t, controllerRequest(t, c, http.MethodGet, "/v1/admin/status", c.state.Devices["router"].Token, nil), http.StatusUnauthorized)
	raw := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(`{"token":"x","unexpected":true}`))
	w := httptest.NewRecorder()
	c.controlHandler().ServeHTTP(w, raw)
	expectCode(t, w, http.StatusBadRequest)
}
