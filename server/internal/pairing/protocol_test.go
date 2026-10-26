package pairing

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"sync"
	"testing"
	"time"
)

func TestSharedSignatureVectors(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/pairing-signatures-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		HostKey      string `json:"host_public_key"`
		Registration struct {
			ID        string `json:"challenge_id"`
			Nonce     string `json:"nonce"`
			Name      string `json:"name"`
			Platform  string `json:"platform"`
			Message   string `json:"message"`
			Signature string `json:"signature"`
		} `json:"registration"`
		Approval struct {
			ID                 string `json:"pairing_id"`
			HostKey            string `json:"host_public_key"`
			ClientKey          string `json:"client_public_key"`
			Permission         string `json:"permission"`
			Message            string `json:"message"`
			Signature          string `json:"signature"`
			AlternateSignature string `json:"alternate_signature"`
		} `json:"approval"`
	}
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	key, err := decodePublicKey(f.HostKey)
	if err != nil {
		t.Fatal(err)
	}
	r := f.Registration
	message := registrationMessage(r.ID, r.Nonce, r.Name, r.Platform)
	signature, _ := base64.StdEncoding.DecodeString(r.Signature)
	if string(message) != r.Message || !ed25519.Verify(key, message, signature) {
		t.Fatal("registration contract mismatch")
	}
	a := f.Approval
	p := Pairing{ID: a.ID, Host: Device{PublicKey: a.HostKey}, Client: &Device{PublicKey: a.ClientKey}}
	message = approvalMessage(p, a.Permission)
	signature, _ = base64.StdEncoding.DecodeString(a.Signature)
	if string(message) != a.Message || !ed25519.Verify(key, message, signature) {
		t.Fatal("approval contract mismatch")
	}
	if ed25519.Verify(key, approvalMessage(p, "view"), signature) {
		t.Fatal("signature did not bind permission")
	}
	alternate, err := base64.StdEncoding.DecodeString(a.AlternateSignature)
	if err != nil || a.AlternateSignature == a.Signature || !ed25519.Verify(key, message, alternate) {
		t.Fatal("alternate approval fixture must be different and valid")
	}
}

func TestChallengeConsumptionAndMemoryBounds(t *testing.T) {
	now := time.Now()
	m := newMemory()
	m.putChallenge(challenge{ID: "one", ExpiresAt: now.Add(time.Minute)}, now)
	var wg sync.WaitGroup
	results := make(chan bool, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); _, ok := m.consumeChallenge("one", now); results <- ok }()
	}
	wg.Wait()
	close(results)
	count := 0
	for ok := range results {
		if ok {
			count++
		}
	}
	if count != 1 {
		t.Fatal("challenge consumed more than once")
	}
	m.putChallenge(challenge{ID: "expired", ExpiresAt: now}, now)
	if _, ok := m.consumeChallenge("expired", now); ok {
		t.Fatal("challenge expiry is not exclusive")
	}
	for i := 0; i < 30; i++ {
		if !m.allow("ip", now) {
			t.Fatal("early rate limit")
		}
	}
	if m.allow("ip", now) {
		t.Fatal("missing rate limit")
	}
	if !m.allow("ip", now.Add(time.Minute)) {
		t.Fatal("rate window did not expire")
	}
	for i := 0; i < memoryCapacity; i++ {
		m.challenges[time.Unix(int64(i), 0).String()] = challenge{ExpiresAt: now.Add(time.Hour)}
	}
	if m.putChallenge(challenge{ID: "overflow", ExpiresAt: now.Add(time.Hour)}, now) {
		t.Fatal("challenge memory is unbounded")
	}
}

func TestSessionHashExpiryAndBoundedParallelClients(t *testing.T) {
	now := time.Now()
	m := newMemory()
	if !m.putSession("secret-one", "device", now.Add(time.Hour), now) {
		t.Fatal("put failed")
	}
	if _, ok := m.getSession("secret-one", now); !ok {
		t.Fatal("valid session missing")
	}
	m.putSession("secret-two", "device", now.Add(time.Hour+time.Second), now)
	if _, ok := m.getSession("secret-one", now); !ok {
		t.Fatal("parallel foreground client invalidated an existing session")
	}
	for i := 2; i < 5; i++ {
		m.putSession(time.Unix(int64(i), 0).String(), "device", now.Add(time.Hour+time.Duration(i)*time.Second), now)
	}
	if len(m.sessions) != 4 {
		t.Fatal("per-device session bound failed")
	}
	if _, ok := m.getSession("secret-one", now); ok {
		t.Fatal("oldest-expiring bearer was not evicted")
	}
	if _, ok := m.getSession("secret-two", now.Add(time.Hour+time.Second)); ok {
		t.Fatal("expired token accepted")
	}
}
