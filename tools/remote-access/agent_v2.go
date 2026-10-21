package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"
)

type agentHTTPError struct{ Status int }

func (e *agentHTTPError) Error() string { return fmt.Sprintf("controller returned HTTP %d", e.Status) }

func validateTransport(t *Transport) error {
	if t == nil {
		return nil
	}
	if validateID(t.ID) != nil || len(t.Name) > 128 {
		return errors.New("invalid transport metadata")
	}
	for _, c := range t.Name {
		if c < 32 || c == 127 {
			return errors.New("invalid transport name")
		}
	}
	return nil
}

func effectiveCapabilities(p Profile, d Desired) Capabilities {
	if d.Format == ServiceFormat && d.Capabilities != nil {
		return *d.Capabilities
	}
	if p.Capabilities != nil {
		return *p.Capabilities
	}
	return roleCapabilities(p.Role)
}

func (o agentOptions) fetchDesired(client *http.Client, p Profile, d *Desired) error {
	err := agentRequest(client, p.ControllerURL, http.MethodGet, "/v2/config", p.DeviceToken, nil, d)
	var status *agentHTTPError
	if errors.As(err, &status) && status.Status == http.StatusNotFound {
		return agentRequest(client, p.ControllerURL, http.MethodGet, "/v1/config", p.DeviceToken, nil, d)
	}
	if err == nil && d.Format != ServiceFormat {
		return errors.New("unexpected configuration format from v2 controller")
	}
	return err
}

func (o agentOptions) validateDesiredV2(p Profile, d Desired) error {
	if d.Schema != SchemaVersion || d.Format != ServiceFormat || d.DeviceID != p.DeviceID || d.Capabilities == nil || len(d.Services) > 128 || len(d.Bindings) > 128 || len(d.AvailableServices) > 4096 || len(d.Grants) > 8192 || len(d.VisitorIDs) > 4096 || len(d.Mappings) > 0 {
		return errors.New("invalid device service configuration")
	}
	caps := *d.Capabilities
	if !caps.Bind && len(d.Bindings) > 0 {
		return errors.New("device cannot bind remote services")
	}
	own, available := map[string]Service{}, map[string]Service{}
	for _, s := range d.Services {
		if err := validateService(s); err != nil {
			return err
		}
		if s.Provider != p.DeviceID || len(s.Visitors) > 32 {
			return errors.New("service belongs to another device or has too many visitors")
		}
		key := serviceKey(s.Provider, s.ID)
		if _, ok := own[key]; ok {
			return errors.New("duplicate published service")
		}
		own[key] = s
	}
	for _, s := range d.AvailableServices {
		if err := validateService(s); err != nil {
			return err
		}
		if !s.Enabled || len(s.Visitors) > 32 {
			return errors.New("invalid available service")
		}
		key := serviceKey(s.Provider, s.ID)
		if _, ok := available[key]; ok {
			return errors.New("duplicate available service")
		}
		available[key] = s
		if existing, ok := own[key]; ok && !reflect.DeepEqual(s, existing) {
			return errors.New("inconsistent service identity")
		}
		if !agentContainsID(s.Visitors, p.DeviceID) {
			return errors.New("available service does not authorize this device")
		}
	}
	grants := map[string]bool{}
	for _, g := range d.Grants {
		if validateServiceKey(g.Service) != nil || validateID(g.Visitor) != nil {
			return errors.New("invalid service grant")
		}
		if strings.HasPrefix(g.Service, p.DeviceID+"/") {
			if _, ok := own[g.Service]; !ok {
				return errors.New("grant refers to unknown published service")
			}
		} else if g.Visitor != p.DeviceID {
			return errors.New("grant belongs to another visitor")
		}
		key := g.Service + ":" + g.Visitor
		if grants[key] {
			return errors.New("duplicate service grant")
		}
		grants[key] = true
	}
	for key, s := range own {
		for _, id := range s.Visitors {
			if !grants[key+":"+id] {
				return errors.New("published service visitor lacks a grant")
			}
		}
	}
	for key := range available {
		if !grants[key+":"+p.DeviceID] {
			return errors.New("available service lacks device authorization")
		}
	}
	ids, ports := map[string]bool{}, map[string]bool{}
	for _, b := range d.Bindings {
		if err := validateBinding(b); err != nil {
			return err
		}
		if b.DeviceID != p.DeviceID || ids[b.ID] {
			return errors.New("invalid binding ownership or duplicate identifier")
		}
		ids[b.ID] = true
		if b.BindPort == o.socksPort || b.BindPort == o.httpPort || b.BindPort == o.adminPort {
			return errors.New("binding conflicts with a transport port")
		}
		if b.Enabled {
			key := net.JoinHostPort(b.BindAddr, strconv.Itoa(b.BindPort))
			if ports[key] {
				return errors.New("duplicate binding listener")
			}
			ports[key] = true
		}
	}
	visitors := map[string]bool{}
	for _, id := range d.VisitorIDs {
		if validateID(id) != nil || visitors[id] {
			return errors.New("invalid visitor catalog")
		}
		visitors[id] = true
	}
	return nil
}

