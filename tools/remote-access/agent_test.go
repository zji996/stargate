package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func testAgentOptions(t *testing.T) agentOptions {
	t.Helper()
	ports := []int{}
	listeners := []net.Listener{}
	for i := 0; i < 3; i++ {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		listeners = append(listeners, l)
		ports = append(ports, l.Addr().(*net.TCPAddr).Port)
	}
	for _, l := range listeners {
		l.Close()
	}
	return agentOptions{dir: t.TempDir(), socksPort: ports[0], httpPort: ports[1], adminPort: ports[2], interval: time.Minute}
}

func testAgentProfile(cert, controller string) Profile {
	return Profile{Schema: SchemaVersion, DeviceID: "home", Role: "provider", DeviceToken: strings.Repeat("d", 64), Node: Node{Server: "203.0.113.5", Port: 443, Password: "anytls-password", ServerName: "remote.example"}, ControllerURL: controller, Certificate: cert, FRPPort: 17000, FRPToken: strings.Repeat("f", 64)}
}

func testMapping() Mapping {
	return Mapping{ID: "rdp", Provider: "home", LocalIP: "10.23.0.10", LocalPort: 3389, BindPort: 13389, Visitors: []string{"mac"}, Secret: strings.Repeat("s", 64)}
}

func TestAgentControllerURLRestrictions(t *testing.T) {
	for _, raw := range []string{"http://127.0.0.1:17443", "https://localhost:17443", "https://10.23.0.1:17443", "https://[::1]:17443", "https://user:pass@127.0.0.1:17443", "https://127.0.0.1", "https://127.0.0.1:65536", "https://127.0.0.1:17443/v1", "https://127.0.0.1:17443?token=secret", "https://127.0.0.1:17443#fragment"} {
		if _, err := controlPort(raw); err == nil {
			t.Errorf("accepted controller URL %s", raw)
		}
	}
	if p, err := controlPort("https://127.0.0.1:17443"); err != nil || p != 17443 {
		t.Fatal(p, err)
	}
}

func TestAgentTransportHasNoDirectFallback(t *testing.T) {
	o := testAgentOptions(t)
	cfg := o.transportConfig(Node{Server: "203.0.113.5", Port: 443, Password: "password"}, 17443, 17000)
	outs := cfg["outbounds"].([]any)
	if len(outs) != 2 || outs[0].(map[string]any)["type"] != "anytls" || outs[1].(map[string]any)["type"] != "block" {
		t.Fatal("unexpected outbound transport")
	}
	route := cfg["route"].(map[string]any)
	if route["final"] != "remote-block" {
		t.Fatal("missing reject fallback")
	}
	rules := route["rules"].([]any)
	if len(rules) != 1 {
		t.Fatal("unexpected route count")
	}
	rule := rules[0].(map[string]any)
	if !reflect.DeepEqual(rule["ip_cidr"], []string{"127.0.0.1/32"}) || !reflect.DeepEqual(rule["port"], []int{17443, 17000}) {
		t.Fatal("transport can reach unapproved target")
	}
	for _, inbound := range cfg["inbounds"].([]any) {
		if inbound.(map[string]any)["listen"] != "127.0.0.1" {
			t.Fatal("public transport listener")
		}
	}
}

