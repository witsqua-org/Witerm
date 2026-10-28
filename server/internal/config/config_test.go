package config

import "testing"

func TestRequiredDatabaseAndMigrationOptIn(t *testing.T) {
	values := map[string]string{}
	getenv := func(key string) string { return values[key] }
	if _, err := load(getenv); err == nil {
		t.Fatal("missing database configuration must fail")
	}
	values["DATABASE_URL"] = "postgres://localhost/witerm"
	cfg, err := load(getenv)
	if err != nil || cfg.MigrateOnStart || cfg.HTTPAddr != "127.0.0.1:37429" {
		t.Fatalf("unexpected defaults: %+v, %v", cfg, err)
	}
	values["MIGRATE_ON_START"] = "invalid"
	if _, err := load(getenv); err == nil {
		t.Fatal("invalid migration setting must fail")
	}
}

func TestRelayDevelopmentOptInAndTLSPair(t *testing.T) {
	values := map[string]string{"DATABASE_URL": "postgres://localhost/witerm"}
	getenv := func(key string) string { return values[key] }
	cfg, err := load(getenv)
	if err != nil || cfg.RelayAllowLoopbackDevelopment || cfg.TLSCertFile != "" || cfg.TLSKeyFile != "" {
		t.Fatal("insecure relay or TLS enabled by default")
	}
	values["RELAY_ALLOW_LOOPBACK_DEVELOPMENT"] = "invalid"
	if _, err := load(getenv); err == nil {
		t.Fatal("invalid development flag accepted")
	}
	values["RELAY_ALLOW_LOOPBACK_DEVELOPMENT"] = "true"
	values["TLS_CERT_FILE"] = "/run/certs/server.pem"
	if _, err := load(getenv); err == nil {
		t.Fatal("unpaired TLS certificate accepted")
	}
	delete(values, "TLS_CERT_FILE")
	values["TLS_KEY_FILE"] = "/run/certs/server.key"
	if _, err := load(getenv); err == nil {
		t.Fatal("unpaired TLS key accepted")
	}
	values["TLS_CERT_FILE"] = "/run/certs/server.pem"
	cfg, err = load(getenv)
	if err != nil || !cfg.RelayAllowLoopbackDevelopment || cfg.TLSCertFile == "" || cfg.TLSKeyFile == "" {
		t.Fatal("valid explicit TLS configuration rejected")
	}
}
