package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	HTTPAddr                      string
	DatabaseURL                   string
	MigrateOnStart                bool
	RelayAllowLoopbackDevelopment bool
	TLSCertFile                   string
	TLSKeyFile                    string
}

func Load() (Config, error) {
	return load(os.Getenv)
}

func load(getenv func(string) string) (Config, error) {
	cfg := Config{HTTPAddr: strings.TrimSpace(getenv("HTTP_ADDR")), DatabaseURL: strings.TrimSpace(getenv("DATABASE_URL"))}
	if cfg.HTTPAddr == "" {
		cfg.HTTPAddr = "127.0.0.1:8080"
	}
	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if raw := getenv("MIGRATE_ON_START"); raw != "" {
		value, err := strconv.ParseBool(raw)
		if err != nil {
			return Config{}, fmt.Errorf("MIGRATE_ON_START must be a boolean")
		}
		cfg.MigrateOnStart = value
	}
	if raw := getenv("RELAY_ALLOW_LOOPBACK_DEVELOPMENT"); raw != "" {
		value, err := strconv.ParseBool(raw)
		if err != nil {
			return Config{}, fmt.Errorf("RELAY_ALLOW_LOOPBACK_DEVELOPMENT must be a boolean")
		}
		cfg.RelayAllowLoopbackDevelopment = value
	}
	cfg.TLSCertFile = strings.TrimSpace(getenv("TLS_CERT_FILE"))
	cfg.TLSKeyFile = strings.TrimSpace(getenv("TLS_KEY_FILE"))
	if (cfg.TLSCertFile == "") != (cfg.TLSKeyFile == "") {
		return Config{}, fmt.Errorf("TLS_CERT_FILE and TLS_KEY_FILE must be configured together")
	}
	return cfg, nil
}
