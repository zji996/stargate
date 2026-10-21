package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const SchemaVersion = 1
const EnrollmentVersion = 2
const ServiceFormat = 2

type Capabilities struct {
	Publish bool `json:"publish"`
	Bind    bool `json:"bind"`
}

func roleCapabilities(role string) Capabilities {
	return Capabilities{Publish: role == "provider" || role == "both", Bind: role == "visitor" || role == "both"}
}

type Transport struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// A service describes the provider's target; grants and visitor listeners are independent.
type Service struct {
	ID        string   `json:"id"`
	Provider  string   `json:"provider"`
	LocalIP   string   `json:"local_ip"`
	LocalPort int      `json:"local_port"`
	Enabled   bool     `json:"enabled"`
	Secret    string   `json:"secret,omitempty"`
	Visitors  []string `json:"visitors,omitempty"`
}

type Grant struct {
	Service string `json:"service"`
	Visitor string `json:"visitor"`
}

type Binding struct {
	ID       string `json:"id"`
	DeviceID string `json:"device_id"`
	Service  string `json:"service"`
	BindAddr string `json:"bind_addr"`
	BindPort int    `json:"bind_port"`
	Enabled  bool   `json:"enabled"`
}

func serviceKey(provider, id string) string { return provider + "/" + id }

func validateServiceKey(value string) error {
	parts := strings.Split(value, "/")
	if len(parts) != 2 || validateID(parts[0]) != nil || validateID(parts[1]) != nil {
		return errors.New("service must be PROVIDER/ID")
	}
	return nil
}

func validateService(s Service) error {
	if validateID(s.ID) != nil || validateID(s.Provider) != nil {
		return errors.New("invalid service identifier")
	}
	ip := net.ParseIP(s.LocalIP)
	if ip == nil || (!ip.IsPrivate() && !ip.IsLoopback()) || s.LocalPort < 1 || s.LocalPort > 65535 || len(s.Secret) < 32 {
		return errors.New("invalid service target or secret")
	}
	seen := map[string]bool{}
	for _, id := range s.Visitors {
		if validateID(id) != nil || seen[id] {
			return errors.New("invalid or duplicate service visitor")
		}
		seen[id] = true
	}
	return nil
}

func validateBinding(b Binding) error {
	if validateID(b.ID) != nil || validateID(b.DeviceID) != nil || validateServiceKey(b.Service) != nil {
		return errors.New("invalid binding identifier")
	}
	if b.BindAddr != "127.0.0.1" && b.BindAddr != "::1" {
		return errors.New("binding must listen on loopback")
	}
	if b.BindPort < 1024 || b.BindPort > 65535 || b.BindPort == 10830 || b.BindPort == 10831 || b.BindPort == 17400 {
		return errors.New("invalid or reserved binding port")
	}
	return nil
}

type Node struct {
	Server     string `json:"server"`
	Port       int    `json:"port"`
	Password   string `json:"password"`
	ServerName string `json:"server_name,omitempty"`
	Insecure   bool   `json:"insecure,omitempty"`
}

type Bootstrap struct {
	Schema          int        `json:"schema"`
	Node            Node       `json:"node"`
	ControllerURL   string     `json:"controller_url"`
	Certificate     string     `json:"certificate"`
	EnrollmentToken string     `json:"enrollment_token"`
	Transport       *Transport `json:"transport,omitempty"`
}

type Profile struct {
	Schema        int           `json:"schema"`
	DeviceID      string        `json:"device_id"`
	Role          string        `json:"role"`
	DeviceToken   string        `json:"device_token"`
	Node          Node          `json:"node"`
	ControllerURL string        `json:"controller_url"`
	Certificate   string        `json:"certificate"`
	FRPPort       int           `json:"frp_port"`
	FRPToken      string        `json:"frp_token"`
	Transport     *Transport    `json:"transport,omitempty"`
	Capabilities  *Capabilities `json:"capabilities,omitempty"`
}

type Mapping struct {
	ID        string   `json:"id"`
	Provider  string   `json:"provider"`
	LocalIP   string   `json:"local_ip"`
	LocalPort int      `json:"local_port"`
	BindPort  int      `json:"bind_port"`
	Visitors  []string `json:"visitors"`
	Secret    string   `json:"secret"`
}

type Desired struct {
	Schema            int           `json:"schema"`
	Revision          uint64        `json:"revision"`
	Mappings          []Mapping     `json:"mappings"`
	VisitorIDs        []string      `json:"visitor_ids,omitempty"`
	Format            int           `json:"format,omitempty"`
	DeviceID          string        `json:"device_id,omitempty"`
	Capabilities      *Capabilities `json:"capabilities,omitempty"`
	Services          []Service     `json:"services,omitempty"`
	AvailableServices []Service     `json:"available_services,omitempty"`
	Grants            []Grant       `json:"grants,omitempty"`
	Bindings          []Binding     `json:"bindings,omitempty"`
}

type Report struct {
	Revision uint64 `json:"revision"`
	State    string `json:"state"`
	Message  string `json:"message,omitempty"`
}

var idPattern = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,47}$`)

func validateID(id string) error {
	if !idPattern.MatchString(id) {
		return errors.New("invalid identifier")
	}
	return nil
}

func validateNode(n Node) error {
	if n.Server == "" || n.Password == "" || n.Port < 1 || n.Port > 65535 {
		return errors.New("invalid AnyTLS node")
	}
	if net.ParseIP(n.Server) == nil && !regexp.MustCompile(`^[a-zA-Z0-9.-]+$`).MatchString(n.Server) {
		return errors.New("invalid node host")
	}
	return nil
}

func validateMapping(m Mapping) error {
	if validateID(m.ID) != nil || validateID(m.Provider) != nil {
		return errors.New("invalid mapping identifier")
	}
	ip := net.ParseIP(m.LocalIP)
	if ip == nil || (!ip.IsPrivate() && !ip.IsLoopback()) {
		return errors.New("mapping target must be a private or loopback IP")
	}
	if m.LocalPort < 1 || m.LocalPort > 65535 || m.BindPort < 1024 || m.BindPort > 65535 {
		return errors.New("invalid mapping port")
	}
	if m.BindPort == 10830 || m.BindPort == 10831 || m.BindPort == 17400 {
		return errors.New("mapping port is reserved for the client transport")
	}
	if len(m.Visitors) == 0 || len(m.Visitors) > 32 {
		return errors.New("mapping needs 1..32 visitors")
	}
	seen := map[string]bool{}
	for _, id := range m.Visitors {
		if validateID(id) != nil || seen[id] {
			return errors.New("invalid or duplicate visitor")
		}
		seen[id] = true
	}
	if len(m.Secret) < 32 {
		return errors.New("mapping secret too short")
	}
	return nil
}

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if len(b) > 4<<20 {
		return errors.New("JSON file too large")
	}
	return json.Unmarshal(b, v)
}

func atomicJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return atomicFile(path, append(b, '\n'), 0600)
}

func atomicFile(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".next-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func requireLoopback(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("listener must bind loopback: %s", addr)
	}
	return nil
}
