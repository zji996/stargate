package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func v2Controller(t *testing.T) *controller {
	t.Helper()
	c := testController(t)
	testDevices(t, c)
	migrateServerState(&c.state)
	if err := c.commit(c.state); err != nil {
		t.Fatal(err)
	}
	return c
}

func v2Config(t *testing.T, c *controller, id string) Desired {
	t.Helper()
	r := controllerRequest(t, c, http.MethodGet, "/v2/config", c.state.Devices[id].Token, nil)
	expectCode(t, r, http.StatusOK)
	var d Desired
	if err := json.Unmarshal(r.Body.Bytes(), &d); err != nil {
		t.Fatal(err)
	}
	return d
}

func publishService(t *testing.T, c *controller, provider, id string, visitors []string) {
	t.Helper()
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/services", c.state.Devices[provider].Token, map[string]any{"id": id, "local_ip": "10.23.0.10", "local_port": 3389, "enabled": true, "visitors": visitors}), http.StatusOK)
}

func bindService(t *testing.T, c *controller, device, id, service string, port int) {
	t.Helper()
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/bindings", c.state.Devices[device].Token, Binding{ID: id, Service: service, BindAddr: "127.0.0.1", BindPort: port, Enabled: true}), http.StatusOK)
}

func setCapabilities(t *testing.T, c *controller, id string, publish, bind bool, visitors []string) {
	t.Helper()
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/capabilities", c.state.AdminToken, map[string]any{"device_id": id, "publish": publish, "bind": bind, "allowed_visitors": visitors}), http.StatusOK)
}

func TestV2IndependentPublishingAndBindings(t *testing.T) {
	c := v2Controller(t)
	publishService(t, c, "router", "windows", []string{"laptop", "tablet"})
	if len(c.state.Bindings) != 0 {
		t.Fatal("publishing automatically created a visitor listener")
	}
	before := c.state.Services["router/windows"]
	d := v2Config(t, c, "laptop")
	if d.Format != ServiceFormat || d.DeviceID != "laptop" || !d.Capabilities.Bind || d.Capabilities.Publish || len(d.AvailableServices) != 1 || len(d.Bindings) != 0 || len(d.Grants) != 1 {
		t.Error("invalid visitor discovery configuration")
	}
	bindService(t, c, "laptop", "desktop", "router/windows", 13389)
	bindService(t, c, "tablet", "desktop", "router/windows", 23389)
	bindService(t, c, "laptop", "desktop", "router/windows", 33389)
	if c.state.Bindings["tablet/desktop"].BindPort != 23389 || c.state.Services["router/windows"].Secret != before.Secret {
		t.Error("visitor port update changed another visitor or the service secret")
	}
	if c.state.Bindings["laptop/desktop"].BindPort != 33389 {
		t.Error("visitor port was not updated")
	}
	d = v2Config(t, c, "router")
	if len(d.Services) != 1 || len(d.Services[0].Visitors) != 2 || len(d.Bindings) != 0 || len(d.AvailableServices) != 0 {
		t.Error("publisher received automatic bind permissions")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/bindings", c.state.Devices["laptop"].Token, Binding{ID: "duplicate", Service: "router/windows", BindAddr: "127.0.0.1", BindPort: 33389, Enabled: true}), http.StatusConflict)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/bindings", c.state.Devices["laptop"].Token, Binding{ID: "foreign", DeviceID: "tablet", Service: "router/windows", BindAddr: "127.0.0.1", BindPort: 33390, Enabled: true}), http.StatusForbidden)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/bindings", c.state.Devices["other"].Token, Binding{ID: "foreign", Service: "router/windows", BindAddr: "127.0.0.1", BindPort: 33390, Enabled: true}), http.StatusForbidden)
	for _, addr := range []string{"0.0.0.0", "10.23.0.20"} {
		expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/bindings", c.state.Devices["laptop"].Token, Binding{ID: "public", Service: "router/windows", BindAddr: addr, BindPort: 33390, Enabled: true}), http.StatusBadRequest)
	}
	expectCode(t, controllerRequest(t, c, http.MethodDelete, "/v2/bindings/desktop", c.state.Devices["laptop"].Token, nil), http.StatusOK)
	if _, ok := c.state.Bindings["tablet/desktop"]; !ok {
		t.Error("deleting own binding removed another visitor binding")
	}
}

