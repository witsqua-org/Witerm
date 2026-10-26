// Package relay routes opaque binary messages. It never interprets their payload.
package relay

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"witerm/server/internal/pairing"
)

const (
	maxTunnels       = 256
	maxDeviceTunnels = 4
	maxHosts         = 256
	maxSockets       = maxTunnels*2 + maxHosts
	maxMessage       = 65536
	maxQueuedBytes   = 256 << 10
	pendingLifetime  = 30 * time.Second
	ioTimeout        = 5 * time.Second
)

var (
	errOffline = errors.New("host_offline")
	errTunnel  = errors.New("tunnel_unavailable")
	errLimited = errors.New("rate_limited")
	errStopped = errors.New("unavailable")
)

type host struct {
	identity pairing.RelayIdentity
	ctx      context.Context
	cancel   context.CancelFunc
	offers   chan offer
}
type offer struct {
	Type     string `json:"type"`
	TunnelID string `json:"tunnel_id"`
	GrantID  string `json:"grant_id"`
}
type leg struct {
	identity pairing.RelayIdentity
	reserved bool
	conn     *websocket.Conn
	queue    *boundedQueue
}
type tunnel struct {
	id      string
	grant   pairing.Grant
	host    *host
	ctx     context.Context
	cancel  context.CancelFunc
	expires time.Time
	timer   *time.Timer
	legs    [2]leg // host, client; roles are never supplied by a caller
}

type Service struct {
	pairing                  Authorizer
	mu                       sync.Mutex
	hosts                    map[string]*host
	tunnels                  map[string]*tunnel
	sockets                  int
	closed                   bool
	ctx                      context.Context
	cancel                   context.CancelFunc
	done                     chan struct{}
	allowLoopbackDevelopment bool
}

type Options struct{ AllowLoopbackDevelopment bool }

// Authorizer is the existing pairing service's narrow in-memory/durable view.
// No identity records, key material or bearer tokens are duplicated by relay.
type Authorizer interface {
	AuthenticateRelay(context.Context, *http.Request) (pairing.RelayIdentity, error)
	WithActiveRelayGrant(context.Context, string, func(pairing.Grant) error) error
	SetRelayRevocationHook(func(string))
	CheckRelayState(context.Context, []pairing.RelayIdentity, []string) (map[string]bool, map[string]bool, error)
	RelaySessionActive(pairing.RelayIdentity) bool
}

func New(auth Authorizer, options ...Options) *Service {
	ctx, cancel := context.WithCancel(context.Background())
	s := &Service{pairing: auth, hosts: map[string]*host{}, tunnels: map[string]*tunnel{}, ctx: ctx, cancel: cancel, done: make(chan struct{})}
	if len(options) > 0 {
		s.allowLoopbackDevelopment = options[0].AllowLoopbackDevelopment
	}
	auth.SetRelayRevocationHook(s.revoke)
	go s.monitor()
	return s
}

func (*Service) Capabilities() []string { return []string{"encrypted_relay_v1"} }
func (s *Service) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/relay/host", s.hostHandler)
	mux.HandleFunc("POST /v1/relay/tunnels", s.createHandler)
	mux.HandleFunc("GET /v1/relay/tunnels/{id}", s.tunnelHandler)
}
func (s *Service) Close() {
	s.mu.Lock()
	if !s.closed {
		s.closed = true
		for _, h := range s.hosts {
			s.dropHostLocked(h)
		}
		for _, t := range s.tunnels {
			s.dropTunnelLocked(t)
		}
		s.cancel()
	}
	s.mu.Unlock()
	<-s.done
}
func fail(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code, "message": "Request could not be completed."}})
}
func failError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, pairing.ErrRelayUnauthorized):
		fail(w, 401, "unauthorized")
	case errors.Is(err, pairing.ErrRelayRateLimited), errors.Is(err, errLimited):
		fail(w, 429, "rate_limited")
	case errors.Is(err, pairing.ErrRelayUnavailable), errors.Is(err, errTunnel):
		fail(w, 404, "tunnel_unavailable")
	case errors.Is(err, errOffline):
		fail(w, 409, "host_offline")
	default:
		fail(w, 503, "unavailable")
	}
}

