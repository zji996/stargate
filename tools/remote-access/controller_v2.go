package main

import (
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
)

func deviceCapabilities(device serverDevice) Capabilities {
	if device.Capabilities != nil {
		return *device.Capabilities
	}
	return roleCapabilities(device.Role)
}

func capabilityRole(caps Capabilities) string {
	if caps.Publish && caps.Bind {
		return "both"
	}
	if caps.Publish {
		return "provider"
	}
	if caps.Bind {
		return "visitor"
	}
	return "none"
}

func grantKey(service, visitor string) string { return service + "/" + visitor }
func bindingKey(device, id string) string     { return device + "/" + id }

// Legacy maps are imported once. Later updates use services, grants and bindings as the source of truth.
func migrateServerState(state *serverState) bool {
	changed := false
	if state.Transport.ID == "" {
		state.Transport = Transport{ID: "default", Name: "server"}
		changed = true
	}
	for id, device := range state.Devices {
		if device.Capabilities == nil {
			caps := roleCapabilities(device.Role)
			device.Capabilities = &caps
			state.Devices[id] = device
			changed = true
		}
	}
	for token, enrollment := range state.Enrollments {
		if enrollment.Capabilities == nil {
			caps := roleCapabilities(enrollment.Role)
			enrollment.Capabilities = &caps
			state.Enrollments[token] = enrollment
			changed = true
		}
	}
	if state.Format == ServiceFormat {
		if state.Services == nil {
			state.Services = map[string]Service{}
			changed = true
		}
		if state.Grants == nil {
			state.Grants = map[string]Grant{}
			changed = true
		}
		if state.Bindings == nil {
			state.Bindings = map[string]Binding{}
			changed = true
		}
		return changed
	}
	state.Services = map[string]Service{}
	state.Grants = map[string]Grant{}
	state.Bindings = map[string]Binding{}
	for _, mapping := range state.Mappings {
		key := serviceKey(mapping.Provider, mapping.ID)
		state.Services[key] = Service{ID: mapping.ID, Provider: mapping.Provider, LocalIP: mapping.LocalIP, LocalPort: mapping.LocalPort, Enabled: true, Secret: mapping.Secret}
		for _, visitor := range mapping.Visitors {
			state.Grants[grantKey(key, visitor)] = Grant{Service: key, Visitor: visitor}
			state.Bindings[bindingKey(visitor, mapping.ID)] = Binding{ID: mapping.ID, DeviceID: visitor, Service: key, BindAddr: "127.0.0.1", BindPort: mapping.BindPort, Enabled: true}
		}
	}
	state.Format = ServiceFormat
	return true
}

func (c *controller) ensureCanonical(w http.ResponseWriter) bool {
	next := c.candidate()
	if !migrateServerState(&next) {
		return true
	}
	if err := c.commit(next); err != nil {
		apiError(w, http.StatusInternalServerError, "failed to migrate server state")
		return false
	}
	return true
}

func stateServiceVisitors(state serverState, key string) []string {
	visitors := []string{}
	for _, grant := range state.Grants {
		device, ok := state.Devices[grant.Visitor]
		if grant.Service == key && ok && device.Enabled && deviceCapabilities(device).Bind {
			visitors = append(visitors, grant.Visitor)
		}
	}
	sort.Strings(visitors)
	return visitors
}

func stateServiceActive(state serverState, service Service) bool {
	provider, ok := state.Devices[service.Provider]
	return ok && provider.Enabled && deviceCapabilities(provider).Publish && service.Enabled
}

func syncLegacyMappings(state *serverState) {
	for id, mapping := range state.Mappings {
		key := serviceKey(mapping.Provider, mapping.ID)
		service, exists := state.Services[key]
		if !exists {
			delete(state.Mappings, id)
			continue
		}
		mapping.LocalIP = service.LocalIP
		mapping.LocalPort = service.LocalPort
		mapping.Secret = service.Secret
		mapping.Visitors = stateServiceVisitors(*state, key)
		state.Mappings[id] = mapping
	}
}

