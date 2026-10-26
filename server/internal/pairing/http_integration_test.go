package pairing

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"witerm/server/internal/store"
)

func testDatabase(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set TEST_DATABASE_URL to run pairing integration tests")
	}
	ctx := context.Background()
	admin, err := store.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("pairing_test_%d", time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+quoted); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		pool.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, err := admin.Exec(ctx, "DROP SCHEMA "+quoted+" CASCADE")
		admin.Close()
		if err != nil {
			t.Error(err)
		}
	})
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}

type testIdentity struct {
	Device Device
	Token  string
	Key    ed25519.PrivateKey
}

func request(h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func requireStatus(t *testing.T, w *httptest.ResponseRecorder, status int) {
	t.Helper()
	if w.Code != status {
		t.Fatalf("HTTP status %d, want %d", w.Code, status)
	}
}

func registerTestIdentity(t *testing.T, h http.Handler, name, platform string) testIdentity {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return registerTestIdentityWithKey(t, h, name, platform, key)
}

func registerTestIdentityWithKey(t *testing.T, h http.Handler, name, platform string, key ed25519.PrivateKey) testIdentity {
	t.Helper()
	pub := key.Public().(ed25519.PublicKey)
	w := request(h, "POST", "/v1/auth/challenges", "", map[string]any{"public_key": base64.StdEncoding.EncodeToString(pub)})
	requireStatus(t, w, 201)
	var c struct {
		ID    string `json:"challenge_id"`
		Nonce string `json:"nonce"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &c); err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(key, registrationMessage(c.ID, c.Nonce, name, platform))
	w = request(h, "POST", "/v1/devices", "", map[string]any{"challenge_id": c.ID, "name": name, "platform": platform, "signature": base64.StdEncoding.EncodeToString(sig)})
	requireStatus(t, w, 200)
	var registered struct {
		Device Device `json:"device"`
		Token  string `json:"access_token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &registered); err != nil {
		t.Fatal(err)
	}
	return testIdentity{registered.Device, registered.Token, key}
}

func createTestPairing(t *testing.T, h http.Handler, host testIdentity) (Pairing, string) {
	t.Helper()
	w := request(h, "POST", "/v1/pairings", host.Token, struct{}{})
	requireStatus(t, w, 201)
	var result struct {
		Pairing Pairing `json:"pairing"`
		Secret  string  `json:"secret"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result.Pairing, result.Secret
}

func TestPairingHTTPFlowAndAuthorization(t *testing.T) {
	pool := testDatabase(t)
	s := New(pool)
	h := http.NewServeMux()
	s.RegisterRoutes(h)
	host := registerTestIdentity(t, h, "Mac", "macos")
	phone := registerTestIdentity(t, h, "iPhone", "ios")
	outsider := registerTestIdentity(t, h, "Other phone", "ios")
	p, secret := createTestPairing(t, h, host)
	if p.Status != "waiting" || p.Client != nil || p.Grant != nil {
		t.Fatal("new invitation has authorization")
	}
	path := "/v1/pairings/" + p.ID
	requireStatus(t, request(h, "GET", path, "", nil), 401)
	requireStatus(t, request(h, "GET", path, outsider.Token, nil), 404)
	requireStatus(t, request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": "invalid"}), 404)
	w := request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": secret})
	requireStatus(t, w, 200)
	if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
		t.Fatal(err)
	}
	if p.Status != "pending" || p.Grant != nil {
		t.Fatal("join granted access without host approval")
	}
	requireStatus(t, request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": secret}), 200)
	requireStatus(t, request(h, "POST", path+"/join", outsider.Token, map[string]string{"secret": secret}), 404)
	for _, identity := range []testIdentity{host, phone, outsider} {
		w := request(h, "GET", "/v1/grants", identity.Token, nil)
		requireStatus(t, w, 200)
		if strings.TrimSpace(w.Body.String()) != "{\"grants\":[]}" {
			t.Fatal("pending invitation exposed grants")
		}
	}
	badSig := base64.StdEncoding.EncodeToString(ed25519.Sign(phone.Key, approvalMessage(p, "control")))
	requireStatus(t, request(h, "POST", path+"/approve", host.Token, map[string]string{"permission": "control", "approval_signature": badSig}), 403)
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(host.Key, approvalMessage(p, "control")))
	approve := map[string]string{"permission": "control", "approval_signature": sig}
	w = request(h, "POST", path+"/approve", host.Token, approve)
	requireStatus(t, w, 200)
	if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
		t.Fatal(err)
	}
	if p.Status != "approved" || p.Grant == nil {
		t.Fatal("host approval did not create grant")
	}
	grantID := p.Grant.ID
	requireStatus(t, request(h, "POST", path+"/approve", host.Token, approve), 200)
	for _, identity := range []testIdentity{host, phone} {
		w := request(h, "GET", "/v1/grants", identity.Token, nil)
		requireStatus(t, w, 200)
		var body struct {
			Grants []Grant `json:"grants"`
		}
		json.Unmarshal(w.Body.Bytes(), &body)
		if len(body.Grants) != 1 || body.Grants[0].ID != grantID {
			t.Fatal("participant list incorrect")
		}
	}
	requireStatus(t, request(h, "DELETE", "/v1/grants/"+grantID, outsider.Token, nil), 404)
	requireStatus(t, request(h, "DELETE", "/v1/grants/"+grantID, phone.Token, nil), 204)
	requireStatus(t, request(h, "DELETE", "/v1/grants/"+grantID, phone.Token, nil), 204)
	w = request(h, "POST", path+"/approve", host.Token, approve)
	requireStatus(t, w, 200)
	var revoked Pairing
	json.Unmarshal(w.Body.Bytes(), &revoked)
	if revoked.Grant != nil {
		t.Fatal("approval retry resurrected revoked grant")
	}
	for _, identity := range []testIdentity{host, phone, outsider} {
		w := request(h, "GET", "/v1/grants", identity.Token, nil)
		requireStatus(t, w, 200)
		if strings.TrimSpace(w.Body.String()) != "{\"grants\":[]}" {
			t.Fatal("revoked grant exposed")
		}
	}

	// Explicit rejection and expiration cannot be bypassed by late approval/join.
	p, secret = createTestPairing(t, h, host)
	path = "/v1/pairings/" + p.ID
	requireStatus(t, request(h, "POST", path+"/reject", host.Token, struct{}{}), 200)
	requireStatus(t, request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": secret}), 404)
	p, secret = createTestPairing(t, h, host)
	path = "/v1/pairings/" + p.ID
	clock := s.now()
	s.now = func() time.Time { return clock.Add(5 * time.Minute) }
	requireStatus(t, request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": secret}), 404)
	s.now = time.Now
	p, secret = createTestPairing(t, h, host)
	path = "/v1/pairings/" + p.ID
	w = request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": secret})
	requireStatus(t, w, 200)
	json.Unmarshal(w.Body.Bytes(), &p)
	sig = base64.StdEncoding.EncodeToString(ed25519.Sign(host.Key, approvalMessage(p, "control")))
	clock = s.now()
	s.now = func() time.Time { return clock.Add(5 * time.Minute) }
	requireStatus(t, request(h, "POST", path+"/approve", host.Token, map[string]string{"permission": "control", "approval_signature": sig}), 409)
	s.now = time.Now
	// Bearer sessions are checked against durable device revocation on every request.
	if _, err := pool.Exec(context.Background(), `UPDATE devices SET revoked_at=now() WHERE id=$1`, phone.Device.ID); err != nil {
		t.Fatal(err)
	}
	requireStatus(t, request(h, "GET", "/v1/grants", phone.Token, nil), 401)
}

func TestPairingClaimsRaceAndNewInvitation(t *testing.T) {
	pool := testDatabase(t)
	s := New(pool)
	h := http.NewServeMux()
	s.RegisterRoutes(h)
	host := registerTestIdentity(t, h, "Mac", "macos")
	a := registerTestIdentity(t, h, "A", "ios")
	b := registerTestIdentity(t, h, "B", "ios")
	p, secret := createTestPairing(t, h, host)
	path := "/v1/pairings/" + p.ID
	results := make(chan int, 2)
	for _, client := range []testIdentity{a, b} {
		go func(client testIdentity) {
			results <- request(h, "POST", path+"/join", client.Token, map[string]string{"secret": secret}).Code
		}(client)
	}
	counts := map[int]int{}
	for range 2 {
		counts[<-results]++
	}
	if counts[200] != 1 || counts[404] != 1 {
		t.Fatalf("competing claims: %v", counts)
	}
	createTestPairing(t, h, host)
	w := request(h, "GET", path, host.Token, nil)
	requireStatus(t, w, 200)
	json.Unmarshal(w.Body.Bytes(), &p)
	if p.Status != "rejected" {
		t.Fatal("new invitation did not cancel earlier live invitation")
	}
	created := make(chan int, 3)
	for range 3 {
		go func() { created <- request(h, "POST", "/v1/pairings", host.Token, struct{}{}).Code }()
	}
	for range 3 {
		if code := <-created; code != 201 {
			t.Fatalf("concurrent invitation creation: %d", code)
		}
	}
	var live int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM pairing_requests WHERE host_device_id=$1 AND status IN ('waiting','pending')`, host.Device.ID).Scan(&live); err != nil {
		t.Fatal(err)
	}
	if live != 1 {
		t.Fatal("concurrent creation left multiple live invitations")
	}
	requireStatus(t, request(h, "POST", "/v1/pairings", a.Token, struct{}{}), 403)
}

func TestRegistrationReplayExpiryStrictJSONAndLimits(t *testing.T) {
	pool := testDatabase(t)
	s := New(pool)
	h := http.NewServeMux()
	s.RegisterRoutes(h)
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	challengeBody := map[string]string{"public_key": base64.StdEncoding.EncodeToString(pub)}
	makeProof := func() map[string]string {
		w := request(h, "POST", "/v1/auth/challenges", "", challengeBody)
		requireStatus(t, w, 201)
		var c struct {
			ID    string `json:"challenge_id"`
			Nonce string `json:"nonce"`
		}
		json.Unmarshal(w.Body.Bytes(), &c)
		sig := ed25519.Sign(key, registrationMessage(c.ID, c.Nonce, "Mac", "macos"))
		return map[string]string{"challenge_id": c.ID, "name": "Mac", "platform": "macos", "signature": base64.StdEncoding.EncodeToString(sig)}
	}
	proof := makeProof()
	wRegistered := request(h, "POST", "/v1/devices", "", proof)
	requireStatus(t, wRegistered, 200)
	var original struct {
		Device Device `json:"device"`
	}
	json.Unmarshal(wRegistered.Body.Bytes(), &original)
	requireStatus(t, request(h, "POST", "/v1/devices", "", proof), 401)
	proof = makeProof()
	correctSignature := proof["signature"]
	proof["signature"] = base64.StdEncoding.EncodeToString(make([]byte, 64))
	requireStatus(t, request(h, "POST", "/v1/devices", "", proof), 401)
	proof["signature"] = correctSignature
	requireStatus(t, request(h, "POST", "/v1/devices", "", proof), 401)
	proof = makeProof()
	clock := s.now()
	s.now = func() time.Time { return clock.Add(time.Minute) }
	requireStatus(t, request(h, "POST", "/v1/devices", "", proof), 401)
	s.now = time.Now
	r := httptest.NewRequest("POST", "/v1/auth/challenges", strings.NewReader(`{"public_key":"x","unknown":true}`))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	requireStatus(t, w, 400)
	r = httptest.NewRequest("POST", "/v1/auth/challenges", strings.NewReader(`{} {}`))
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	requireStatus(t, w, 400)
	r = httptest.NewRequest("POST", "/v1/auth/challenges", strings.NewReader(`null`))
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	requireStatus(t, w, 400)
	r = httptest.NewRequest("POST", "/v1/auth/challenges", strings.NewReader(`{"public_key":"`+strings.Repeat("a", 17000)+`"}`))
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	requireStatus(t, w, 400)
	if _, err := pool.Exec(context.Background(), `UPDATE devices SET revoked_at=now() WHERE id=$1`, original.Device.ID); err != nil {
		t.Fatal(err)
	}
	proof = makeProof()
	requireStatus(t, request(h, "POST", "/v1/devices", "", proof), 401)
	s.memory = newMemory()
	for range 30 {
		requireStatus(t, request(h, "POST", "/v1/auth/challenges", "", challengeBody), 201)
	}
	requireStatus(t, request(h, "POST", "/v1/auth/challenges", "", challengeBody), 429)
}

func TestClientMayRevokeWithRevokedHost(t *testing.T) {
	pool := testDatabase(t)
	s := New(pool)
	h := http.NewServeMux()
	s.RegisterRoutes(h)
	host := registerTestIdentity(t, h, "Mac", "macos")
	phone := registerTestIdentity(t, h, "Phone", "ios")
	p, secret := createTestPairing(t, h, host)
	path := "/v1/pairings/" + p.ID
	w := request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": secret})
	requireStatus(t, w, 200)
	json.Unmarshal(w.Body.Bytes(), &p)
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(host.Key, approvalMessage(p, "view")))
	w = request(h, "POST", path+"/approve", host.Token, map[string]string{"permission": "view", "approval_signature": sig})
	requireStatus(t, w, 200)
	json.Unmarshal(w.Body.Bytes(), &p)
	if _, err := pool.Exec(context.Background(), `UPDATE devices SET revoked_at=now() WHERE id=$1`, host.Device.ID); err != nil {
		t.Fatal(err)
	}
	requireStatus(t, request(h, "DELETE", "/v1/grants/"+p.Grant.ID, phone.Token, nil), 204)
	var revoked bool
	if err := pool.QueryRow(context.Background(), `SELECT revoked_at IS NOT NULL FROM device_grants WHERE id=$1`, p.Grant.ID).Scan(&revoked); err != nil {
		t.Fatal(err)
	}
	if !revoked {
		t.Fatal("revocation did not persist")
	}
}

