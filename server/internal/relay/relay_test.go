package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"witerm/server/internal/pairing"
	"witerm/server/internal/store"
)

func TestQueueBoundsIncludeInflightAndEmptyMessages(t *testing.T) {
	q := newBoundedQueue()
	for range 4 {
		if !q.put(make([]byte, maxMessage)) {
			t.Fatal("rejected bounded message")
		}
	}
	data := <-q.messages
	if q.put([]byte{1}) {
		t.Fatal("in-flight write escaped budget")
	}
	q.delivered(len(data))
	if !q.put(make([]byte, maxMessage)) {
		t.Fatal("completed write did not release budget")
	}
	q = newBoundedQueue()
	for range 16 {
		if !q.put(nil) {
			t.Fatal("empty message rejected before count bound")
		}
	}
	if q.put(nil) || q.put(make([]byte, maxMessage+1)) {
		t.Fatal("queue unbounded")
	}
}
func TestTransportPolicyAndStrictJSON(t *testing.T) {
	defaultRequest := httptest.NewRequest("GET", "http://localhost/", nil)
	if transportAllowed(defaultRequest, false) {
		t.Fatal("plaintext relay accepted without development opt-in")
	}
	for _, tc := range []struct {
		host, remote string
		tls, allowed bool
	}{
		{"localhost:8080", "127.0.0.1:12", false, true}, {"127.0.0.1:8080", "127.0.0.1:12", false, true}, {"[::1]:8080", "[::1]:12", false, true},
		{"127.0.0.2:8080", "127.0.0.1:12", false, false}, {"localhost.evil", "127.0.0.1:12", false, false}, {"localhost", "192.0.2.1:12", false, true}, {"service.test", "192.0.2.1:12", true, true},
	} {
		r := httptest.NewRequest("GET", "http://"+tc.host+"/", nil)
		r.RemoteAddr = tc.remote
		if tc.tls {
			r.TLS = &tls.ConnectionState{}
		}
		if transportAllowed(r, true) != tc.allowed {
			t.Fatal("transport policy mismatch")
		}
	}
	for _, body := range []string{`null`, `[]`, `{} {}`, `{"grant_id":"a","grant_id":"b"}`, `{"unknown":"a"}`, `{"grant_id":1}`, `{"grant_id":"` + strings.Repeat("x", 4096) + `"}`} {
		r := httptest.NewRequest("POST", "/", strings.NewReader(body))
		w := httptest.NewRecorder()
		var v struct {
			GrantID string `json:"grant_id"`
		}
		if decodeRequest(w, r, &v) {
			t.Fatal("accepted malformed relay JSON")
		}
		if w.Code != 400 {
			t.Fatal("incorrect invalid JSON status")
		}
	}
}
func TestRouteLifecycleAndCapacity(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := &Service{hosts: map[string]*host{}, tunnels: map[string]*tunnel{}, ctx: ctx}
	hctx, hcancel := context.WithCancel(ctx)
	h := &host{ctx: hctx, cancel: hcancel, identity: pairing.RelayIdentity{Device: pairing.Device{ID: "host"}}, offers: make(chan offer, 16)}
	s.hosts["host"] = h
	tctx, tcancel := context.WithCancel(ctx)
	route := &tunnel{id: "route", host: h, ctx: tctx, cancel: tcancel}
	s.tunnels[route.id] = route
	s.dropHostLocked(h)
	if len(s.tunnels) != 0 || len(s.hosts) != 0 || hctx.Err() == nil || tctx.Err() == nil {
		t.Fatal("host drop retained routes")
	}
	// A late disconnect from a superseded host cannot remove the replacement.
	newctx, newcancel := context.WithCancel(ctx)
	defer newcancel()
	newHost := &host{ctx: newctx, cancel: newcancel, identity: h.identity}
	s.hosts["host"] = newHost
	s.dropHostLocked(h)
	if s.hosts["host"] != newHost || newctx.Err() != nil {
		t.Fatal("old disconnect removed new host")
	}
	for range maxSockets {
		if !s.acquire() {
			t.Fatal("socket bound too low")
		}
	}
	if s.acquire() {
		t.Fatal("socket bound exceeded")
	}
	s.release()
	if !s.acquire() {
		t.Fatal("socket capacity not released")
	}
}

type identity struct {
	device pairing.Device
	token  string
	key    ed25519.PrivateKey
}
type fixture struct {
	pool                *pgxpool.Pool
	auth                *pairing.Service
	relay               *Service
	server              *httptest.Server
	host, client, other identity
	grant               pairing.Grant
}