func TestAgentPrivateCredentialsAndLock(t *testing.T) {
	o := testAgentOptions(t)
	path := filepath.Join(o.dir, "link")
	if err := os.WriteFile(path, []byte("private"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := privateRead(path); err == nil {
		t.Fatal("accepted public credential file")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := privateRead(path); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(o.dir, "symlink")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := privateRead(link); err == nil {
		t.Fatal("accepted symlink credential file")
	}
	unlock, err := o.lock()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := o.lock(); err == nil {
		t.Fatal("allowed overlapping updates")
	}
	unlock()
	unlock, err = o.lock()
	if err != nil {
		t.Fatal(err)
	}
	unlock()
}

func TestAgentSTCPRoleRestrictions(t *testing.T) {
	o := testAgentOptions(t)
	p := testAgentProfile("unused", "https://127.0.0.1:17443")
	d := Desired{Schema: SchemaVersion, Revision: 1, Mappings: []Mapping{testMapping()}, VisitorIDs: []string{"mac"}}
	cfg, err := o.frpcConfig(p, d)
	if err != nil {
		t.Fatal(err)
	}
	proxy := cfg["proxies"].([]any)[0].(map[string]any)
	if cfg["loginFailExit"] != false {
		t.Fatal("frpc must keep reconnecting after login failure")
	}
	if proxy["type"] != "stcp" || !reflect.DeepEqual(proxy["allowUsers"], []string{"mac"}) || cfg["user"] != "home" {
		t.Fatal("missing provider authorization")
	}
	if !reflect.DeepEqual(cfg["auth"].(map[string]any)["additionalScopes"], []string{"HeartBeats", "NewWorkConns"}) {
		t.Fatal("missing work and heartbeat authentication")
	}
	p.Role = "visitor"
	p.DeviceID = "mac"
	cfg, err = o.frpcConfig(p, d)
	if err != nil {
		t.Fatal(err)
	}
	visitor := cfg["visitors"].([]any)[0].(map[string]any)
	if visitor["serverUser"] != "home" || visitor["serverName"] != "rdp" || visitor["bindAddr"] != "127.0.0.1" {
		t.Fatal("invalid visitor configuration")
	}
	p.DeviceID = "uninvited"
	if _, err = o.frpcConfig(p, d); err == nil {
		t.Fatal("accepted unauthorized visitor")
	}
	p.DeviceID = "mac"
	d.Mappings[0].BindPort = o.httpPort
	if _, err = o.frpcConfig(p, d); err == nil {
		t.Fatal("accepted listener conflict")
	}
	d.Mappings[0] = testMapping()
	d.Mappings[0].LocalIP = "8.8.8.8"
	if _, err = o.frpcConfig(p, d); err == nil {
		t.Fatal("accepted public target")
	}
	d.Mappings[0] = testMapping()
	d.Mappings[0].Secret = "short"
	if _, err = o.frpcConfig(p, d); err == nil {
		t.Fatal("accepted weak secret")
	}
	d.Mappings = []Mapping{testMapping(), testMapping()}
	if _, err = o.frpcConfig(p, d); err == nil {
		t.Fatal("accepted duplicate mapping")
	}
	p.Role = "provider"
	p.DeviceID = "elsewhere"
	d.Mappings = []Mapping{testMapping()}
	if _, err = o.frpcConfig(p, d); err == nil {
		t.Fatal("accepted foreign provider mapping")
	}
}

func testConnectProxy(t *testing.T) *httptest.Server {
	t.Helper()
	p := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "CONNECT" {
			http.Error(w, "CONNECT required", 405)
			return
		}
		up, err := net.DialTimeout("tcp", r.Host, time.Second)
		if err != nil {
			http.Error(w, "unreachable", 502)
			return
		}
		client, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			up.Close()
			return
		}
		defer client.Close()
		defer up.Close()
		_, _ = rw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		_ = rw.Flush()
		done := make(chan struct{})
		go func() { _, _ = io.Copy(up, rw); _ = up.Close(); close(done) }()
		_, _ = io.Copy(client, up)
		_ = client.Close()
		<-done
	}))
	t.Cleanup(p.Close)
	return p
}

func testCertificate(server *httptest.Server) string {
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.TLS.Certificates[0].Certificate[0]}))
}

func TestAgentProviderStatusRequiresRegistration(t *testing.T) {
	p := testAgentProfile("unused", "https://127.0.0.1:17443")
	d := Desired{Schema: SchemaVersion, Mappings: []Mapping{testMapping()}}
	good := frpcProxyStatus{Name: "rdp", Type: "stcp", Status: "running", LocalAddr: "10.23.0.10:3389"}
	tests := []struct {
		name    string
		entries []frpcProxyStatus
		ready   bool
	}{
		{"registered", []frpcProxyStatus{good}, true},
		{"missing", nil, false},
		{"wrong-user-prefix", []frpcProxyStatus{{Name: "home.rdp", Type: "stcp", Status: "running", LocalAddr: good.LocalAddr}}, false},
		{"old-target", []frpcProxyStatus{{Name: good.Name, Type: "stcp", Status: "running", LocalAddr: "10.23.0.10:3390"}}, false},
		{"waiting", []frpcProxyStatus{{Name: good.Name, Type: "stcp", Status: "wait start", LocalAddr: good.LocalAddr}}, false},
		{"registration-error", []frpcProxyStatus{{Name: good.Name, Type: "stcp", Status: "running", LocalAddr: good.LocalAddr, Err: "rejected"}}, false},
		{"stale-extra", []frpcProxyStatus{good, {Name: "old", Type: "stcp", Status: "running", LocalAddr: good.LocalAddr}}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			o := testAgentOptions(t)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_ = json.NewEncoder(w).Encode(map[string][]frpcProxyStatus{"stcp": tt.entries})
			}))
			defer server.Close()
			_, port, _ := net.SplitHostPort(strings.TrimPrefix(server.URL, "http://"))
			o.adminPort, _ = strconv.Atoi(port)
			ready, err := o.providerRunning(p, d)
			if err != nil || ready != tt.ready {
				t.Fatal("unexpected registration result", ready, err)
			}
		})
	}
	o := testAgentOptions(t)
	o.runtimeWait = time.Second
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		status := good
		if requests == 1 {
			status.Status = "wait start"
		}
		_ = json.NewEncoder(w).Encode(map[string][]frpcProxyStatus{"stcp": {status}})
	}))
	defer server.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(server.URL, "http://"))
	o.adminPort, _ = strconv.Atoi(port)
	if err := o.waitProvider(p, d); err != nil {
		t.Fatal("did not wait for asynchronous registration", err)
	}
}