// HTTP requires explicit development opt-in and an exact loopback Host. Docker
// port forwarding can present a gateway RemoteAddr. Enabling this option requires
// a loopback-bound published port, as in Compose. Forwarded headers are not trusted.
func transportAllowed(r *http.Request, allowLoopback bool) bool {
	if r.TLS != nil {
		return true
	}
	host := r.Host
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return allowLoopback && (host == "localhost" || host == "127.0.0.1" || host == "::1")
}
func (s *Service) authenticate(w http.ResponseWriter, r *http.Request, upgrade bool) (pairing.RelayIdentity, bool) {
	if !transportAllowed(r, s.allowLoopbackDevelopment) || len(r.Header.Values("Origin")) != 0 {
		fail(w, 403, "forbidden")
		return pairing.RelayIdentity{}, false
	}
	if r.URL.RawQuery != "" || r.ContentLength != 0 && r.Method == "GET" || len(r.TransferEncoding) != 0 {
		fail(w, 400, "invalid_request")
		return pairing.RelayIdentity{}, false
	}
	ctx, cancel := context.WithTimeout(r.Context(), ioTimeout)
	defer cancel()
	identity, err := s.pairing.AuthenticateRelay(ctx, r)
	if err != nil {
		failError(w, err)
		return pairing.RelayIdentity{}, false
	}
	if upgrade && !validUpgrade(r) {
		fail(w, 400, "invalid_request")
		return pairing.RelayIdentity{}, false
	}
	return identity, true
}
func (s *Service) acquire() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.sockets >= maxSockets {
		return false
	}
	s.sockets++
	return true
}
func (s *Service) release() { s.mu.Lock(); s.sockets--; s.mu.Unlock() }

func (s *Service) hostHandler(w http.ResponseWriter, r *http.Request) {
	identity, ok := s.authenticate(w, r, true)
	if !ok {
		return
	}
	if identity.Device.Platform != "macos" {
		fail(w, 403, "forbidden")
		return
	}
	if !s.acquire() {
		failError(w, errLimited)
		return
	}
	defer s.release()
	s.mu.Lock()
	full := len(s.hosts) >= maxHosts && s.hosts[identity.Device.ID] == nil
	s.mu.Unlock()
	if full {
		failError(w, errLimited)
		return
	}
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(4096)
	ctx, cancel := context.WithDeadline(s.ctx, identity.ExpiresAt)
	defer cancel()
	h := &host{identity: identity, ctx: ctx, cancel: cancel, offers: make(chan offer, 16)}
	s.mu.Lock()
	if s.closed || len(s.hosts) >= maxHosts && s.hosts[identity.Device.ID] == nil {
		s.mu.Unlock()
		return
	}
	if old := s.hosts[identity.Device.ID]; old != nil {
		s.dropHostLocked(old)
	}
	s.hosts[identity.Device.ID] = h
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.dropHostLocked(h); s.mu.Unlock() }()
	// This write precedes the offer consumer even when an offer was queued while
	// the upgrade completed, so ready is always the first application message.
	if err := write(ctx, c, websocket.MessageText, []byte(`{"type":"ready"}`)); err != nil {
		return
	}
	go heartbeat(ctx, c, cancel)
	go func() {
		defer cancel()
		for {
			typ, _, err := read(ctx, c)
			if err != nil || typ != websocket.MessageText {
				return
			}
			return /* no inbound control operations in v1 */
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case o := <-h.offers:
			data, _ := json.Marshal(o)
			if err := write(ctx, c, websocket.MessageText, data); err != nil {
				return
			}
		}
	}
}