func TestV2BothCapabilitiesAndScopedServices(t *testing.T) {
	c := v2Controller(t)
	setCapabilities(t, c, "router", true, true, []string{"laptop", "tablet"})
	setCapabilities(t, c, "laptop", true, true, []string{"router"})
	publishService(t, c, "router", "windows", []string{"laptop"})
	publishService(t, c, "laptop", "windows", []string{"router"})
	if len(c.state.Services) != 2 {
		t.Fatal("same service ID across providers collided")
	}
	bindService(t, c, "router", "laptopdesktop", "laptop/windows", 23389)
	bindService(t, c, "laptop", "routerdesktop", "router/windows", 13389)
	for _, id := range []string{"router", "laptop"} {
		d := v2Config(t, c, id)
		if !d.Capabilities.Publish || !d.Capabilities.Bind || len(d.Services) != 1 || len(d.AvailableServices) != 1 || len(d.Bindings) != 1 {
			t.Errorf("%s cannot publish and bind independently", id)
		}
	}
	service := c.state.Services["laptop/windows"]
	user := pluginUser{User: "laptop", Metas: map[string]string{"device_token": c.state.Devices["laptop"].Token}}
	content := map[string]any{"user": user, "proxy_name": "laptop.windows", "proxy_type": "stcp", "sk": service.Secret, "allow_users": []string{"router"}}
	if !pluginAllowed(t, c, "NewProxy", content) {
		t.Error("both-capability provider registration rejected")
	}
	content["allow_users"] = []string{"*"}
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("both-capability provider bypassed precise grants")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/grants", c.state.Devices["laptop"].Token, map[string]any{"service": "router/windows", "visitors": []string{"router"}}), http.StatusForbidden)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/services", c.state.Devices["tablet"].Token, map[string]any{"id": "windows", "local_ip": "10.23.0.10", "local_port": 3389, "enabled": true}), http.StatusForbidden)
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/grants", c.state.Devices["router"].Token, map[string]any{"service": "router/windows", "visitors": []string{"other"}}), http.StatusForbidden)
}