func TestAgentProviderStatusFRP071Payload(t *testing.T) {
	o := testAgentOptions(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"stcp":[{"name":"windows","type":"stcp","status":"running","err":"","local_addr":"10.23.0.10:3389","plugin":"","remote_addr":""}]}`)
	}))
	defer server.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(server.URL, "http://"))
	o.adminPort, _ = strconv.Atoi(port)
	p := testAgentProfile("unused", "https://127.0.0.1:17443")
	m := testMapping()
	m.ID = "windows"
	ready, err := o.providerRunning(p, Desired{Schema: SchemaVersion, Mappings: []Mapping{m}})
	if err != nil || !ready {
		t.Fatal("frpc 0.71 local-name status payload rejected", ready, err)
	}
}

func TestAgentSyncPinnedTLSIdempotenceAndRollback(t *testing.T) {
	o := testAgentOptions(t)
	o.runtimeWait = 80 * time.Millisecond
	desired := Desired{Schema: SchemaVersion, Revision: 1, Mappings: []Mapping{testMapping()}}
	var mu sync.Mutex
	var reports []Report
	rejectRegistration := false
	controller := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("d", 64) {
			http.Error(w, "unauthorized", 401)
			return
		}
		switch r.URL.Path {
		case "/v1/config":
			mu.Lock()
			defer mu.Unlock()
			_ = json.NewEncoder(w).Encode(desired)
		case "/v1/report":
			var report Report
			if json.NewDecoder(r.Body).Decode(&report) != nil {
				http.Error(w, "bad report", 400)
				return
			}
			mu.Lock()
			reports = append(reports, report)
			mu.Unlock()
			w.WriteHeader(204)
		default:
			http.NotFound(w, r)
		}
	}))
	defer controller.Close()
	proxy := testConnectProxy(t)
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(proxy.URL, "http://"))
	o.httpPort, _ = strconv.Atoi(port)
	p := testAgentProfile(testCertificate(controller), controller.URL)
	if err := atomicJSON(filepath.Join(o.dir, "profile.json"), p); err != nil {
		t.Fatal(err)
	}
	base, _ := o.frpcConfig(p, Desired{Schema: SchemaVersion})
	if err := atomicJSON(filepath.Join(o.dir, "frpc.json"), base); err != nil {
		t.Fatal(err)
	}
	o.frpc = filepath.Join(o.dir, "frpc-test")
	script := "#!/bin/sh\ncd \"$(dirname \"$0\")\" || exit 1\nprintf '%s %s\\n' \"$1\" \"$3\" >> commands\nif [ \"$1\" = reload ] && [ -e fail ] && grep -q '\"localPort\": 3390' \"$3\"; then exit 1; fi\n"
	if err := os.WriteFile(o.frpc, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	admin := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		hash := sha256.Sum256([]byte("stargate-frpc-admin:" + p.DeviceToken))
		if !ok || user != p.DeviceID || password != hex.EncodeToString(hash[:]) {
			http.Error(w, "unauthorized", 401)
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
		if readJSON(filepath.Join(o.dir, "frpc.json"), &cfg) != nil {
			http.Error(w, "bad config", 500)
			return
		}
		mu.Lock()
		rejected := rejectRegistration
		mu.Unlock()
		statuses := []frpcProxyStatus{}
		for _, proxy := range cfg.Proxies {
			status := frpcProxyStatus{Name: proxy.Name, Type: proxy.Type, Status: "running", LocalAddr: net.JoinHostPort(proxy.LocalIP, strconv.Itoa(proxy.LocalPort))}
			if rejected {
				status.Status = "start error"
				status.Err = "private-secret-must-not-be-reported"
			}
			statuses = append(statuses, status)
		}
		_ = json.NewEncoder(w).Encode(map[string][]frpcProxyStatus{"stcp": statuses})
	}))
	o.adminPort = admin.Listener.Addr().(*net.TCPAddr).Port
	base, _ = o.frpcConfig(p, Desired{Schema: SchemaVersion})
	if err := atomicJSON(filepath.Join(o.dir, "frpc.json"), base); err != nil {
		t.Fatal(err)
	}
	admin.Start()
	defer admin.Close()
	var err error
	if err = o.sync(); err != nil {
		t.Fatal(err)
	}
	commands1, _ := os.ReadFile(filepath.Join(o.dir, "commands"))
	if strings.Count(string(commands1), "reload ") != 1 || strings.Count(string(commands1), "verify ") != 1 {
		t.Fatalf("initial apply did not verify and reload: %s", commands1)
	}
	if err = o.sync(); err != nil {
		t.Fatal(err)
	}
	commands2, _ := os.ReadFile(filepath.Join(o.dir, "commands"))
	if string(commands2) != string(commands1) {
		t.Fatal("identical revision triggered reload")
	}
	mu.Lock()
	lastReport := reports[len(reports)-1]
	mu.Unlock()
	if lastReport.State != "applied" {
		t.Fatal("provider not reported registered", lastReport)
	}
	mu.Lock()
	desired.Revision = 2
	mu.Unlock()
	if err = o.sync(); err != nil {
		t.Fatal(err)
	}
	commands2, _ = os.ReadFile(filepath.Join(o.dir, "commands"))
	if string(commands2) != string(commands1) {
		t.Fatal("revision-only update triggered reload")
	}
	previous, _ := os.ReadFile(filepath.Join(o.dir, "frpc.json"))
	if err = os.WriteFile(filepath.Join(o.dir, "fail"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	desired.Revision = 3
	desired.Mappings[0].LocalPort = 3390
	mu.Unlock()
	if err = o.sync(); err == nil || !strings.Contains(err.Error(), "restored") {
		t.Fatal("expected failed reload with rollback", err)
	}
	current, _ := os.ReadFile(filepath.Join(o.dir, "frpc.json"))
	if string(current) != string(previous) {
		t.Fatal("failed reload changed stored configuration")
	}
	var applied Desired
	if err = readJSON(filepath.Join(o.dir, "desired.json"), &applied); err != nil || applied.Revision != 2 {
		t.Fatal("failed reload changed applied revision", err)
	}
	commands3, _ := os.ReadFile(filepath.Join(o.dir, "commands"))
	if !strings.HasSuffix(string(commands3), "reload "+filepath.Join(o.dir, "frpc.json")+"\n") {
		t.Fatal("rollback did not reload old file")
	}
	if err = os.Remove(filepath.Join(o.dir, "fail")); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	desired.Revision = 4
	desired.Mappings[0].LocalPort = 3391
	rejectRegistration = true
	mu.Unlock()
	if err = o.sync(); err == nil || !strings.Contains(err.Error(), "restored") || strings.Contains(err.Error(), "private-secret") {
		t.Fatal("registration failure did not safely roll back", err)
	}
	current, _ = os.ReadFile(filepath.Join(o.dir, "frpc.json"))
	if string(current) != string(previous) {
		t.Fatal("registration failure changed stored config")
	}
	mu.Lock()
	lastReport = reports[len(reports)-1]
	mu.Unlock()
	if lastReport.State != "error" || lastReport.Revision != 4 || strings.Contains(lastReport.Message, "private-secret") {
		t.Fatal("incorrect failure report", lastReport)
	}
	mu.Lock()
	desired.Revision = 1
	mu.Unlock()
	if err = o.sync(); err == nil {
		t.Fatal("accepted replayed revision")
	}
	p.Role = "visitor"
	p.DeviceID = "mac"
	if err = atomicJSON(filepath.Join(o.dir, "profile.json"), p); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	desired.Revision = 5
	rejectRegistration = false
	mu.Unlock()
	if err = o.sync(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	lastReport = reports[len(reports)-1]
	mu.Unlock()
	if lastReport.State != "configured" || !strings.Contains(lastReport.Message, "separate connection probe") {
		t.Fatal("visitor reported end-to-end success", lastReport)
	}
	// A different trusted certificate must not authorize this controller.
	other := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer other.Close()
	wrong, _ := o.client(testCertificate(other))
	// httptest uses a shared fixture certificate; an empty unrelated trust store tests the failure path.
	wrong.Transport.(*http.Transport).TLSClientConfig.RootCAs = nil
	if err = agentRequest(wrong, p.ControllerURL, "GET", "/v1/config", p.DeviceToken, nil, &applied); err == nil {
		t.Fatal("untrusted controller certificate accepted")
	}
}