func (s *Service) createHandler(w http.ResponseWriter, r *http.Request) {
	identity, ok := s.authenticate(w, r, false)
	if !ok {
		return
	}
	if identity.Device.Platform != "ios" {
		fail(w, 403, "forbidden")
		return
	}
	var request struct {
		GrantID string `json:"grant_id"`
	}
	if !decodeRequest(w, r, &request) {
		return
	}
	if !validID(request.GrantID) {
		fail(w, 400, "invalid_request")
		return
	}
	id, err := randomID()
	if err != nil {
		failError(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), ioTimeout)
	defer cancel()
	err = s.pairing.WithActiveRelayGrant(ctx, request.GrantID, func(g pairing.Grant) error {
		if identity.Device.ID != g.Client.ID {
			return errTunnel
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.closed {
			return errStopped
		}
		h := s.hosts[g.Host.ID]
		if h == nil || h.ctx.Err() != nil {
			return errOffline
		}
		if len(s.tunnels) >= maxTunnels {
			return errLimited
		}
		hostCount, clientCount := 0, 0
		for _, t := range s.tunnels {
			if t.grant.Host.ID == g.Host.ID {
				hostCount++
			}
			if t.grant.Client.ID == g.Client.ID {
				clientCount++
			}
		}
		if hostCount >= maxDeviceTunnels || clientCount >= maxDeviceTunnels {
			return errLimited
		}
		tctx, tcancel := context.WithCancel(s.ctx)
		t := &tunnel{id: id, grant: g, host: h, ctx: tctx, cancel: tcancel, expires: time.Now().Add(pendingLifetime)}
		for i := range t.legs {
			t.legs[i].queue = newBoundedQueue()
		}
		s.tunnels[id] = t
		t.timer = time.AfterFunc(pendingLifetime, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if !complete(t) {
				s.dropTunnelLocked(t)
			}
		})
		select {
		case h.offers <- offer{Type: "offer", TunnelID: id, GrantID: g.ID}:
			return nil
		default:
			s.dropTunnelLocked(t)
			s.dropHostLocked(h)
			return errOffline
		}
	})
	if err != nil {
		failError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(201)
	_ = json.NewEncoder(w).Encode(map[string]string{"tunnel_id": id})
}

func complete(t *tunnel) bool { return t.legs[0].conn != nil && t.legs[1].conn != nil }
func (s *Service) tunnelHandler(w http.ResponseWriter, r *http.Request) {
	identity, ok := s.authenticate(w, r, true)
	if !ok {
		return
	}
	id := r.PathValue("id")
	if !validID(id) {
		failError(w, errTunnel)
		return
	}
	if !s.acquire() {
		failError(w, errLimited)
		return
	}
	defer s.release()
	s.mu.Lock()
	t := s.tunnels[id]
	s.mu.Unlock()
	if t == nil {
		failError(w, errTunnel)
		return
	}
	role := -1
	ctx, cancel := context.WithTimeout(r.Context(), ioTimeout)
	err := s.pairing.WithActiveRelayGrant(ctx, t.grant.ID, func(g pairing.Grant) error {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.tunnels[id] != t || t.ctx.Err() != nil || !complete(t) && !time.Now().Before(t.expires) {
			return errTunnel
		}
		if identity.Device.ID == g.Host.ID && identity.Device.Platform == "macos" {
			role = 0
		} else if identity.Device.ID == g.Client.ID && identity.Device.Platform == "ios" {
			role = 1
		} else {
			return errTunnel
		}
		if t.legs[role].reserved {
			return errTunnel
		}
		t.legs[role].reserved = true
		t.legs[role].identity = identity
		return nil
	})
	cancel()
	if err != nil {
		failError(w, err)
		return
	}
	// Once admitted, any failed upgrade consumes this route; an endpoint can
	// never reconnect/reuse an old cryptographic transport.
	defer func() { s.mu.Lock(); s.dropTunnelLocked(t); s.mu.Unlock() }()
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(maxMessage)
	ctx, cancel = context.WithTimeout(context.Background(), ioTimeout)
	err = s.pairing.WithActiveRelayGrant(ctx, t.grant.ID, func(g pairing.Grant) error {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.tunnels[id] != t || t.ctx.Err() != nil || !time.Now().Before(identity.ExpiresAt) || !complete(t) && !time.Now().Before(t.expires) {
			return errTunnel
		}
		t.legs[role].conn = c
		if complete(t) {
			t.timer.Stop()
		}
		return nil
	})
	cancel()
	if err != nil {
		return
	}
	ctx, cancel = context.WithDeadline(t.ctx, identity.ExpiresAt)
	defer cancel()
	go heartbeat(ctx, c, cancel)
	go func() {
		defer cancel()
		for {
			select {
			case <-ctx.Done():
				return
			case data := <-t.legs[role].queue.messages:
				err := write(ctx, c, websocket.MessageBinary, data)
				t.legs[role].queue.delivered(len(data))
				if err != nil {
					return
				}
			}
		}
	}()
	for {
		typ, data, err := read(ctx, c)
		if err != nil || typ != websocket.MessageBinary {
			return
		}
		if !t.legs[1-role].queue.put(data) {
			return
		}
	}
}

func (s *Service) dropTunnelLocked(t *tunnel) {
	if s.tunnels[t.id] != t {
		return
	}
	delete(s.tunnels, t.id)
	t.cancel()
	if t.timer != nil {
		t.timer.Stop()
	}
}
func (s *Service) dropHostLocked(h *host) {
	if s.hosts[h.identity.Device.ID] != h {
		return
	}
	delete(s.hosts, h.identity.Device.ID)
	h.cancel()
	for _, t := range s.tunnels {
		if t.host == h {
			s.dropTunnelLocked(t)
		}
	}
}
func (s *Service) revoke(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, t := range s.tunnels {
		if t.grant.ID == id {
			s.dropTunnelLocked(t)
		}
	}
}

func (s *Service) monitor() {
	defer close(s.done)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.mu.Lock()
			hosts := make([]*host, 0, len(s.hosts))
			routes := make([]*tunnel, 0, len(s.tunnels))
			identities := make([]pairing.RelayIdentity, 0, len(s.hosts)+len(s.tunnels)*2)
			ids := make([]string, 0, len(s.tunnels))
			for _, h := range s.hosts {
				hosts = append(hosts, h)
				identities = append(identities, h.identity)
			}
			for _, t := range s.tunnels {
				routes = append(routes, t)
				ids = append(ids, t.grant.ID)
				for _, l := range t.legs {
					if l.reserved {
						identities = append(identities, l.identity)
					}
				}
			}
			s.mu.Unlock()
			if len(hosts) == 0 && len(routes) == 0 {
				continue
			}
			ctx, cancel := context.WithTimeout(s.ctx, 750*time.Millisecond)
			devices, grants, err := s.pairing.CheckRelayState(ctx, identities, ids)
			cancel()
			s.mu.Lock()
			for _, h := range hosts {
				if err != nil || !devices[h.identity.Device.ID] || !s.pairing.RelaySessionActive(h.identity) {
					s.dropHostLocked(h)
				}
			}
			for _, t := range routes {
				invalid := err != nil || !grants[t.grant.ID]
				for _, l := range t.legs {
					if l.reserved && (!devices[l.identity.Device.ID] || !s.pairing.RelaySessionActive(l.identity)) {
						invalid = true
					}
				}
				if invalid {
					s.dropTunnelLocked(t)
				}
			}
			s.mu.Unlock()
		}
	}
}

