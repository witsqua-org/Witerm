package pairing

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool         *pgxpool.Pool
	memory       *memory
	now          func() time.Time
	relayMu      sync.Mutex
	relayRevoked func(string)
}

func New(pool *pgxpool.Pool) *Service {
	return &Service{pool: pool, memory: newMemory(), now: time.Now}
}

func (*Service) Capabilities() []string { return []string{"device_identity_v1", "device_pairing_v1"} }

func (s *Service) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/auth/challenges", s.issueChallenge)
	mux.HandleFunc("POST /v1/devices", s.register)
	mux.HandleFunc("POST /v1/pairings", s.auth(true, s.createHandler))
	mux.HandleFunc("POST /v1/pairings/{id}/join", s.auth(true, s.joinHandler))
	mux.HandleFunc("POST /v1/pairings/{id}/approve", s.auth(true, s.approveHandler))
	mux.HandleFunc("POST /v1/pairings/{id}/reject", s.auth(true, s.rejectHandler))
	mux.HandleFunc("GET /v1/pairings/{id}", s.auth(false, s.getHandler))
	mux.HandleFunc("GET /v1/grants", s.auth(false, s.grantsHandler))
	mux.HandleFunc("DELETE /v1/grants/{id}", s.auth(true, s.revokeHandler))
}

func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	if value != nil {
		_ = json.NewEncoder(w).Encode(value)
	}
}

func fail(w http.ResponseWriter, status int, code string) {
	respond(w, status, map[string]any{"error": map[string]string{"code": code, "message": "Request could not be completed."}})
}

func failError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errUnauthorized):
		fail(w, 401, "unauthorized")
	case errors.Is(err, errForbidden):
		fail(w, 403, "forbidden")
	case errors.Is(err, errUnavailable), errors.Is(err, pgx.ErrNoRows):
		fail(w, 404, "pairing_unavailable")
	case errors.Is(err, errConflict):
		fail(w, 409, "conflict")
	default:
		fail(w, 503, "unavailable")
	}
}

func decode(w http.ResponseWriter, r *http.Request, target any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	body, err := io.ReadAll(r.Body)
	body = bytes.TrimSpace(body)
	if err != nil || len(body) < 2 || body[0] != '{' {
		fail(w, 400, "invalid_request")
		return false
	}
	d := json.NewDecoder(bytes.NewReader(body))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		fail(w, 400, "invalid_request")
		return false
	}
	if err := d.Decode(new(any)); err != io.EOF {
		fail(w, 400, "invalid_request")
		return false
	}
	return true
}

func (s *Service) issueChallenge(w http.ResponseWriter, r *http.Request) {
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		ip = r.RemoteAddr
	}
	if !s.memory.allow("ip:"+ip, s.now()) {
		fail(w, 429, "rate_limited")
		return
	}
	var request struct {
		PublicKey string `json:"public_key"`
	}
	if !decode(w, r, &request) {
		return
	}
	key, err := decodePublicKey(request.PublicKey)
	if err != nil {
		fail(w, 400, "invalid_request")
		return
	}
	id, err := randomID()
	if err != nil {
		failError(w, err)
		return
	}
	nonce, err := randomSecret()
	if err != nil {
		failError(w, err)
		return
	}
	expires := wholeSecond(s.now()).Add(time.Minute)
	if !s.memory.putChallenge(challenge{ID: id, Nonce: nonce, Key: key, ExpiresAt: expires}, s.now()) {
		fail(w, 429, "rate_limited")
		return
	}
	respond(w, 201, map[string]any{"challenge_id": id, "nonce": nonce, "expires_at": expires})
}

