package main

import (
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHealthcheckHTTPAndVerifiedTLS(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/readyz" {
			t.Error("healthcheck used wrong path")
		}
		w.WriteHeader(http.StatusOK)
	})
	plain := httptest.NewServer(handler)
	defer plain.Close()
	t.Setenv("HTTP_ADDR", strings.TrimPrefix(plain.URL, "http://"))
	t.Setenv("TLS_CERT_FILE", "")
	if err := healthcheck(); err != nil {
		t.Fatal("HTTP healthcheck failed")
	}
	secure := httptest.NewTLSServer(handler)
	defer secure.Close()
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: secure.Certificate().Raw})
	path := filepath.Join(t.TempDir(), "public-certificate.pem")
	if err := os.WriteFile(path, certificate, 0600); err != nil {
		t.Fatal("public test certificate write failed")
	}
	t.Setenv("HTTP_ADDR", strings.TrimPrefix(secure.URL, "https://"))
	t.Setenv("TLS_CERT_FILE", path)
	if err := healthcheck(); err != nil {
		t.Fatal("verified TLS healthcheck failed")
	}
	t.Setenv("TLS_CERT_FILE", filepath.Join(t.TempDir(), "missing.pem"))
	if err := healthcheck(); err == nil {
		t.Fatal("healthcheck ignored missing TLS certificate")
	}
}