func removeService(state *serverState, key string) {
	delete(state.Services, key)
	for id, grant := range state.Grants {
		if grant.Service == key {
			delete(state.Grants, id)
		}
	}
	for id, binding := range state.Bindings {
		if binding.Service == key {
			delete(state.Bindings, id)
		}
	}
}

func removeVisitorGrant(state *serverState, key, visitor string) {
	delete(state.Grants, grantKey(key, visitor))
	for id, binding := range state.Bindings {
		if binding.Service == key && binding.DeviceID == visitor {
			delete(state.Bindings, id)
		}
	}
}

func grantedVisitors(state serverState, key string) []string {
	ids := []string{}
	for _, grant := range state.Grants {
		if grant.Service == key {
			ids = append(ids, grant.Visitor)
		}
	}
	sort.Strings(ids)
	return ids
}

func validateVisitorGrants(state serverState, actor serverDevice, visitors []string, pending bool, now int64) error {
	if len(visitors) > 32 {
		return errors.New("too many visitor grants")
	}
	seen := map[string]bool{}
	for _, id := range visitors {
		if validateID(id) != nil || seen[id] {
			return errors.New("invalid or duplicate visitor grant")
		}
		seen[id] = true
		device, ok := state.Devices[id]
		valid := ok && device.Enabled && deviceCapabilities(device).Bind
		if pending && !ok {
			if id == actor.ID && deviceCapabilities(actor).Bind {
				valid = true
			}
			for _, enrollment := range state.Enrollments {
				caps := roleCapabilities(enrollment.Role)
				if enrollment.Capabilities != nil {
					caps = *enrollment.Capabilities
				}
				if enrollment.DeviceID == id && caps.Bind && enrollment.ExpiresAt > now {
					valid = true
					break
				}
			}
		}
		if !valid {
			return errors.New("visitor grant requires an enabled binding device")
		}
	}
	return nil
}

func replaceServiceGrants(state *serverState, key string, visitors []string) error {
	old := grantedVisitors(*state, key)
	removed := false
	for _, id := range old {
		if !containsID(visitors, id) {
			removeVisitorGrant(state, key, id)
			removed = true
		}
	}
	for _, id := range visitors {
		state.Grants[grantKey(key, id)] = Grant{Service: key, Visitor: id}
	}
	if removed {
		service := state.Services[key]
		service.Secret = randomToken()
		state.Services[key] = service
	}
	for _, visitor := range visitors {
		count := 0
		for _, grant := range state.Grants {
			if grant.Visitor == visitor {
				count++
			}
		}
		if count > 128 {
			return errors.New("per-device service grant capacity reached (128)")
		}
	}
	return nil
}

func validateServerQuotas(state serverState) error {
	if len(state.Services) > 256 || len(state.Bindings) > 512 {
		return errors.New("server service or binding capacity reached")
	}
	providers, visitors, bindings := map[string]int{}, map[string]int{}, map[string]int{}
	for _, service := range state.Services {
		providers[service.Provider]++
	}
	for _, grant := range state.Grants {
		visitors[grant.Visitor]++
	}
	for _, binding := range state.Bindings {
		bindings[binding.DeviceID]++
	}
	for _, counts := range []map[string]int{providers, visitors, bindings} {
		for _, n := range counts {
			if n > 128 {
				return errors.New("per-device service or binding capacity reached (128)")
			}
		}
	}
	ports := map[string]bool{}
	for _, binding := range state.Bindings {
		if !binding.Enabled {
			continue
		}
		key := fmt.Sprintf("%s/%s/%d", binding.DeviceID, binding.BindAddr, binding.BindPort)
		if ports[key] {
			return errors.New("device binding address and port conflict")
		}
		ports[key] = true
	}
	return nil
}