func newFixture(t *testing.T, decorate ...func(*pairing.Service) Authorizer) *fixture {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set TEST_DATABASE_URL to run relay PostgreSQL integration tests")
	}
	ctx := context.Background()
	admin, err := store.Open(ctx, url)
	if err != nil {
		t.Fatal("database unavailable")
	}
	schema := fmt.Sprintf("relay_test_%d", time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+quoted); err != nil {
		t.Fatal(err)
	}
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal("database configuration invalid")
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal("database unavailable")
	}
	t.Cleanup(func() {
		pool.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, err := admin.Exec(ctx, "DROP SCHEMA "+quoted+" CASCADE")
		admin.Close()
		if err != nil {
			t.Error("test schema cleanup failed")
		}
	})
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	auth := pairing.New(pool)
	var authorizer Authorizer = auth
	if len(decorate) > 0 {
		authorizer = decorate[0](auth)
	}
	router := New(authorizer, Options{AllowLoopbackDevelopment: true})
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	router.RegisterRoutes(mux)
	server := httptest.NewServer(mux)
	f := &fixture{pool: pool, auth: auth, relay: router, server: server}
	t.Cleanup(func() { router.Close(); server.Close() })
	f.host = f.register(t, "Mac", "macos")
	f.client = f.register(t, "Phone", "ios")
	f.other = f.register(t, "Other", "ios")
	f.grant = f.pair(t, f.client)
	return f
}

// pair pairs a client with the fixture's host for control and returns the grant.
func (f *fixture) pair(t *testing.T, client identity) pairing.Grant {
	t.Helper()
	var created struct {
		Pairing pairing.Pairing `json:"pairing"`
		Secret  string          `json:"secret"`
	}
	f.request(t, "POST", "/v1/pairings", f.host.token, struct{}{}, 201, &created)
	var p pairing.Pairing
	f.request(t, "POST", "/v1/pairings/"+created.Pairing.ID+"/join", client.token, map[string]string{"secret": created.Secret}, 200, &p)
	message := strings.Join([]string{"witerm-pair-v1", p.ID, p.Host.PublicKey, p.Client.PublicKey, "control"}, "\n")
	f.request(t, "POST", "/v1/pairings/"+p.ID+"/approve", f.host.token, map[string]string{"permission": "control", "approval_signature": base64.StdEncoding.EncodeToString(ed25519.Sign(f.host.key, []byte(message)))}, 200, &p)
	return *p.Grant
}
func (f *fixture) request(t *testing.T, method, path, token string, body any, want int, result any) {
	t.Helper()
	data, _ := json.Marshal(body)
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(data)
	}
	r, err := http.NewRequest(method, f.server.URL+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	r.Header.Set("Content-Type", "application/json")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal("HTTP request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != want {
		t.Fatalf("HTTP %d, want %d", resp.StatusCode, want)
	}
	if result != nil && json.NewDecoder(resp.Body).Decode(result) != nil {
		t.Fatal("invalid response JSON")
	}
}
func (f *fixture) register(t *testing.T, name, platform string) identity {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var challenge struct {
		ID    string `json:"challenge_id"`
		Nonce string `json:"nonce"`
	}
	f.request(t, "POST", "/v1/auth/challenges", "", map[string]string{"public_key": base64.StdEncoding.EncodeToString(pub)}, 201, &challenge)
	sig := ed25519.Sign(key, []byte(strings.Join([]string{"witerm-device-v1", challenge.ID, challenge.Nonce, name, platform}, "\n")))
	var registered struct {
		Device pairing.Device `json:"device"`
		Token  string         `json:"access_token"`
	}
	f.request(t, "POST", "/v1/devices", "", map[string]string{"challenge_id": challenge.ID, "name": name, "platform": platform, "signature": base64.StdEncoding.EncodeToString(sig)}, 200, &registered)
	return identity{registered.Device, registered.Token, key}
}
func (f *fixture) dial(t *testing.T, path, token string, want int) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	header := http.Header{}
	if token != "" {
		header.Set("Authorization", "Bearer "+token)
	}
	c, resp, err := websocket.Dial(ctx, strings.Replace(f.server.URL, "http:", "ws:", 1)+path, &websocket.DialOptions{HTTPHeader: header})
	if want != 101 {
		if err == nil {
			c.CloseNow()
			t.Fatal("unexpected WebSocket upgrade")
		}
		if resp == nil || resp.StatusCode != want {
			t.Fatalf("WebSocket rejected with unexpected status, want %d", want)
		}
		return nil
	}
	if err != nil {
		t.Fatal("WebSocket upgrade failed")
	}
	c.SetReadLimit(maxMessage)
	t.Cleanup(func() { c.CloseNow() })
	return c
}
func receive(t *testing.T, c *websocket.Conn, typ websocket.MessageType) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	actual, data, err := c.Read(ctx)
	if err != nil || actual != typ {
		t.Fatal("WebSocket receive failed")
	}
	return data
}
func send(t *testing.T, c *websocket.Conn, typ websocket.MessageType, data []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if c.Write(ctx, typ, data) != nil {
		t.Fatal("WebSocket send failed")
	}
}
func closed(t *testing.T, c *websocket.Conn) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2200*time.Millisecond)
	defer cancel()
	_, _, err := c.Read(ctx)
	if err == nil || ctx.Err() != nil {
		t.Fatal("socket was not promptly closed")
	}
}
func (f *fixture) online(t *testing.T) *websocket.Conn {
	t.Helper()
	c := f.dial(t, "/v1/relay/host", f.host.token, 101)
	if string(receive(t, c, websocket.MessageText)) != `{"type":"ready"}` {
		t.Fatal("missing initial ready")
	}
	return c
}
func (f *fixture) route(t *testing.T, h *websocket.Conn) string {
	t.Helper()
	var result struct {
		ID string `json:"tunnel_id"`
	}
	f.request(t, "POST", "/v1/relay/tunnels", f.client.token, map[string]string{"grant_id": f.grant.ID}, 201, &result)
	var o offer
	if json.Unmarshal(receive(t, h, websocket.MessageText), &o) != nil || o.Type != "offer" || o.TunnelID != result.ID || o.GrantID != f.grant.ID {
		t.Fatal("offer did not bind route and grant")
	}
	return result.ID
}