func TestApprovalRetryAcceptsAlternateValidSignature(t *testing.T) {
	pool := testDatabase(t)
	s := New(pool)
	h := http.NewServeMux()
	s.RegisterRoutes(h)
	data, err := os.ReadFile("../../../protocol/fixtures/pairing-signatures-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		HostSeed   string `json:"host_seed_hex"`
		ClientSeed string `json:"client_seed_hex"`
		Approval   struct {
			ID        string `json:"pairing_id"`
			Signature string `json:"signature"`
			Alternate string `json:"alternate_signature"`
		} `json:"approval"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	hostSeed, err := hex.DecodeString(fixture.HostSeed)
	if err != nil {
		t.Fatal(err)
	}
	clientSeed, err := hex.DecodeString(fixture.ClientSeed)
	if err != nil {
		t.Fatal(err)
	}
	host := registerTestIdentityWithKey(t, h, "Mac", "macos", ed25519.NewKeyFromSeed(hostSeed))
	phone := registerTestIdentityWithKey(t, h, "Phone", "ios", ed25519.NewKeyFromSeed(clientSeed))
	p, secret := createTestPairing(t, h, host)
	if _, err := pool.Exec(context.Background(), `UPDATE pairing_requests SET id=$2 WHERE id=$1`, p.ID, fixture.Approval.ID); err != nil {
		t.Fatal(err)
	}
	p.ID = fixture.Approval.ID
	path := "/v1/pairings/" + p.ID
	requireStatus(t, request(h, "POST", path+"/join", phone.Token, map[string]string{"secret": secret}), 200)
	approve := func(signature string) *httptest.ResponseRecorder {
		return request(h, "POST", path+"/approve", host.Token, map[string]string{"permission": "control", "approval_signature": signature})
	}
	w := approve(fixture.Approval.Signature)
	requireStatus(t, w, 200)
	json.Unmarshal(w.Body.Bytes(), &p)
	originalID := p.Grant.ID
	w = approve(fixture.Approval.Alternate)
	requireStatus(t, w, 200)
	json.Unmarshal(w.Body.Bytes(), &p)
	if p.Grant.ID != originalID || p.Grant.ApprovalSignature != fixture.Approval.Signature {
		t.Fatal("retry changed original signed grant")
	}
	viewSignature := base64.StdEncoding.EncodeToString(ed25519.Sign(host.Key, approvalMessage(p, "view")))
	requireStatus(t, request(h, "POST", path+"/approve", host.Token, map[string]string{"permission": "view", "approval_signature": viewSignature}), 409)
}
