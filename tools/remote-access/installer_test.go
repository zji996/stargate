package main

import (
	"bytes"
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestServerPreflightAndConfiguredHealthAddress(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusServiceUnavailable, http.StatusFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			c := testController(t)
			pair, err := tls.LoadX509KeyPair(filepath.Join(c.dir, "server.crt"), filepath.Join(c.dir, "server.key"))
			if err != nil {
				t.Fatal(err)
			}
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/health" {
					t.Errorf("unexpected health path: %s", r.URL.Path)
				}
				w.Header().Set("Location", "/other")
				w.WriteHeader(status)
			}))
			server.TLS = &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}
			server.StartTLS()
			defer server.Close()
			c.state.Listen = strings.TrimPrefix(server.URL, "https://")
			if err := atomicJSON(filepath.Join(c.dir, "server.json"), c.state); err != nil {
				t.Fatal(err)
			}
			if err := CheckServer([]string{"--dir", c.dir}); err != nil {
				t.Fatal(err)
			}
			err = CheckServer([]string{"--dir", c.dir, "--health"})
			if (err == nil) != (status == http.StatusOK) {
				t.Fatalf("health status %d returned %v", status, err)
			}
			if err := os.WriteFile(filepath.Join(c.dir, "server.key"), []byte("broken key"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := CheckServer([]string{"--dir", c.dir}); err == nil {
				t.Fatal("preflight accepted a broken TLS key")
			}
		})
	}
}

func TestServerPreflightRejectsChangedPinnedIdentity(t *testing.T) {
	c := testController(t)
	other := testController(t)
	c.state.Certificate = other.state.Certificate
	if err := atomicJSON(filepath.Join(c.dir, "server.json"), c.state); err != nil {
		t.Fatal(err)
	}
	if err := CheckServer([]string{"--dir", c.dir}); err == nil {
		t.Fatal("preflight accepted a certificate different from the pinned identity")
	}
}

func TestServerPreparationPreservesIdentityAndMappings(t *testing.T) {
	c := testController(t)
	testDevices(t, c)
	before, err := os.ReadFile(filepath.Join(c.dir, "server.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(c.dir, "frps.json"), map[string]any{"obsolete": true}); err != nil {
		t.Fatal(err)
	}
	if err := PrepareServer([]string{"--dir", c.dir}); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(filepath.Join(c.dir, "server.json"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("server preparation changed the stored identity or device grants")
	}
	var got map[string]any
	if err := readJSON(filepath.Join(c.dir, "frps.json"), &got); err != nil {
		t.Fatal(err)
	}
	if got["obsolete"] != nil || got["bindAddr"] != "127.0.0.1" {
		t.Fatal("server configuration was not regenerated")
	}
}