func agentContainsID(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}

func activePublications(p Profile, d Desired) []Service {
	result := []Service{}
	if !effectiveCapabilities(p, d).Publish {
		return result
	}
	if d.Format == ServiceFormat {
		for _, s := range d.Services {
			if s.Provider == p.DeviceID && s.Enabled && len(s.Visitors) > 0 {
				result = append(result, s)
			}
		}
	} else {
		for _, m := range d.Mappings {
			if m.Provider == p.DeviceID {
				result = append(result, Service{ID: m.ID, Provider: m.Provider, LocalIP: m.LocalIP, LocalPort: m.LocalPort, Enabled: true, Secret: m.Secret, Visitors: m.Visitors})
			}
		}
	}
	return result
}

func (o agentOptions) frpcConfigV2(p Profile, d Desired) (map[string]any, error) {
	base, err := o.frpcConfig(p, Desired{Schema: SchemaVersion})
	if err != nil {
		return nil, err
	}
	for _, s := range activePublications(p, d) {
		base["proxies"] = append(base["proxies"].([]any), map[string]any{"name": s.ID, "type": "stcp", "localIP": s.LocalIP, "localPort": s.LocalPort, "secretKey": s.Secret, "allowUsers": s.Visitors})
	}
	available := map[string]Service{}
	for _, s := range d.AvailableServices {
		available[serviceKey(s.Provider, s.ID)] = s
	}
	if effectiveCapabilities(p, d).Bind {
		for _, b := range d.Bindings {
			s, ok := available[b.Service]
			if !b.Enabled || !ok || !s.Enabled || !agentContainsID(s.Visitors, p.DeviceID) {
				continue
			}
			base["visitors"] = append(base["visitors"].([]any), map[string]any{"name": b.ID, "type": "stcp", "serverUser": s.Provider, "serverName": s.ID, "secretKey": s.Secret, "bindAddr": b.BindAddr, "bindPort": b.BindPort})
		}
	}
	return base, nil
}