func TestRelayPostgresOpaqueFlowAuthorizationAndRevocation(t *testing.T) {
	f := newFixture(t)
	f.request(t, "POST", "/v1/relay/tunnels", "", map[string]string{"grant_id": f.grant.ID}, 401, nil)
	f.request(t, "POST", "/v1/relay/tunnels", f.host.token, map[string]string{"grant_id": f.grant.ID}, 403, nil)
	f.request(t, "POST", "/v1/relay/tunnels", f.other.token, map[string]string{"grant_id": f.grant.ID}, 404, nil)
	f.request(t, "POST", "/v1/relay/tunnels", f.client.token, map[string]string{"grant_id": f.grant.ID}, 409, nil)
	f.dial(t, "/v1/relay/host", f.client.token, 403)
	h := f.online(t)
	id := f.route(t, h)
	path := "/v1/relay/tunnels/" + id
	f.dial(t, path, f.other.token, 404)
	client := f.dial(t, path, f.client.token, 101)
	// The initial Noise bytes may precede the host leg; they must be buffered
	// unchanged and in order, without needing a payload-aware routing step.
	first := []byte{0, 255, 19, 1, 0, 128}
	send(t, client, websocket.MessageBinary, first)
	host := f.dial(t, path, f.host.token, 101)
	if !bytes.Equal(receive(t, host, websocket.MessageBinary), first) {
		t.Fatal("opaque initial bytes changed")
	}
	for _, payload := range [][]byte{nil, {0, 0, 255}, bytes.Repeat([]byte{173}, maxMessage)} {
		send(t, host, websocket.MessageBinary, payload)
		if !bytes.Equal(receive(t, client, websocket.MessageBinary), payload) {
			t.Fatal("opaque payload changed")
		}
	}
	f.dial(t, path, f.client.token, 404)
	f.request(t, "DELETE", "/v1/grants/"+f.grant.ID, f.client.token, nil, 204, nil)
	closed(t, client)
	closed(t, host)
	f.dial(t, path, f.host.token, 404)
	f.request(t, "POST", "/v1/relay/tunnels", f.client.token, map[string]string{"grant_id": f.grant.ID}, 404, nil)
}

