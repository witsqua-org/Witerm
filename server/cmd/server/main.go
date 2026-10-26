package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"witerm/server/internal/config"
	"witerm/server/internal/httpapi"
	"witerm/server/internal/pairing"
	"witerm/server/internal/relay"
	"witerm/server/internal/store"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	check := flag.Bool("healthcheck", false, "check the local readiness endpoint")
	migrate := flag.Bool("migrate-only", false, "apply database migrations and exit")
	flag.Parse()
	if *check {
		if err := healthcheck(); err != nil {
			os.Exit(1)
		}
		return
	}
	if err := run(*migrate); err != nil {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func run(migrateOnly bool) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	startup, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, err := store.Open(startup, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()
	if cfg.MigrateOnStart || migrateOnly {
		if err := store.Migrate(startup, db); err != nil {
			return err
		}
	}
	if err := store.ValidateSchema(startup, db); err != nil {
		return err
	}
	if migrateOnly {
		return nil
	}
	identities := pairing.New(db)
	router := relay.New(identities, relay.Options{AllowLoopbackDevelopment: cfg.RelayAllowLoopbackDevelopment})
	defer router.Close()
	server := &http.Server{
		Addr: cfg.HTTPAddr, Handler: httpapi.New(db, identities, router),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second, WriteTimeout: 10 * time.Second,
		IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}
	done := make(chan error, 1)
	go func() {
		if cfg.TLSCertFile != "" {
			done <- server.ListenAndServeTLS(cfg.TLSCertFile, cfg.TLSKeyFile)
		} else {
			done <- server.ListenAndServe()
		}
	}()
	slog.Info("server starting", "address", cfg.HTTPAddr)
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		router.Close()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
			return err
		}
		if err := <-done; !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}

func healthcheck() error {
	addr := os.Getenv("HTTP_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	client := &http.Client{Timeout: 3 * time.Second}
	scheme := "http"
	if certFile := os.Getenv("TLS_CERT_FILE"); certFile != "" {
		certificate, err := os.ReadFile(certFile)
		if err != nil {
			return errors.New("healthcheck TLS certificate unavailable")
		}
		roots := x509.NewCertPool()
		if !roots.AppendCertsFromPEM(certificate) {
			return errors.New("healthcheck TLS certificate invalid")
		}
		block, _ := pem.Decode(certificate)
		if block == nil {
			return errors.New("healthcheck TLS certificate invalid")
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return errors.New("healthcheck TLS certificate invalid")
		}
		serverName := host
		if len(cert.DNSNames) > 0 {
			serverName = cert.DNSNames[0]
		}
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: serverName, MinVersion: tls.VersionTLS12}}
		scheme = "https"
	}
	response, err := client.Get(scheme + "://" + net.JoinHostPort(host, port) + "/readyz")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errors.New(strings.TrimSpace(response.Status))
	}
	return nil
}