func splitVisitors(raw string) ([]string, error) {
	ids := []string{}
	if strings.TrimSpace(raw) == "" {
		return ids, nil
	}
	seen := map[string]bool{}
	for _, id := range strings.Split(raw, ",") {
		id = strings.TrimSpace(id)
		if validateID(id) != nil || seen[id] {
			return nil, errors.New("invalid or duplicate visitor")
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if len(ids) > 32 {
		return nil, errors.New("too many service visitors")
	}
	return ids, nil
}

func canonicalProjection(value any) []byte {
	b, _ := json.Marshal(value)
	var normalized any
	if json.Unmarshal(b, &normalized) != nil {
		return nil
	}
	var normalize func(any)
	normalize = func(v any) {
		switch item := v.(type) {
		case map[string]any:
			for key, child := range item {
				normalize(child)
				entries, ok := child.([]any)
				if !ok {
					continue
				}
				if key == "allowUsers" {
					sort.Slice(entries, func(i, j int) bool { return fmt.Sprint(entries[i]) < fmt.Sprint(entries[j]) })
				}
				if key == "proxies" || key == "visitors" {
					sort.Slice(entries, func(i, j int) bool {
						a, _ := entries[i].(map[string]any)
						b, _ := entries[j].(map[string]any)
						return fmt.Sprint(a["name"]) < fmt.Sprint(b["name"])
					})
				}
			}
		case []any:
			for _, child := range item {
				normalize(child)
			}
		}
	}
	normalize(normalized)
	b, _ = json.Marshal(normalized)
	return b
}

func projectedConfigEqual(a, b any) bool {
	return bytes.Equal(canonicalProjection(a), canonicalProjection(b))
}

func retainUnchangedProxies(next map[string]any, current []byte) error {
	var old map[string]any
	if json.Unmarshal(current, &old) != nil {
		return errors.New("invalid current frpc configuration")
	}
	byName := map[string]map[string]any{}
	entries, ok := old["proxies"].([]any)
	if !ok && old["proxies"] != nil {
		return errors.New("invalid current frpc proxy list")
	}
	for _, entry := range entries {
		proxy, ok := entry.(map[string]any)
		if !ok {
			return errors.New("invalid current frpc proxy")
		}
		name, ok := proxy["name"].(string)
		if !ok {
			return errors.New("invalid current frpc proxy name")
		}
		byName[name] = proxy
	}
	proxies := next["proxies"].([]any)
	for i, entry := range proxies {
		proxy := entry.(map[string]any)
		oldProxy, ok := byName[proxy["name"].(string)]
		// Preserve the live allowUsers order when another visitor or service triggers a reload.
		if ok && projectedConfigEqual(proxy, oldProxy) {
			proxies[i] = oldProxy
		}
	}
	return nil
}

func (o agentOptions) serviceChange(command string) error {
	unlock, err := o.lock()
	if err != nil {
		return err
	}
	defer unlock()
	p, err := o.profile()
	if err != nil {
		return err
	}
	client, err := o.client(p.Certificate)
	if err != nil {
		return err
	}
	method, path := http.MethodPost, ""
	var body any
	switch command {
	case "service-publish":
		visitors, err := splitVisitors(o.visitorList)
		if err != nil {
			return err
		}
		s := Service{ID: o.mappingID, Provider: p.DeviceID, LocalIP: o.targetIP, LocalPort: o.targetPort, Enabled: o.enabled, Secret: strings.Repeat("x", 32), Visitors: visitors}
		if err = validateService(s); err != nil {
			return err
		}
		path = "/v2/services"
		request := map[string]any{"id": s.ID, "local_ip": s.LocalIP, "local_port": s.LocalPort, "enabled": s.Enabled}
		if o.visitorsSpecified {
			request["visitors"] = visitors
		}
		body = request
	case "service-delete":
		if err = validateID(o.mappingID); err != nil {
			return err
		}
		method = http.MethodDelete
		path = "/v2/services/" + o.mappingID
	case "grant-set":
		if err = validateServiceKey(o.service); err != nil {
			return err
		}
		visitors, err := splitVisitors(o.visitorList)
		if err != nil {
			return err
		}
		path = "/v2/grants"
		body = map[string]any{"service": o.service, "visitors": visitors}
	case "binding-add":
		b := Binding{ID: o.mappingID, DeviceID: p.DeviceID, Service: o.service, BindAddr: o.bindAddress, BindPort: o.bindPort, Enabled: o.enabled}
		if err = validateBinding(b); err != nil {
			return err
		}
		if b.BindPort == o.socksPort || b.BindPort == o.httpPort || b.BindPort == o.adminPort {
			return errors.New("binding conflicts with transport port")
		}
		path = "/v2/bindings"
		body = b
	case "binding-delete":
		if err = validateID(o.mappingID); err != nil {
			return err
		}
		method = http.MethodDelete
		path = "/v2/bindings/" + o.mappingID
	default:
		return errors.New("unknown service command")
	}
	// The controller evaluates current capabilities; the profile is an enrollment snapshot.
	if err = agentRequest(client, p.ControllerURL, method, path, p.DeviceToken, body, nil); err != nil {
		return err
	}
	if err = o.syncUnlocked(); err != nil {
		return fmt.Errorf("service change saved; synchronization failed: %w", err)
	}
	return nil
}

func (o agentOptions) proxyExport() error {
	if o.outputFile == "" || !filepath.IsAbs(o.outputFile) {
		return errors.New("proxy-export requires an absolute --output private file")
	}
	for _, name := range []string{"profile.json", "desired.json", "transport.json", "frpc.json", "ca.pem"} {
		if filepath.Clean(o.outputFile) == filepath.Join(o.dir, name) {
			return errors.New("proxy export must not overwrite a managed configuration file")
		}
	}
	p, err := o.profile()
	if err != nil {
		return err
	}
	name := p.DeviceID + " remote transport"
	if p.Transport != nil && p.Transport.Name != "" {
		name = p.Transport.Name
	}
	u := url.URL{Scheme: "anytls", Host: net.JoinHostPort(p.Node.Server, strconv.Itoa(p.Node.Port)), User: url.User(p.Node.Password), Fragment: name}
	query := url.Values{"security": []string{"tls"}}
	if p.Node.ServerName != "" {
		query.Set("sni", p.Node.ServerName)
	}
	query.Set("insecure", "0")
	if p.Node.Insecure {
		query.Set("insecure", "1")
	}
	u.RawQuery = query.Encode()
	if err = atomicFile(o.outputFile, []byte(u.String()+"\n"), 0600); err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, "proxy link exported to private file")
	return nil
}

func safeService(s Service) map[string]any {
	visitors := s.Visitors
	if visitors == nil {
		visitors = []string{}
	}
	return map[string]any{"id": s.ID, "provider": s.Provider, "local_ip": s.LocalIP, "local_port": s.LocalPort, "enabled": s.Enabled, "visitors": visitors}
}

func (o agentOptions) statusDocument(p Profile, d Desired) map[string]any {
	mappings := []any{}
	for _, m := range d.Mappings {
		mappings = append(mappings, map[string]any{"id": m.ID, "provider": m.Provider, "local_ip": m.LocalIP, "local_port": m.LocalPort, "bind_port": m.BindPort, "visitors": m.Visitors})
	}
	visitors := d.VisitorIDs
	if visitors == nil {
		visitors = []string{}
	}
	services, available := []any{}, []any{}
	for _, s := range d.Services {
		services = append(services, safeService(s))
	}
	for _, s := range d.AvailableServices {
		available = append(available, safeService(s))
	}
	grants := d.Grants
	if grants == nil {
		grants = []Grant{}
	}
	bindings := d.Bindings
	if bindings == nil {
		bindings = []Binding{}
	}
	transport := map[string]any{"id": "legacy", "name": "Dedicated AnyTLS", "server": p.Node.Server, "port": p.Node.Port, "server_name": p.Node.ServerName}
	if p.Transport != nil {
		transport["id"] = p.Transport.ID
		if p.Transport.Name != "" {
			transport["name"] = p.Transport.Name
		}
	}
	return map[string]any{"schema": SchemaVersion, "format": d.Format, "device_id": p.DeviceID, "role": p.Role, "revision": d.Revision, "enrolled": true, "mapping_count": len(d.Mappings), "mappings": mappings, "visitor_ids": visitors, "transport": transport, "capabilities": effectiveCapabilities(p, d), "services": services, "available_services": available, "grants": grants, "bindings": bindings, "runtime": o.runtimeStatus(p, d)}
}

func (o agentOptions) runtimeStatus(p Profile, d Desired) map[string]any {
	runtime := map[string]any{"state": "staged", "admin_authenticated": false, "message": "frpc is not running; stored configuration is retained", "published": []any{}}
	statuses, err := o.frpcStatuses(p)
	if err != nil {
		conn, dialErr := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(o.adminPort), 100*time.Millisecond)
		if dialErr == nil {
			_ = conn.Close()
			runtime["state"] = "error"
			runtime["message"] = "frpc administration authentication or status validation failed"
		}
		return runtime
	}
	runtime["admin_authenticated"] = true
	runtime["state"] = "configured"
	runtime["message"] = "configuration present; remote access requires a separate connection probe"
	published := []any{}
	for _, s := range activePublications(p, d) {
		state := "pending"
		for _, entry := range statuses["stcp"] {
			if entry.Name == s.ID && entry.Type == "stcp" && entry.Status == "running" && entry.Err == "" && entry.LocalAddr == net.JoinHostPort(s.LocalIP, strconv.Itoa(s.LocalPort)) {
				state = "running"
			}
		}
		published = append(published, map[string]any{"id": s.ID, "status": state})
	}
	runtime["published"] = published
	ready, err := providerStatusesRunning(p, d, statuses)
	if err != nil || !ready {
		runtime["state"] = "error"
		runtime["message"] = "published services are not fully registered"
	} else if len(published) > 0 {
		runtime["state"] = "applied"
		runtime["message"] = "published services are registered; target reachability requires a separate connection probe"
	}
	return runtime
}