func (s *Service) register(w http.ResponseWriter, r *http.Request) {
	var request struct {
		ChallengeID string `json:"challenge_id"`
		Name        string `json:"name"`
		Platform    string `json:"platform"`
		Signature   string `json:"signature"`
	}
	if !decode(w, r, &request) {
		return
	}
	c, ok := s.memory.consumeChallenge(request.ChallengeID, s.now())
	if !ok {
		fail(w, 401, "unauthorized")
		return
	}
	if strings.TrimSpace(request.Name) != request.Name || utf8.RuneCountInString(request.Name) < 1 || utf8.RuneCountInString(request.Name) > 64 || strings.ContainsFunc(request.Name, unicode.IsControl) || (request.Platform != "macos" && request.Platform != "ios") {
		fail(w, 400, "invalid_request")
		return
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(request.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || base64.StdEncoding.EncodeToString(signature) != request.Signature || !ed25519.Verify(c.Key, registrationMessage(c.ID, c.Nonce, request.Name, request.Platform), signature) {
		fail(w, 401, "unauthorized")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	device, err := registerDevice(ctx, s.pool, c.Key, request.Name, request.Platform)
	if err != nil {
		failError(w, err)
		return
	}
	token, err := randomSecret()
	if err != nil {
		failError(w, err)
		return
	}
	expires := wholeSecond(s.now()).Add(time.Hour)
	if !s.memory.putSession(token, device.ID, expires, s.now()) {
		fail(w, 429, "rate_limited")
		return
	}
	respond(w, 200, map[string]any{"device": device, "access_token": token, "expires_at": expires})
}

type authenticated func(context.Context, http.ResponseWriter, *http.Request, Device)

func (s *Service) auth(mutation bool, next authenticated) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if (r.Method == http.MethodGet || r.Method == http.MethodDelete) && (r.ContentLength != 0 || len(r.TransferEncoding) != 0) {
			fail(w, 400, "invalid_request")
			return
		}
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") || len(header) > 128 {
			fail(w, 401, "unauthorized")
			return
		}
		session, ok := s.memory.getSession(strings.TrimPrefix(header, "Bearer "), s.now())
		if !ok {
			fail(w, 401, "unauthorized")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		device, err := deviceByID(ctx, s.pool, session.DeviceID)
		if errors.Is(err, pgx.ErrNoRows) {
			fail(w, 401, "unauthorized")
			return
		}
		if err != nil {
			failError(w, err)
			return
		}
		if mutation && !s.memory.allow("device:"+device.ID, s.now()) {
			fail(w, 429, "rate_limited")
			return
		}
		next(ctx, w, r, device)
	}
}

func routeID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if !validID(id) {
		fail(w, 404, "pairing_unavailable")
		return "", false
	}
	return id, true
}

func (s *Service) createHandler(ctx context.Context, w http.ResponseWriter, r *http.Request, d Device) {
	if !decode(w, r, &struct{}{}) {
		return
	}
	p, secret, err := s.create(ctx, d)
	if err != nil {
		failError(w, err)
		return
	}
	respond(w, 201, map[string]any{"pairing": p, "secret": secret})
}

func (s *Service) joinHandler(ctx context.Context, w http.ResponseWriter, r *http.Request, d Device) {
	id, ok := routeID(w, r)
	if !ok {
		return
	}
	var request struct {
		Secret string `json:"secret"`
	}
	if !decode(w, r, &request) {
		return
	}
	p, err := s.join(ctx, id, d, request.Secret)
	if err != nil {
		failError(w, err)
		return
	}
	respond(w, 200, p)
}

func (s *Service) approveHandler(ctx context.Context, w http.ResponseWriter, r *http.Request, d Device) {
	id, ok := routeID(w, r)
	if !ok {
		return
	}
	var request struct {
		Permission string `json:"permission"`
		Signature  string `json:"approval_signature"`
	}
	if !decode(w, r, &request) {
		return
	}
	if request.Permission != "view" && request.Permission != "control" {
		fail(w, 400, "invalid_request")
		return
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(request.Signature)
	if err != nil || len(signature) != 64 || base64.StdEncoding.EncodeToString(signature) != request.Signature {
		fail(w, 400, "invalid_request")
		return
	}
	p, err := s.approve(ctx, id, d, request.Permission, signature)
	if err != nil {
		failError(w, err)
		return
	}
	respond(w, 200, p)
}

func (s *Service) rejectHandler(ctx context.Context, w http.ResponseWriter, r *http.Request, d Device) {
	id, ok := routeID(w, r)
	if !ok {
		return
	}
	if !decode(w, r, &struct{}{}) {
		return
	}
	p, err := s.reject(ctx, id, d)
	if err != nil {
		failError(w, err)
		return
	}
	respond(w, 200, p)
}

func (s *Service) getHandler(ctx context.Context, w http.ResponseWriter, r *http.Request, d Device) {
	id, ok := routeID(w, r)
	if !ok {
		return
	}
	p, err := loadPairing(ctx, s.pool, id, false, s.now())
	if err != nil {
		failError(w, err)
		return
	}
	if p.Host.ID != d.ID && (p.Client == nil || p.Client.ID != d.ID) {
		fail(w, 404, "pairing_unavailable")
		return
	}
	respond(w, 200, p)
}

func (s *Service) grantsHandler(ctx context.Context, w http.ResponseWriter, r *http.Request, d Device) {
	grants, err := s.grants(ctx, d)
	if err != nil {
		failError(w, err)
		return
	}
	respond(w, 200, map[string]any{"grants": grants})
}

func (s *Service) revokeHandler(ctx context.Context, w http.ResponseWriter, r *http.Request, d Device) {
	id, ok := routeID(w, r)
	if !ok {
		return
	}
	if err := s.revoke(ctx, id, d); err != nil {
		failError(w, err)
		return
	}
	respond(w, 204, nil)
}