func TestV2AuthorizationReductionAndDisabledServices(t *testing.T) {
	c := v2Controller(t)
	publishService(t, c, "router", "windows", []string{"laptop", "tablet"})
	bindService(t, c, "laptop", "desktop", "router/windows", 13389)
	bindService(t, c, "tablet", "desktop", "router/windows", 23389)
	old := c.state.Services["router/windows"].Secret
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/grants", c.state.Devices["router"].Token, map[string]any{"service": "router/windows", "visitors": []string{"tablet"}}), http.StatusOK)
	if old == c.state.Services["router/windows"].Secret {
		t.Error("grant removal did not rotate secret")
	}
	if _, ok := c.state.Bindings["laptop/desktop"]; ok {
		t.Error("grant removal retained unauthorized binding")
	}
	if len(v2Config(t, c, "laptop").AvailableServices) != 0 {
		t.Error("removed visitor can still discover the service")
	}
	old = c.state.Services["router/windows"].Secret
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/services", c.state.Devices["router"].Token, map[string]any{"id": "windows", "local_ip": "10.23.0.10", "local_port": 3389, "enabled": false}), http.StatusOK)
	if old == c.state.Services["router/windows"].Secret || len(v2Config(t, c, "tablet").AvailableServices) != 0 || len(v2Config(t, c, "tablet").Bindings) != 1 {
		t.Error("disabled service did not retain independent binding while removing availability")
	}
	user := pluginUser{User: "router", Metas: map[string]string{"device_token": c.state.Devices["router"].Token}}
	content := map[string]any{"user": user, "proxy_name": "router.windows", "proxy_type": "stcp", "sk": c.state.Services["router/windows"].Secret, "allow_users": []string{"tablet"}}
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("disabled service registered")
	}
	publishService(t, c, "router", "windows", []string{"tablet"})
	old = c.state.Services["router/windows"].Secret
	setCapabilities(t, c, "tablet", false, false, nil)
	if old == c.state.Services["router/windows"].Secret || len(c.state.Bindings) != 0 || len(grantedVisitors(c.state, "router/windows")) != 0 {
		t.Error("bind capability removal did not retire authorization")
	}
	if pluginAllowed(t, c, "NewProxy", content) {
		t.Error("service without active visitors registered")
	}
	if c.state.Devices["tablet"].Role != "none" {
		t.Error("empty capabilities have incorrect role")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/bindings", c.state.Devices["tablet"].Token, Binding{ID: "desktop", Service: "router/windows", BindAddr: "127.0.0.1", BindPort: 23389, Enabled: true}), http.StatusForbidden)
	setCapabilities(t, c, "router", false, false, nil)
	if pluginAllowed(t, c, "NewWorkConn", map[string]any{"user": user}) {
		t.Error("publish capability removal permitted new provider work")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/services", c.state.Devices["router"].Token, map[string]any{"id": "windows", "local_ip": "10.23.0.10", "local_port": 3389, "enabled": true}), http.StatusForbidden)
}

func TestV2PublisherDelegationReductionAndRevoke(t *testing.T) {
	c := v2Controller(t)
	publishService(t, c, "router", "windows", []string{"laptop", "tablet"})
	bindService(t, c, "laptop", "desktop", "router/windows", 13389)
	bindService(t, c, "tablet", "desktop", "router/windows", 23389)
	before := c.state.Services["router/windows"].Secret
	setCapabilities(t, c, "router", true, false, []string{"tablet"})
	if c.state.Services["router/windows"].Secret == before || len(c.state.Bindings) != 1 || len(grantedVisitors(c.state, "router/windows")) != 1 {
		t.Error("reduced delegation retained visitor access")
	}
	before = c.state.Services["router/windows"].Secret
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/revoke", c.state.AdminToken, map[string]string{"device_id": "router"}), http.StatusOK)
	if c.state.Services["router/windows"].Secret == before || len(c.state.Bindings) != 0 || len(v2Config(t, c, "tablet").AvailableServices) != 0 {
		t.Error("publisher revocation retained a live service or binding")
	}
	user := pluginUser{User: "router", Metas: map[string]string{"device_token": c.state.Devices["router"].Token}}
	if pluginAllowed(t, c, "NewWorkConn", map[string]any{"user": user}) {
		t.Error("revoked publisher opened work connection")
	}
}

func TestV2LegacyMigrationAndEnrollment(t *testing.T) {
	c := v2Controller(t)
	mapping := sampleMapping()
	mapping.Secret = randomToken()
	c.state.Format = 0
	c.state.Services = nil
	c.state.Grants = nil
	c.state.Bindings = nil
	c.state.Transport = Transport{}
	c.state.Mappings = map[string]Mapping{mapping.ID: mapping}
	for id, device := range c.state.Devices {
		device.Capabilities = nil
		c.state.Devices[id] = device
	}
	pending := randomToken()
	c.state.Enrollments[pending] = serverEnrollment{DeviceID: "newvisitor", Role: "visitor", ExpiresAt: c.now().Unix() + 60}
	revision := c.state.Revision
	if err := atomicJSON(filepath.Join(c.dir, "server.json"), c.state); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadController(c.dir)
	if err != nil {
		t.Fatal(err)
	}
	loaded.now = c.now
	c = loaded
	if c.state.Revision != revision || c.state.Format != ServiceFormat || c.state.Services["router/windows"].Secret != mapping.Secret || len(c.state.Bindings) != 2 || len(c.state.Grants) != 2 {
		t.Fatal("migration altered revision, secret or existing bindings")
	}
	for _, id := range []string{"laptop", "tablet"} {
		if c.state.Bindings[id+"/windows"].BindPort != mapping.BindPort {
			t.Error("migration changed a legacy visitor port")
		}
	}
	for _, id := range []string{"router", "laptop"} {
		r := controllerRequest(t, c, http.MethodGet, "/v1/config", c.state.Devices[id].Token, nil)
		expectCode(t, r, http.StatusOK)
		var d Desired
		json.Unmarshal(r.Body.Bytes(), &d)
		if d.Schema != SchemaVersion || d.Format != 0 || len(d.Mappings) != 1 || d.Mappings[0].Secret != mapping.Secret {
			t.Error("legacy config projection incompatible")
		}
	}
	r := controllerRequest(t, c, http.MethodPost, "/v2/enroll", "", map[string]string{"token": pending})
	expectCode(t, r, http.StatusOK)
	var p Profile
	if err := json.Unmarshal(r.Body.Bytes(), &p); err != nil {
		t.Fatal(err)
	}
	if p.Node != c.state.Node || p.Transport == nil || p.Transport.ID != "default" || p.Capabilities == nil || !p.Capabilities.Bind {
		t.Error("legacy token lost fixed transport or capabilities")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/enroll", "", map[string]string{"token": pending}), http.StatusUnauthorized)
	mapping.BindPort = 23390
	mapping.Secret = ""
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/mappings", c.state.Devices["router"].Token, mapping), http.StatusOK)
	if c.state.Bindings["laptop/windows"].BindPort != 23390 || c.state.Bindings["tablet/windows"].BindPort != 23390 {
		t.Error("legacy mapping bridge failed to update visitor ports")
	}
	expectCode(t, controllerRequest(t, c, http.MethodDelete, "/v1/mappings/windows", c.state.Devices["router"].Token, nil), http.StatusOK)
	if len(c.state.Services) != 0 || len(c.state.Bindings) != 0 || len(c.state.Grants) != 0 {
		t.Error("legacy delete left canonical objects")
	}
}

func TestV1BindingProjectionIsStable(t *testing.T) {
	c := v2Controller(t)
	setCapabilities(t, c, "otherrouter", true, false, []string{"laptop"})
	publishService(t, c, "router", "windows", []string{"laptop"})
	publishService(t, c, "otherrouter", "windows", []string{"laptop"})
	bindService(t, c, "laptop", "zrouter", "router/windows", 23389)
	bindService(t, c, "laptop", "windows", "router/windows", 13389)
	bindService(t, c, "laptop", "aother", "otherrouter/windows", 33389)
	assertStable := func(provider string, port int) {
		t.Helper()
		revision := c.state.Revision
		var first []byte
		for i := 0; i < 100; i++ {
			r := controllerRequest(t, c, http.MethodGet, "/v1/config", c.state.Devices["laptop"].Token, nil)
			expectCode(t, r, http.StatusOK)
			var d Desired
			if err := json.Unmarshal(r.Body.Bytes(), &d); err != nil {
				t.Fatal(err)
			}
			if d.Revision != revision || len(d.Mappings) != 1 || d.Mappings[0].Provider != provider || d.Mappings[0].BindPort != port || d.Mappings[0].Secret != c.state.Services[serviceKey(provider, "windows")].Secret {
				t.Fatal("legacy projection selected an unexpected binding")
			}
			if i == 0 {
				first = append([]byte(nil), r.Body.Bytes()...)
			} else if !bytes.Equal(first, r.Body.Bytes()) {
				t.Fatal("same-revision legacy projection changed")
			}
		}
	}
	assertStable("router", 13389)
	expectCode(t, controllerRequest(t, c, http.MethodDelete, "/v2/bindings/windows", c.state.Devices["laptop"].Token, nil), http.StatusOK)
	assertStable("otherrouter", 33389)
}

func TestV2EnrollmentMetadataAndNoSelfGrantedCapabilities(t *testing.T) {
	c := v2Controller(t)
	r := controllerRequest(t, c, http.MethodPost, "/v1/admin/enrollment", c.state.AdminToken, map[string]any{"device_id": "dual", "role": "both", "new_schema": EnrollmentVersion, "allowed_visitors": []string{"dual"}})
	expectCode(t, r, http.StatusOK)
	var response struct {
		Link string `json:"link"`
	}
	json.Unmarshal(r.Body.Bytes(), &response)
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(response.Link, "stargate://enroll/"))
	if err != nil {
		t.Fatal(err)
	}
	var bootstrap Bootstrap
	if err = json.Unmarshal(b, &bootstrap); err != nil {
		t.Fatal(err)
	}
	if bootstrap.Schema != EnrollmentVersion || bootstrap.Transport == nil || bootstrap.Node != c.state.Node {
		t.Error("new link lacks fixed transport snapshot")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/enroll", "", map[string]any{"token": bootstrap.EnrollmentToken, "capabilities": Capabilities{Publish: true, Bind: true}}), http.StatusBadRequest)
	r = controllerRequest(t, c, http.MethodPost, "/v2/enroll", "", map[string]string{"token": bootstrap.EnrollmentToken})
	expectCode(t, r, http.StatusOK)
	var profile Profile
	json.Unmarshal(r.Body.Bytes(), &profile)
	if profile.Schema != SchemaVersion || profile.Role != "both" || profile.Capabilities == nil || !profile.Capabilities.Publish || !profile.Capabilities.Bind {
		t.Error("dual capability enrollment incorrect")
	}
	if len(c.state.Bindings) != 0 {
		t.Error("enrollment assigned automatic listeners")
	}
	expectCode(t, controllerRequest(t, c, http.MethodPost, "/v1/admin/capabilities", profile.DeviceToken, map[string]any{"device_id": "dual", "publish": true}), http.StatusUnauthorized)
}

func TestV2QuotasAndTransactionalSave(t *testing.T) {
	t.Run("services", func(t *testing.T) {
		c := v2Controller(t)
		for i := 0; i < 128; i++ {
			id := fmt.Sprintf("service%03d", i)
			c.state.Services[serviceKey("router", id)] = Service{ID: id, Provider: "router", LocalIP: "10.23.0.10", LocalPort: 3389, Enabled: true, Secret: randomToken()}
		}
		expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/services", c.state.Devices["router"].Token, map[string]any{"id": "overflow", "local_ip": "10.23.0.10", "local_port": 3389, "enabled": true}), http.StatusConflict)
		publishService(t, c, "router", "service000", nil)
	})
	t.Run("bindings", func(t *testing.T) {
		c := v2Controller(t)
		publishService(t, c, "router", "windows", []string{"laptop"})
		for i := 0; i < 128; i++ {
			id := fmt.Sprintf("binding%03d", i)
			c.state.Bindings[bindingKey("laptop", id)] = Binding{ID: id, DeviceID: "laptop", Service: "router/windows", BindAddr: "127.0.0.1", BindPort: 20000 + i, Enabled: true}
		}
		expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/bindings", c.state.Devices["laptop"].Token, Binding{ID: "overflow", Service: "router/windows", BindAddr: "127.0.0.1", BindPort: 25000, Enabled: true}), http.StatusConflict)
		bindService(t, c, "laptop", "binding000", "router/windows", 25000)
	})
	t.Run("failed persistence", func(t *testing.T) {
		c := v2Controller(t)
		publishService(t, c, "router", "windows", []string{"laptop"})
		bindService(t, c, "laptop", "desktop", "router/windows", 13389)
		before, _ := json.Marshal(c.state)
		if err := os.Remove(filepath.Join(c.dir, "server.json")); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(c.dir, "server.json"), 0700); err != nil {
			t.Fatal(err)
		}
		expectCode(t, controllerRequest(t, c, http.MethodPost, "/v2/grants", c.state.Devices["router"].Token, map[string]any{"service": "router/windows", "visitors": []string{}}), http.StatusInternalServerError)
		after, _ := json.Marshal(c.state)
		if !bytes.Equal(before, after) {
			t.Error("failed grant rotation mutated live configuration")
		}
	})
}