func (c *controller) desiredV2(device serverDevice) Desired {
	caps := deviceCapabilities(device)
	desired := Desired{Schema: SchemaVersion, Format: ServiceFormat, Revision: c.state.Revision, DeviceID: device.ID, Capabilities: &caps, Mappings: []Mapping{}, Services: []Service{}, AvailableServices: []Service{}, Grants: []Grant{}, Bindings: []Binding{}}
	for key, service := range c.state.Services {
		service.Visitors = stateServiceVisitors(c.state, key)
		if service.Provider == device.ID {
			desired.Services = append(desired.Services, service)
		}
		if caps.Bind && stateServiceActive(c.state, service) && containsID(service.Visitors, device.ID) {
			desired.AvailableServices = append(desired.AvailableServices, service)
		}
	}
	if caps.Publish {
		for _, id := range device.AllowedVisitors {
			if visitor, ok := c.state.Devices[id]; ok && visitor.Enabled && deviceCapabilities(visitor).Bind {
				desired.VisitorIDs = append(desired.VisitorIDs, id)
			}
		}
	}
	for _, grant := range c.state.Grants {
		if service, ok := c.state.Services[grant.Service]; ok && (service.Provider == device.ID || (caps.Bind && grant.Visitor == device.ID && stateServiceActive(c.state, service))) {
			desired.Grants = append(desired.Grants, grant)
		}
	}
	if caps.Bind {
		for _, binding := range c.state.Bindings {
			if binding.DeviceID == device.ID {
				desired.Bindings = append(desired.Bindings, binding)
			}
		}
	}
	sort.Slice(desired.Services, func(i, j int) bool { return desired.Services[i].ID < desired.Services[j].ID })
	sort.Slice(desired.AvailableServices, func(i, j int) bool {
		return serviceKey(desired.AvailableServices[i].Provider, desired.AvailableServices[i].ID) < serviceKey(desired.AvailableServices[j].Provider, desired.AvailableServices[j].ID)
	})
	sort.Slice(desired.Grants, func(i, j int) bool {
		return grantKey(desired.Grants[i].Service, desired.Grants[i].Visitor) < grantKey(desired.Grants[j].Service, desired.Grants[j].Visitor)
	})
	sort.Slice(desired.Bindings, func(i, j int) bool { return desired.Bindings[i].ID < desired.Bindings[j].ID })
	sort.Strings(desired.VisitorIDs)
	return desired
}

func (c *controller) legacyDesired(device serverDevice) Desired {
	desired := Desired{Schema: SchemaVersion, Revision: c.state.Revision, Mappings: []Mapping{}}
	caps := deviceCapabilities(device)
	if caps.Publish {
		for _, id := range device.AllowedVisitors {
			if d, ok := c.state.Devices[id]; ok && d.Enabled && deviceCapabilities(d).Bind {
				desired.VisitorIDs = append(desired.VisitorIDs, id)
			}
		}
		for key, service := range c.state.Services {
			visitors := stateServiceVisitors(c.state, key)
			if service.Provider != device.ID || !stateServiceActive(c.state, service) || len(visitors) == 0 {
				continue
			}
			port := 13389
			if old, ok := c.state.Mappings[service.ID]; ok && old.Provider == service.Provider {
				port = old.BindPort
			}
			desired.Mappings = append(desired.Mappings, Mapping{ID: service.ID, Provider: service.Provider, LocalIP: service.LocalIP, LocalPort: service.LocalPort, BindPort: port, Visitors: visitors, Secret: service.Secret})
		}
	} else if caps.Bind {
		seenIDs := map[string]bool{}
		bindings := []Binding{}
		for _, binding := range c.state.Bindings {
			if binding.DeviceID == device.ID && binding.Enabled {
				bindings = append(bindings, binding)
			}
		}
		// Legacy clients have one name per service ID; preserve their original named binding first.
		sort.Slice(bindings, func(i, j int) bool {
			a, b := bindings[i], bindings[j]
			aLegacy, bLegacy := a.ID == c.state.Services[a.Service].ID, b.ID == c.state.Services[b.Service].ID
			if aLegacy != bLegacy {
				return aLegacy
			}
			return bindingKey(a.DeviceID, a.ID) < bindingKey(b.DeviceID, b.ID)
		})
		for _, binding := range bindings {
			service, ok := c.state.Services[binding.Service]
			if binding.DeviceID != device.ID || !binding.Enabled || !ok || !stateServiceActive(c.state, service) || !containsID(stateServiceVisitors(c.state, binding.Service), device.ID) {
				continue
			}
			if seenIDs[service.ID] {
				continue
			}
			seenIDs[service.ID] = true
			desired.Mappings = append(desired.Mappings, Mapping{ID: service.ID, Provider: service.Provider, LocalIP: service.LocalIP, LocalPort: service.LocalPort, BindPort: binding.BindPort, Visitors: stateServiceVisitors(c.state, binding.Service), Secret: service.Secret})
		}
	}
	sort.Slice(desired.Mappings, func(i, j int) bool { return desired.Mappings[i].ID < desired.Mappings[j].ID })
	sort.Strings(desired.VisitorIDs)
	return desired
}

