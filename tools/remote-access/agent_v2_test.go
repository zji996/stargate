package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func testServiceDesired() Desired {
	return Desired{Schema: SchemaVersion, Format: ServiceFormat, DeviceID: "home", Revision: 1, Capabilities: &Capabilities{Publish: true, Bind: true}, Services: []Service{{ID: "rdp", Provider: "home", LocalIP: "10.23.0.10", LocalPort: 3389, Enabled: true, Secret: strings.Repeat("s", 64)}}, VisitorIDs: []string{"mac", "home"}}
}

func TestAgentV2PublicationAndBindingAreIndependent(t *testing.T) {
	o := testAgentOptions(t)
	p := testAgentProfile("unused", "https://127.0.0.1:17443")
	d := testServiceDesired()
	cfg, err := o.frpcConfig(p, d)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg["proxies"].([]any)) != 0 || len(cfg["visitors"].([]any)) != 0 {
		t.Fatal("ungranted service registered or created visitor")
	}
	d.Services[0].Visitors = []string{"mac"}
	d.Grants = []Grant{{Service: "home/rdp", Visitor: "mac"}}
	cfg, err = o.frpcConfig(p, d)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg["proxies"].([]any)) != 1 || len(cfg["visitors"].([]any)) != 0 {
		t.Fatal("publishing created a local listener")
	}
	provider := cfg["proxies"]
	remote := Service{ID: "ssh", Provider: "office", LocalIP: "10.24.0.10", LocalPort: 22, Enabled: true, Secret: strings.Repeat("r", 64), Visitors: []string{"home"}}
	d.AvailableServices = []Service{remote}
	d.Grants = append(d.Grants, Grant{Service: "office/ssh", Visitor: "home"})
	d.Bindings = []Binding{{ID: "office-ssh", DeviceID: "home", Service: "office/ssh", BindAddr: "127.0.0.1", BindPort: 10022, Enabled: true}}
	cfg, err = o.frpcConfig(p, d)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(provider, cfg["proxies"]) || len(cfg["visitors"].([]any)) != 1 {
		t.Fatal("binding changed published service")
	}
	visitor := cfg["visitors"].([]any)[0].(map[string]any)
	if visitor["name"] != "office-ssh" || visitor["serverUser"] != "office" || visitor["serverName"] != "ssh" || visitor["bindPort"] != 10022 {
		t.Fatal("binding did not reference independent service")
	}
	d.Bindings[0].BindPort = 10023
	updated, err := o.frpcConfig(p, d)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(cfg["proxies"], updated["proxies"]) {
		t.Fatal("listener port update changed provider projection")
	}
	d.AvailableServices = nil
	updated, err = o.frpcConfig(p, d)
	if err != nil {
		t.Fatal("disabled remote service must retain dormant binding", err)
	}
	if len(updated["visitors"].([]any)) != 0 || !reflect.DeepEqual(provider, updated["proxies"]) {
		t.Fatal("unavailable service retained a visitor")
	}
	d.Capabilities = &Capabilities{Publish: false, Bind: true}
	updated, err = o.frpcConfig(p, d)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated["proxies"].([]any)) != 0 {
		t.Fatal("revoked publish capability kept provider active")
	}
}