func TestRelayPostgresReconnectExpiryAndBounds(t *testing.T) {
	f := newFixture(t)
	h := f.online(t)
	id := f.route(t, h)
	client := f.dial(t, "/v1/relay/tunnels/"+id, f.client.token, 101)
	newHost := f.online(t)
	closed(t, h)
	closed(t, client)
	f.dial(t, "/v1/relay/tunnels/"+id, f.host.token, 404)
	for range maxClientTunnels {
		f.route(t, newHost)
	}
	f.request(t, "POST", "/v1/relay/tunnels", f.client.token, map[string]string{"grant_id": f.grant.ID}, 429, nil)
	// Advance only pending route deadlines; authentication remains real.
	f.relay.mu.Lock()
	var expired string
	for _, route := range f.relay.tunnels {
		route.expires = time.Now().Add(-time.Second)
		expired = route.id
	}
	f.relay.mu.Unlock()
	f.dial(t, "/v1/relay/tunnels/"+expired, f.host.token, 404)
	newHost.CloseNow()
	eventually(t, func() bool {
		f.relay.mu.Lock()
		defer f.relay.mu.Unlock()
		return len(f.relay.tunnels) == 0 && len(f.relay.hosts) == 0
	})
}

// A Mac serves every device paired with it: two clients at their own bound
// fit within the Mac's, and a third client finds the Mac full.
func TestRelayPostgresHostServesSeveralClients(t *testing.T) {
	f := newFixture(t)
	f.online(t)
	tablet := f.register(t, "Tablet", "ios")
	clients := []struct {
		identity
		grant pairing.Grant
	}{{f.client, f.grant}, {f.other, f.pair(t, f.other)}, {tablet, f.pair(t, tablet)}}
	for _, c := range clients[:2] {
		for range maxClientTunnels {
			f.request(t, "POST", "/v1/relay/tunnels", c.token, map[string]string{"grant_id": c.grant.ID}, 201, nil)
		}
		f.request(t, "POST", "/v1/relay/tunnels", c.token, map[string]string{"grant_id": c.grant.ID}, 429, nil)
	}
	if 2*maxClientTunnels != maxHostTunnels {
		t.Fatal("test assumes two full clients fill the host")
	}
	f.request(t, "POST", "/v1/relay/tunnels", clients[2].token, map[string]string{"grant_id": clients[2].grant.ID}, 429, nil)
}

// Joining tunnels has its own budget, so a Mac answering several devices
// isn't limited to one device's worth of tunnels, and both stay bounded.
func TestRelayPostgresJoinsHaveTheirOwnBudget(t *testing.T) {
	f := newFixture(t)
	authenticate := func(access pairing.RelayAccess) error {
		r := httptest.NewRequest("GET", "/v1/relay/tunnels/"+f.grant.ID, nil)
		r.Header.Set("Authorization", "Bearer "+f.host.token)
		_, err := f.auth.AuthenticateRelay(context.Background(), r, access)
		return err
	}
	opened := 0
	for authenticate(pairing.RelayOpen) == nil {
		opened++
		if opened > 1000 {
			t.Fatal("open budget is unbounded")
		}
	}
	joined := 0
	for authenticate(pairing.RelayJoin) == nil {
		joined++
		if joined > 1000 {
			t.Fatal("join budget is unbounded")
		}
	}
	if opened != 30 || joined != 120 {
		t.Fatalf("opened %d and joined %d, want 30 and 120", opened, joined)
	}
	if err := authenticate(pairing.RelayOpen); err != pairing.ErrRelayRateLimited {
		t.Fatal("a spent budget must report rate_limited")
	}
}