func (c *controller) v2API(w http.ResponseWriter, r *http.Request, device serverDevice) {
	switch {
	case r.URL.Path == "/v2/config" && r.Method == http.MethodGet:
		jsonResponse(w, http.StatusOK, c.desiredV2(device))
	case r.URL.Path == "/v2/services" && r.Method == http.MethodPost:
		c.saveService(w, r, device)
	case strings.HasPrefix(r.URL.Path, "/v2/services/") && r.Method == http.MethodDelete:
		id := strings.TrimPrefix(r.URL.Path, "/v2/services/")
		if validateID(id) != nil {
			apiError(w, http.StatusBadRequest, "invalid service identifier")
			return
		}
		if !deviceCapabilities(device).Publish {
			apiError(w, http.StatusForbidden, "publish capability required")
			return
		}
		key := serviceKey(device.ID, id)
		if _, ok := c.state.Services[key]; !ok {
			apiError(w, http.StatusNotFound, "service not found")
			return
		}
		next := c.candidate()
		removeService(&next, key)
		c.finishV2(w, next)
	case r.URL.Path == "/v2/grants" && r.Method == http.MethodPost:
		c.saveGrants(w, r, device)
	case r.URL.Path == "/v2/bindings" && r.Method == http.MethodPost:
		c.saveBinding(w, r, device)
	case strings.HasPrefix(r.URL.Path, "/v2/bindings/") && r.Method == http.MethodDelete:
		id := strings.TrimPrefix(r.URL.Path, "/v2/bindings/")
		if validateID(id) != nil {
			apiError(w, http.StatusBadRequest, "invalid binding identifier")
			return
		}
		if !deviceCapabilities(device).Bind {
			apiError(w, http.StatusForbidden, "bind capability required")
			return
		}
		key := bindingKey(device.ID, id)
		if _, ok := c.state.Bindings[key]; !ok {
			apiError(w, http.StatusNotFound, "binding not found")
			return
		}
		next := c.candidate()
		delete(next.Bindings, key)
		c.finishV2(w, next)
	default:
		apiError(w, http.StatusNotFound, "not found")
	}
}

func (c *controller) finishV2(w http.ResponseWriter, next serverState) {
	if err := validateServerQuotas(next); err != nil {
		apiError(w, http.StatusConflict, err.Error())
		return
	}
	next.Revision++
	if err := c.commit(next); err != nil {
		apiError(w, http.StatusInternalServerError, "failed to save configuration")
		return
	}
	jsonResponse(w, http.StatusOK, map[string]uint64{"revision": next.Revision})
}