func write(ctx context.Context, c *websocket.Conn, typ websocket.MessageType, data []byte) error {
	timeout, cancel := context.WithTimeout(ctx, ioTimeout)
	defer cancel()
	return c.Write(timeout, typ, data)
}
func read(ctx context.Context, c *websocket.Conn) (websocket.MessageType, []byte, error) {
	// The heartbeat bounds unresponsive idle/header reads. Once an application
	// message starts, a separate deadline bounds fragmented/slow messages.
	typ, reader, err := c.Reader(ctx)
	if err != nil {
		return typ, nil, err
	}
	timer := time.AfterFunc(ioTimeout, func() { _ = c.CloseNow() })
	defer timer.Stop()
	data, err := io.ReadAll(reader)
	return typ, data, err
}
func heartbeat(ctx context.Context, c *websocket.Conn, cancel context.CancelFunc) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			ping, done := context.WithTimeout(ctx, ioTimeout)
			err := c.Ping(ping)
			done()
			if err != nil {
				cancel()
				return
			}
		}
	}
}
func randomID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}
func validID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for i, c := range id {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
			return false
		}
	}
	return true
}

// Queue accounting includes a blocked in-flight write. Message count is also
// bounded, so a stream of empty messages cannot exhaust routing memory.
type boundedQueue struct {
	mu       sync.Mutex
	bytes    int
	messages chan []byte
}

func newBoundedQueue() *boundedQueue { return &boundedQueue{messages: make(chan []byte, 16)} }
func (q *boundedQueue) put(data []byte) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(data) > maxMessage || q.bytes+len(data) > maxQueuedBytes {
		return false
	}
	select {
	case q.messages <- data:
		q.bytes += len(data)
		return true
	default:
		return false
	}
}
func (q *boundedQueue) delivered(size int) { q.mu.Lock(); q.bytes -= size; q.mu.Unlock() }