func TestRelayPostgresGlobalAndHostOfferBounds(t *testing.T) {
	t.Run("global", func(t *testing.T) {
		f := newFixture(t)
		f.online(t)
		// Fill the bounded router with inert, individually cancellable routes;
		// the request itself still performs real token/grant authorization.
		f.relay.mu.Lock()
		for i := range maxTunnels {
			ctx, cancel := context.WithCancel(f.relay.ctx)
			id := fmt.Sprintf("occupied-%d", i)
			f.relay.tunnels[id] = &tunnel{id: id, grant: f.grant, ctx: ctx, cancel: cancel}
		}
		f.relay.mu.Unlock()
		f.request(t, "POST", "/v1/relay/tunnels", f.client.token, map[string]string{"grant_id": f.grant.ID}, 429, nil)
	})
	t.Run("offers", func(t *testing.T) {
		f := newFixture(t)
		// A live-host slot with a deliberately stalled offer consumer makes
		// overflow deterministic without depending on OS socket buffer sizes.
		ctx, cancel := context.WithCancel(f.relay.ctx)
		h := &host{ctx: ctx, cancel: cancel, identity: pairing.RelayIdentity{Device: f.host.device}, offers: make(chan offer, 16)}
		for range 16 {
			h.offers <- offer{Type: "offer"}
		}
		f.relay.mu.Lock()
		f.relay.hosts[f.host.device.ID] = h
		f.relay.mu.Unlock()
		f.request(t, "POST", "/v1/relay/tunnels", f.client.token, map[string]string{"grant_id": f.grant.ID}, 409, nil)
		f.relay.mu.Lock()
		defer f.relay.mu.Unlock()
		if len(f.relay.tunnels) != 0 || len(f.relay.hosts) != 0 || ctx.Err() == nil {
			t.Fatal("offer overflow retained an unserviceable route")
		}
	})
}
func TestRelayPostgresMalformedOversizedAndBackpressure(t *testing.T) {
	for _, mode := range []string{"text", "oversized", "backpressure"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			h := f.online(t)
			id := f.route(t, h)
			client := f.dial(t, "/v1/relay/tunnels/"+id, f.client.token, 101)
			switch mode {
			case "text":
				send(t, client, websocket.MessageText, []byte(`{}`))
			case "oversized":
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				_ = client.Write(ctx, websocket.MessageBinary, make([]byte, maxMessage+1))
				cancel()
			case "backpressure":
				for range 5 {
					ctx, cancel := context.WithTimeout(context.Background(), time.Second)
					_ = client.Write(ctx, websocket.MessageBinary, make([]byte, maxMessage))
					cancel()
				}
			}
			closed(t, client)
			f.dial(t, "/v1/relay/tunnels/"+id, f.host.token, 404)
		})
	}
}
func TestRelayPostgresDeviceGrantAndDatabaseFailClosed(t *testing.T) {
	for _, mode := range []string{"device", "grant", "database", "database_timeout", "token"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			h := f.online(t)
			id := f.route(t, h)
			client := f.dial(t, "/v1/relay/tunnels/"+id, f.client.token, 101)
			host := f.dial(t, "/v1/relay/tunnels/"+id, f.host.token, 101)
			switch mode {
			case "device":
				if _, err := f.pool.Exec(context.Background(), `UPDATE devices SET revoked_at=now() WHERE id=$1`, f.client.device.ID); err != nil {
					t.Fatal(err)
				}
			case "grant":
				if _, err := f.pool.Exec(context.Background(), `UPDATE device_grants SET revoked_at=now() WHERE id=$1`, f.grant.ID); err != nil {
					t.Fatal(err)
				}
			case "database":
				f.pool.Close()
			case "database_timeout":
				tx, err := f.pool.Begin(context.Background())
				if err != nil {
					t.Fatal("database unavailable")
				}
				defer tx.Rollback(context.Background())
				if _, err := tx.Exec(context.Background(), `LOCK TABLE device_grants IN ACCESS EXCLUSIVE MODE`); err != nil {
					t.Fatal("database lock failed")
				}
			case "token": // Re-registration evicts the oldest bearer session at four.
				// Expiry timestamps are whole seconds; ensure renewed sessions
				// are newer, rather than relying on map-order ties among equals.
				time.Sleep(time.Second)
				for range 4 {
					pub := f.client.key.Public().(ed25519.PublicKey)
					var ch struct {
						ID    string `json:"challenge_id"`
						Nonce string `json:"nonce"`
					}
					f.request(t, "POST", "/v1/auth/challenges", "", map[string]string{"public_key": base64.StdEncoding.EncodeToString(pub)}, 201, &ch)
					sig := ed25519.Sign(f.client.key, []byte(strings.Join([]string{"witerm-device-v1", ch.ID, ch.Nonce, "Phone", "ios"}, "\n")))
					f.request(t, "POST", "/v1/devices", "", map[string]string{"challenge_id": ch.ID, "name": "Phone", "platform": "ios", "signature": base64.StdEncoding.EncodeToString(sig)}, 200, nil)
				}
			}
			closed(t, client)
			closed(t, host)
		})
	}
}
func TestRelayPostgresConcurrentOpenAndRevoke(t *testing.T) {
	f := newFixture(t)
	h := f.online(t)
	id := f.route(t, h)
	path := "/v1/relay/tunnels/" + id
	var wg sync.WaitGroup
	wg.Add(2)
	var conn *websocket.Conn
	go func() {
		defer wg.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		conn, _, _ = websocket.Dial(ctx, strings.Replace(f.server.URL, "http:", "ws:", 1)+path, &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer " + f.client.token}}})
	}()
	go func() { defer wg.Done(); f.request(t, "DELETE", "/v1/grants/"+f.grant.ID, f.host.token, nil, 204, nil) }()
	wg.Wait()
	if conn != nil {
		defer conn.CloseNow()
		closed(t, conn)
	}
	f.dial(t, path, f.host.token, 404)
	eventually(t, func() bool { f.relay.mu.Lock(); defer f.relay.mu.Unlock(); return len(f.relay.tunnels) == 0 })
}
func TestRelayPostgresOriginAndUnknownRoleRejected(t *testing.T) {
	f := newFixture(t)
	h := f.online(t)
	id := f.route(t, h)
	for _, path := range []string{"/v1/relay/host", "/v1/relay/tunnels/" + id} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		c, resp, err := websocket.Dial(ctx, strings.Replace(f.server.URL, "http:", "ws:", 1)+path, &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer " + f.host.token}, "Origin": []string{f.server.URL}}})
		cancel()
		if c != nil {
			c.CloseNow()
		}
		if err == nil || resp == nil || resp.StatusCode != 403 {
			t.Fatal("Origin was accepted")
		}
	}
	f.dial(t, "/v1/relay/tunnels/"+id+"?role=host", f.client.token, 400)
	if capabilities := f.relay.Capabilities(); len(capabilities) != 1 || capabilities[0] != "encrypted_relay_v1" {
		t.Fatal("verified relay capability is missing")
	}
}

func TestRelayPostgresHostControlBound(t *testing.T) {
	f := newFixture(t)
	h := f.online(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	_ = h.Write(ctx, websocket.MessageText, make([]byte, 4097))
	cancel()
	closed(t, h)
	eventually(t, func() bool { f.relay.mu.Lock(); defer f.relay.mu.Unlock(); return len(f.relay.hosts) == 0 })
}

// The real pairing service still authenticates every credential and grant;
// only a returned socket deadline is shortened to test expiry without an hour.
type expiringAuthorizer struct {
	*pairing.Service
	host bool
}

func (a expiringAuthorizer) AuthenticateRelay(ctx context.Context, r *http.Request, access pairing.RelayAccess) (pairing.RelayIdentity, error) {
	identity, err := a.Service.AuthenticateRelay(ctx, r, access)
	if err == nil && (a.host && r.URL.Path == "/v1/relay/host" || !a.host && r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/v1/relay/tunnels/") && identity.Device.Platform == "ios") {
		identity.ExpiresAt = time.Now().Add(800 * time.Millisecond)
	}
	return identity, err
}
func TestRelayPostgresSocketTokenDeadlines(t *testing.T) {
	for _, hostExpiry := range []bool{false, true} {
		t.Run(fmt.Sprintf("host_%t", hostExpiry), func(t *testing.T) {
			f := newFixture(t, func(auth *pairing.Service) Authorizer { return expiringAuthorizer{auth, hostExpiry} })
			h := f.online(t)
			id := f.route(t, h)
			client := f.dial(t, "/v1/relay/tunnels/"+id, f.client.token, 101)
			host := f.dial(t, "/v1/relay/tunnels/"+id, f.host.token, 101)
			closed(t, client)
			closed(t, host)
			if hostExpiry {
				closed(t, h)
			}
			f.dial(t, "/v1/relay/tunnels/"+id, f.host.token, 404)
		})
	}
}

func TestRelayPostgresTLSWithoutDevelopmentException(t *testing.T) {
	f := newFixture(t)
	// Replace only the HTTP listener/router, retaining the same real database,
	// verified identities and bearer sessions.
	f.relay.Close()
	f.server.Close()
	router := New(f.auth)
	mux := http.NewServeMux()
	f.auth.RegisterRoutes(mux)
	router.RegisterRoutes(mux)
	server := httptest.NewTLSServer(mux)
	defer server.Close()
	defer router.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, strings.Replace(server.URL, "https:", "wss:", 1)+"/v1/relay/host", &websocket.DialOptions{HTTPClient: server.Client(), HTTPHeader: http.Header{"Authorization": []string{"Bearer " + f.host.token}}})
	if err != nil {
		t.Fatal("trusted native TLS upgrade failed")
	}
	defer c.CloseNow()
	if string(receive(t, c, websocket.MessageText)) != `{"type":"ready"}` {
		t.Fatal("TLS host missing ready")
	}
}
func eventually(t *testing.T, predicate func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if predicate() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("relay state was not promptly released")
}