func (c *controller) saveService(w http.ResponseWriter, r *http.Request, device serverDevice) {
	if !deviceCapabilities(device).Publish {
		apiError(w, http.StatusForbidden, "publish capability required")
		return
	}
	var req struct {
		ID        string    `json:"id"`
		LocalIP   string    `json:"local_ip"`
		LocalPort int       `json:"local_port"`
		Enabled   bool      `json:"enabled"`
		Visitors  *[]string `json:"visitors"`
	}
	if err := decodeRequest(w, r, &req); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	key := serviceKey(device.ID, req.ID)
	old, exists := c.state.Services[key]
	service := Service{ID: req.ID, Provider: device.ID, LocalIP: req.LocalIP, LocalPort: req.LocalPort, Enabled: req.Enabled, Secret: old.Secret}
	if !exists || (old.Enabled && !service.Enabled) {
		service.Secret = randomToken()
	}
	if err := validateService(service); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Visitors != nil {
		if err := validateVisitorGrants(c.state, device, *req.Visitors, false, c.now().Unix()); err != nil {
			apiError(w, http.StatusBadRequest, err.Error())
			return
		}
		for _, id := range *req.Visitors {
			if !containsID(device.AllowedVisitors, id) {
				apiError(w, http.StatusForbidden, "visitor outside publisher grants")
				return
			}
		}
	}
	next := c.candidate()
	next.Services[key] = service
	if req.Visitors != nil {
		if err := replaceServiceGrants(&next, key, *req.Visitors); err != nil {
			apiError(w, http.StatusConflict, err.Error())
			return
		}
	}
	c.finishV2(w, next)
}

func (c *controller) saveGrants(w http.ResponseWriter, r *http.Request, device serverDevice) {
	if !deviceCapabilities(device).Publish {
		apiError(w, http.StatusForbidden, "publish capability required")
		return
	}
	var req struct {
		Service  string   `json:"service"`
		Visitors []string `json:"visitors"`
	}
	if err := decodeRequest(w, r, &req); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	service, ok := c.state.Services[req.Service]
	if validateServiceKey(req.Service) != nil {
		apiError(w, http.StatusBadRequest, "invalid service identifier")
		return
	}
	if !ok {
		apiError(w, http.StatusNotFound, "service not found")
		return
	}
	if service.Provider != device.ID {
		apiError(w, http.StatusForbidden, "service belongs to another publisher")
		return
	}
	if err := validateVisitorGrants(c.state, device, req.Visitors, false, c.now().Unix()); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	for _, id := range req.Visitors {
		if !containsID(device.AllowedVisitors, id) {
			apiError(w, http.StatusForbidden, "visitor outside publisher grants")
			return
		}
	}
	next := c.candidate()
	if err := replaceServiceGrants(&next, req.Service, req.Visitors); err != nil {
		apiError(w, http.StatusConflict, err.Error())
		return
	}
	c.finishV2(w, next)
}

func (c *controller) saveBinding(w http.ResponseWriter, r *http.Request, device serverDevice) {
	if !deviceCapabilities(device).Bind {
		apiError(w, http.StatusForbidden, "bind capability required")
		return
	}
	var binding Binding
	if err := decodeRequest(w, r, &binding); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	if binding.DeviceID != "" && binding.DeviceID != device.ID {
		apiError(w, http.StatusForbidden, "binding belongs to another device")
		return
	}
	binding.DeviceID = device.ID
	if binding.BindAddr == "" {
		binding.BindAddr = "127.0.0.1"
	}
	if err := validateBinding(binding); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	service, exists := c.state.Services[binding.Service]
	provider, providerExists := c.state.Devices[service.Provider]
	if !exists || !providerExists || !provider.Enabled || !deviceCapabilities(provider).Publish {
		apiError(w, http.StatusForbidden, "service publisher unavailable")
		return
	}
	if _, ok := c.state.Grants[grantKey(binding.Service, device.ID)]; !ok {
		apiError(w, http.StatusForbidden, "service not granted to this device")
		return
	}
	next := c.candidate()
	next.Bindings[bindingKey(device.ID, binding.ID)] = binding
	c.finishV2(w, next)
}

