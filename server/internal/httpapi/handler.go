package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

type Database interface {
	Ping(context.Context) error
}

type Info struct {
	Service         string   `json:"service"`
	ProtocolVersion int      `json:"protocol_version"`
	Capabilities    []string `json:"capabilities"`
}

type RouteRegistrar interface {
	RegisterRoutes(*http.ServeMux)
	Capabilities() []string
}

func New(db Database, registrars ...RouteRegistrar) http.Handler {
	mux := http.NewServeMux()
	capabilities := []string{}
	for _, registrar := range registrars {
		registrar.RegisterRoutes(mux)
		capabilities = append(capabilities, registrar.Capabilities()...)
	}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := db.Ping(ctx); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /v1/info", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, Info{Service: "witerm", ProtocolVersion: 1, Capabilities: capabilities})
	})
	return mux
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