func TestAgentV2RejectsInvalidOwnershipAndAuthorization(t *testing.T) {
	o := testAgentOptions(t)
	p := testAgentProfile("unused", "https://127.0.0.1:17443")
	base := testServiceDesired()
	base.Services[0].Visitors = []string{"home"}
	base.AvailableServices = []Service{base.Services[0]}
	base.Grants = []Grant{{Service: "home/rdp", Visitor: "home"}}
	base.Bindings = []Binding{{ID: "local-rdp", DeviceID: "home", Service: "home/rdp", BindAddr: "127.0.0.1", BindPort: 13389, Enabled: true}}
	cases := []struct {
		name   string
		mutate func(*Desired)
	}{
		{"wrong-device", func(d *Desired) { d.DeviceID = "elsewhere" }},
		{"no-capabilities", func(d *Desired) { d.Capabilities = nil }},
		{"foreign-publication", func(d *Desired) { d.Services[0].Provider = "elsewhere" }},
		{"public-target", func(d *Desired) { d.Services[0].LocalIP = "8.8.8.8" }},
		{"weak-secret", func(d *Desired) { d.Services[0].Secret = "short" }},
		{"missing-grant", func(d *Desired) { d.Grants = nil }},
		{"wrong-visitor", func(d *Desired) { d.AvailableServices[0].Visitors = []string{"mac"} }},
		{"foreign-binding", func(d *Desired) { d.Bindings[0].DeviceID = "mac" }},
		{"public-listener", func(d *Desired) { d.Bindings[0].BindAddr = "0.0.0.0" }},
		{"conflicting-port", func(d *Desired) { d.Bindings[0].BindPort = o.httpPort }},
		{"duplicate-listener", func(d *Desired) { copy := d.Bindings[0]; copy.ID = "another"; d.Bindings = append(d.Bindings, copy) }},
		{"revoked-bind", func(d *Desired) { d.Capabilities.Bind = false }},
		{"duplicate-service", func(d *Desired) { d.Services = append(d.Services, d.Services[0]) }},
		{"legacy-payload-in-v2", func(d *Desired) { d.Mappings = []Mapping{testMapping()} }},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			b, _ := json.Marshal(base)
			var d Desired
			_ = json.Unmarshal(b, &d)
			tt.mutate(&d)
			if err := o.validateDesired(p, d); err == nil {
				t.Fatal("accepted invalid v2 configuration")
			}
		})
	}
}

type v2AgentHarness struct {
	o                  agentOptions
	p                  Profile
	mu                 sync.Mutex
	desired            Desired
	legacy             Desired
	statusCode         int
	rejectRegistration bool
	requests           map[string]int
	bodies             map[string]map[string]json.RawMessage
	reports            []Report
}

func newV2AgentHarness(t *testing.T) *v2AgentHarness {
	t.Helper()
	h := &v2AgentHarness{o: testAgentOptions(t), desired: testServiceDesired(), requests: map[string]int{}, bodies: map[string]map[string]json.RawMessage{}}
	h.o.runtimeWait = 80 * time.Millisecond
	controller := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		defer h.mu.Unlock()
		h.requests[r.Method+" "+r.URL.Path]++
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("d", 64) {
			http.Error(w, "unauthorized", 401)
			return
		}
		switch r.URL.Path {
		case "/v2/config":
			if h.statusCode != 0 {
				w.WriteHeader(h.statusCode)
				return
			}
			_ = json.NewEncoder(w).Encode(h.desired)
		case "/v1/config":
			_ = json.NewEncoder(w).Encode(h.legacy)
		case "/v1/report":
			var report Report
			if json.NewDecoder(r.Body).Decode(&report) != nil {
				w.WriteHeader(400)
				return
			}
			h.reports = append(h.reports, report)
			w.WriteHeader(204)
		default:
			if !strings.HasPrefix(r.URL.Path, "/v2/") {
				http.NotFound(w, r)
				return
			}
			if r.Method == http.MethodPost {
				var body map[string]json.RawMessage
				if json.NewDecoder(r.Body).Decode(&body) != nil {
					w.WriteHeader(400)
					return
				}
				h.bodies[r.URL.Path] = body
			}
			h.desired.Revision++
			w.WriteHeader(204)
		}
	}))
	t.Cleanup(controller.Close)
	proxy := testConnectProxy(t)
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(proxy.URL, "http://"))
	h.o.httpPort, _ = strconv.Atoi(port)
	h.p = testAgentProfile(testCertificate(controller), controller.URL)
	h.p.Transport = &Transport{ID: "dmit", Name: "Remote channel"}
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		hash := sha256.Sum256([]byte("stargate-frpc-admin:" + h.p.DeviceToken))
		if !ok || user != h.p.DeviceID || password != hex.EncodeToString(hash[:]) {
			w.WriteHeader(401)
			return
		}
		if r.URL.Path != "/api/status" {
			http.NotFound(w, r)
			return
		}
		var cfg struct {
			Proxies []struct {
				Name      string `json:"name"`
				Type      string `json:"type"`
				LocalIP   string `json:"localIP"`
				LocalPort int    `json:"localPort"`
			} `json:"proxies"`
		}
		if readJSON(filepath.Join(h.o.dir, "frpc.json"), &cfg) != nil {
			w.WriteHeader(500)
			return
		}
		h.mu.Lock()
		reject := h.rejectRegistration
		h.mu.Unlock()
		statuses := []frpcProxyStatus{}
		for _, p := range cfg.Proxies {
			status := frpcProxyStatus{Name: p.Name, Type: p.Type, Status: "running", LocalAddr: net.JoinHostPort(p.LocalIP, strconv.Itoa(p.LocalPort))}
			if reject {
				status.Status = "start error"
				status.Err = "do-not-expose-server-message"
			}
			statuses = append(statuses, status)
		}
		_ = json.NewEncoder(w).Encode(map[string][]frpcProxyStatus{"stcp": statuses})
	}))
	t.Cleanup(admin.Close)
	_, port, _ = net.SplitHostPort(strings.TrimPrefix(admin.URL, "http://"))
	h.o.adminPort, _ = strconv.Atoi(port)
	if err := atomicJSON(filepath.Join(h.o.dir, "profile.json"), h.p); err != nil {
		t.Fatal(err)
	}
	base, _ := h.o.frpcConfig(h.p, Desired{Schema: SchemaVersion})
	if err := atomicJSON(filepath.Join(h.o.dir, "frpc.json"), base); err != nil {
		t.Fatal(err)
	}
	h.o.frpc = filepath.Join(h.o.dir, "frpc-test")
	script := "#!/bin/sh\ncd \"$(dirname \"$0\")\" || exit 1\nprintf '%s\\n' \"$1\" >> commands\n"
	if err := os.WriteFile(h.o.frpc, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	return h
}