func (c *controller) changeCapabilities(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string    `json:"device_id"`
		Publish  *bool     `json:"publish"`
		Bind     *bool     `json:"bind"`
		Visitors *[]string `json:"allowed_visitors"`
	}
	if err := decodeRequest(w, r, &req); err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	device, ok := c.state.Devices[req.DeviceID]
	if !ok || !device.Enabled {
		apiError(w, http.StatusNotFound, "enabled device not found")
		return
	}
	old := deviceCapabilities(device)
	caps := old
	if req.Publish != nil {
		caps.Publish = *req.Publish
	}
	if req.Bind != nil {
		caps.Bind = *req.Bind
	}
	device.Capabilities = &caps
	device.Role = capabilityRole(caps)
	next := c.candidate()
	next.Devices[device.ID] = device
	if req.Visitors != nil {
		if !caps.Publish && len(*req.Visitors) > 0 {
			apiError(w, http.StatusBadRequest, "visitor delegation requires publish capability")
			return
		}
		if err := validateVisitorGrants(next, device, *req.Visitors, false, c.now().Unix()); err != nil {
			apiError(w, http.StatusBadRequest, err.Error())
			return
		}
		device.AllowedVisitors = *req.Visitors
		next.Devices[device.ID] = device
	}
	c.reduceDeviceAccess(&next, device.ID, old, caps)
	c.finishV2(w, next)
}

func (c *controller) reduceDeviceAccess(state *serverState, id string, old, caps Capabilities) {
	device := state.Devices[id]
	affected := map[string]bool{}
	for key, service := range state.Services {
		if service.Provider == id && old.Publish && !caps.Publish {
			affected[key] = true
			for bindingID, binding := range state.Bindings {
				if binding.Service == key {
					delete(state.Bindings, bindingID)
				}
			}
		}
	}
	for key, grant := range state.Grants {
		service := state.Services[grant.Service]
		if (grant.Visitor == id && old.Bind && !caps.Bind) || (service.Provider == id && !containsID(device.AllowedVisitors, grant.Visitor)) {
			affected[grant.Service] = true
			removeVisitorGrant(state, grant.Service, grant.Visitor)
			delete(state.Grants, key)
		}
	}
	if old.Bind && !caps.Bind {
		for key, binding := range state.Bindings {
			if binding.DeviceID == id {
				delete(state.Bindings, key)
			}
		}
	}
	for key := range affected {
		if service, ok := state.Services[key]; ok {
			service.Secret = randomToken()
			state.Services[key] = service
		}
	}
}

func bridgeLegacyMapping(state *serverState, mapping Mapping, old Mapping, exists bool) error {
	if exists && old.Provider != mapping.Provider {
		removeService(state, serviceKey(old.Provider, old.ID))
	}
	key := serviceKey(mapping.Provider, mapping.ID)
	state.Services[key] = Service{ID: mapping.ID, Provider: mapping.Provider, LocalIP: mapping.LocalIP, LocalPort: mapping.LocalPort, Enabled: true, Secret: mapping.Secret}
	if err := replaceServiceGrants(state, key, mapping.Visitors); err != nil {
		return err
	}
	for _, visitor := range mapping.Visitors {
		bkey := bindingKey(visitor, mapping.ID)
		if current, ok := state.Bindings[bkey]; ok && current.Service != key {
			return errors.New("legacy binding identifier conflicts with another service")
		}
		state.Bindings[bkey] = Binding{ID: mapping.ID, DeviceID: visitor, Service: key, BindAddr: "127.0.0.1", BindPort: mapping.BindPort, Enabled: true}
	}
	state.Mappings[mapping.ID] = mapping
	return validateServerQuotas(*state)
}