func TestAgentV2HTTPFallbackOnlyOn404(t *testing.T) {
	h := newV2AgentHarness(t)
	client, _ := h.o.client(h.p.Certificate)
	for _, code := range []int{401, 403, 500} {
		h.mu.Lock()
		h.statusCode = code
		h.mu.Unlock()
		var d Desired
		if err := h.o.fetchDesired(client, h.p, &d); err == nil {
			t.Fatal("controller error was swallowed")
		}
	}
	h.mu.Lock()
	fallbacks := h.requests["GET /v1/config"]
	h.statusCode = 404
	h.legacy = Desired{Schema: SchemaVersion, Revision: 1}
	h.mu.Unlock()
	if fallbacks != 0 {
		t.Fatal("unauthorized/error request retried legacy endpoint")
	}
	var d Desired
	if err := h.o.fetchDesired(client, h.p, &d); err != nil || d.Schema != SchemaVersion {
		t.Fatal("missing v2 endpoint did not fall back", err)
	}
}

func TestAgentV2MigrationAndProjectionChanges(t *testing.T) {
	h := newV2AgentHarness(t)
	legacy := Desired{Schema: SchemaVersion, Revision: 1, Mappings: []Mapping{testMapping()}}
	oldCfg, err := h.o.frpcConfig(h.p, legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err = atomicJSON(filepath.Join(h.o.dir, "frpc.json"), oldCfg); err != nil {
		t.Fatal(err)
	}
	if err = atomicJSON(filepath.Join(h.o.dir, "desired.json"), legacy); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	h.desired.Capabilities = &Capabilities{Publish: true}
	h.desired.Services[0].Visitors = []string{"mac"}
	h.desired.Grants = []Grant{{Service: "home/rdp", Visitor: "mac"}}
	h.mu.Unlock()
	if err = h.o.sync(); err != nil {
		t.Fatal("same-revision legacy migration rejected", err)
	}
	commands, _ := os.ReadFile(filepath.Join(h.o.dir, "commands"))
	if len(commands) != 0 {
		t.Fatal("equivalent legacy migration reloaded runtime")
	}
	var saved Desired
	if err = readJSON(filepath.Join(h.o.dir, "desired.json"), &saved); err != nil || saved.Format != ServiceFormat {
		t.Fatal("migration was not committed", err)
	}
	h.mu.Lock()
	h.desired.Revision++
	h.desired.VisitorIDs = append(h.desired.VisitorIDs, "newmac")
	h.mu.Unlock()
	if err = h.o.sync(); err != nil {
		t.Fatal(err)
	}
	commands, _ = os.ReadFile(filepath.Join(h.o.dir, "commands"))
	if len(commands) != 0 {
		t.Fatal("catalog-only revision reloaded runtime")
	}
	h.mu.Lock()
	h.desired.Revision++
	h.desired.Services[0].LocalPort = 3390
	h.rejectRegistration = true
	h.mu.Unlock()
	if err = h.o.sync(); err == nil || !strings.Contains(err.Error(), "restored") {
		t.Fatal("failed v2 provider did not roll back", err)
	}
	var restored map[string]any
	if err = readJSON(filepath.Join(h.o.dir, "frpc.json"), &restored); err != nil {
		t.Fatal(err)
	}
	if restored["proxies"].([]any)[0].(map[string]any)["localPort"] != float64(3389) {
		t.Fatal("failed v2 provider changed stored target")
	}
	h.mu.Lock()
	report := h.reports[len(h.reports)-1]
	h.mu.Unlock()
	if report.State != "error" || strings.Contains(report.Message, "do-not-expose") {
		t.Fatal("unsafe failure report", report)
	}
}

func TestAgentV2CLIUsesIndependentRequests(t *testing.T) {
	h := newV2AgentHarness(t)
	o := h.o
	o.mappingID = "rdp"
	o.targetIP = "10.23.0.10"
	o.targetPort = 3389
	o.enabled = true
	if err := o.serviceChange("service-publish"); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	publish := h.bodies["/v2/services"]
	h.mu.Unlock()
	if publish["bind_port"] != nil || publish["secret"] != nil || publish["provider"] != nil {
		t.Fatal("service publication contained a listener or credentials")
	}
	o.service = "home/rdp"
	o.visitorList = ""
	if err := o.serviceChange("grant-set"); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	grant := h.bodies["/v2/grants"]
	h.mu.Unlock()
	if string(grant["visitors"]) != "[]" {
		t.Fatal("empty grant set did not revoke all visitors")
	}
	o.mappingID = "my-rdp"
	o.bindAddress = "127.0.0.1"
	o.bindPort = 13390
	if err := o.serviceChange("binding-add"); err != nil {
		t.Fatal("stale provider profile blocked current bind capability", err)
	}
	h.mu.Lock()
	binding := h.bodies["/v2/bindings"]
	h.mu.Unlock()
	if string(binding["service"]) != `"home/rdp"` || string(binding["bind_port"]) != "13390" || binding["local_ip"] != nil || binding["secret"] != nil {
		t.Fatal("binding request contained publication fields")
	}
	if err := o.serviceChange("binding-delete"); err != nil {
		t.Fatal(err)
	}
	if err := o.serviceChange("service-delete"); err != nil {
		t.Fatal(err)
	}
}

func TestAgentV2StatusAndProxyExportKeepSecretsPrivate(t *testing.T) {
	h := newV2AgentHarness(t)
	h.mu.Lock()
	h.desired.Services[0].Visitors = []string{"mac"}
	h.desired.Grants = []Grant{{Service: "home/rdp", Visitor: "mac"}}
	d := h.desired
	h.mu.Unlock()
	if err := h.o.sync(); err != nil {
		t.Fatal(err)
	}
	status := h.o.statusDocument(h.p, d)
	b, _ := json.Marshal(status)
	for _, secret := range []string{h.p.Node.Password, h.p.DeviceToken, h.p.FRPToken, d.Services[0].Secret, "password", "certificate", "device_token"} {
		if strings.Contains(string(b), secret) {
			t.Fatal("status exposed credentials")
		}
	}
	transport := status["transport"].(map[string]any)
	if transport["id"] != "dmit" || transport["name"] != "Remote channel" || transport["server"] != h.p.Node.Server {
		t.Fatal("status did not describe fixed transport")
	}
	if status["runtime"].(map[string]any)["state"] != "applied" {
		t.Fatal("status missed registered provider")
	}
	h.p.Node.Password = "a:@/%+?secret"
	h.p.Node.Insecure = false
	if err := atomicJSON(filepath.Join(h.o.dir, "profile.json"), h.p); err != nil {
		t.Fatal(err)
	}
	h.o.outputFile = filepath.Join(h.o.dir, "export.uri")
	if err := h.o.proxyExport(); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(h.o.outputFile)
	if err != nil || st.Mode().Perm() != 0600 {
		t.Fatal("export is not private", err)
	}
	b, err = os.ReadFile(h.o.outputFile)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(strings.TrimSpace(string(b)))
	if err != nil || u.User.Username() != h.p.Node.Password || u.Hostname() != h.p.Node.Server || u.Query().Get("insecure") != "0" {
		t.Fatal("export changed AnyTLS credentials or TLS policy", err)
	}
	legacy := h.p
	legacy.Transport = nil
	status = h.o.statusDocument(legacy, Desired{Schema: SchemaVersion})
	transport = status["transport"].(map[string]any)
	if transport["id"] == "" || transport["name"] == "" {
		t.Fatal("legacy transport lacks safe display metadata")
	}
}

func TestAgentV2PrepareKeepsLegacyProfileCompatible(t *testing.T) {
	controller := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer controller.Close()
	o := testAgentOptions(t)
	p := testAgentProfile(testCertificate(controller), controller.URL)
	d := Desired{Schema: SchemaVersion, Revision: 1, Mappings: []Mapping{testMapping()}}
	if err := atomicJSON(filepath.Join(o.dir, "profile.json"), p); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(o.dir, "desired.json"), d); err != nil {
		t.Fatal(err)
	}
	o.singBox = filepath.Join(o.dir, "tool-test")
	o.frpc = o.singBox
	if err := os.WriteFile(o.singBox, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := o.prepare(); err != nil {
		t.Fatal("legacy profile could not be prepared after relocation", err)
	}
	var cfg map[string]any
	if err := readJSON(filepath.Join(o.dir, "frpc.json"), &cfg); err != nil {
		t.Fatal(err)
	}
	tls := cfg["transport"].(map[string]any)["tls"].(map[string]any)
	if tls["trustedCaFile"] != filepath.Join(o.dir, "ca.pem") || len(cfg["proxies"].([]any)) != 1 {
		t.Fatal("legacy relocated runtime lost its certificate path or publication")
	}
	var preserved Profile
	if err := readJSON(filepath.Join(o.dir, "profile.json"), &preserved); err != nil || !reflect.DeepEqual(p, preserved) {
		t.Fatal("prepare rewrote the fixed profile", err)
	}
}

func TestAgentV2CLIServiceTogglePreservesBindings(t *testing.T) {
	c := v2Controller(t)
	publishService(t, c, "router", "windows", []string{"laptop"})
	bindService(t, c, "laptop", "desktop", "router/windows", 13389)
	server := httptest.NewTLSServer(c.controlHandler())
	defer server.Close()
	proxy := testConnectProxy(t)
	o := testAgentOptions(t)
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(proxy.URL, "http://"))
	o.httpPort, _ = strconv.Atoi(port)
	p := testAgentProfile(testCertificate(server), server.URL)
	p.DeviceID = "router"
	p.DeviceToken = c.state.Devices["router"].Token
	if err := atomicJSON(filepath.Join(o.dir, "profile.json"), p); err != nil {
		t.Fatal(err)
	}
	base, _ := o.frpcConfig(p, Desired{Schema: SchemaVersion})
	if err := atomicJSON(filepath.Join(o.dir, "frpc.json"), base); err != nil {
		t.Fatal(err)
	}
	o.frpc = filepath.Join(o.dir, "frpc-test")
	if err := os.WriteFile(o.frpc, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	args := []string{"--dir", o.dir, "--frpc", o.frpc, "--socks-port", strconv.Itoa(o.socksPort), "--http-port", strconv.Itoa(o.httpPort), "--admin-port", strconv.Itoa(o.adminPort), "--id", "windows", "--target-ip", "10.23.0.10", "--target-port", "3389"}
	for _, enabled := range []string{"false", "true"} {
		if err := Agent("service-publish", append(args, "--enabled="+enabled)); err != nil {
			t.Fatal(err)
		}
		c.mu.Lock()
		_, bindingExists := c.state.Bindings["laptop/desktop"]
		_, grantExists := c.state.Grants["router/windows/laptop"]
		active := c.state.Services["router/windows"].Enabled
		c.mu.Unlock()
		if !bindingExists || !grantExists || strconv.FormatBool(active) != enabled {
			t.Fatal("omitted visitors changed authorization while toggling service")
		}
	}
	if err := Agent("service-publish", append(args, "--visitors", "")); err != nil {
		t.Fatal(err)
	}
	c.mu.Lock()
	_, bindingExists := c.state.Bindings["laptop/desktop"]
	_, grantExists := c.state.Grants["router/windows/laptop"]
	c.mu.Unlock()
	if bindingExists || grantExists {
		t.Fatal("explicit empty visitors did not revoke authorization")
	}
}

func TestAgentV2UnorderedLegacyMigrationPreservesLiveProxies(t *testing.T) {
	h := newV2AgentHarness(t)
	mapping := testMapping()
	mapping.Visitors = []string{"tablet", "mac"}
	legacy := Desired{Schema: SchemaVersion, Revision: 1, Mappings: []Mapping{mapping}}
	oldCfg, err := h.o.frpcConfig(h.p, legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err = atomicJSON(filepath.Join(h.o.dir, "frpc.json"), oldCfg); err != nil {
		t.Fatal(err)
	}
	if err = atomicJSON(filepath.Join(h.o.dir, "desired.json"), legacy); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	h.desired.Services[0].Visitors = []string{"mac", "tablet"}
	h.desired.Grants = []Grant{{Service: "home/rdp", Visitor: "mac"}, {Service: "home/rdp", Visitor: "tablet"}}
	h.mu.Unlock()
	if err = h.o.sync(); err != nil {
		t.Fatal("unordered legacy migration failed", err)
	}
	commands, _ := os.ReadFile(filepath.Join(h.o.dir, "commands"))
	if len(commands) != 0 {
		t.Fatal("visitor ordering alone reloaded an established provider")
	}
	h.mu.Lock()
	h.desired.Revision++
	h.desired.AvailableServices = []Service{{ID: "ssh", Provider: "office", LocalIP: "10.24.0.10", LocalPort: 22, Enabled: true, Secret: strings.Repeat("r", 64), Visitors: []string{"home"}}}
	h.desired.Grants = append(h.desired.Grants, Grant{Service: "office/ssh", Visitor: "home"})
	h.desired.Bindings = []Binding{{ID: "office-ssh", DeviceID: "home", Service: "office/ssh", BindAddr: "127.0.0.1", BindPort: 10022, Enabled: true}}
	h.mu.Unlock()
	if err = h.o.sync(); err != nil {
		t.Fatal("binding update after migration failed", err)
	}
	var newCfg map[string]any
	if err = readJSON(filepath.Join(h.o.dir, "frpc.json"), &newCfg); err != nil {
		t.Fatal(err)
	}
	proxies := newCfg["proxies"].([]any)
	users := proxies[0].(map[string]any)["allowUsers"].([]any)
	if !reflect.DeepEqual(users, []any{"tablet", "mac"}) {
		t.Fatal("unrelated listener update reordered live provider grants")
	}
	if !projectedConfigEqual(oldCfg["proxies"], newCfg["proxies"]) {
		t.Fatal("binding update changed provider configuration")
	}
}
