package pairing

import (
	"crypto/ed25519"
	"crypto/sha256"
	"sync"
	"time"
)

const (
	memoryCapacity = 10000
	// rateLimit is the default number of requests per key per minute.
	rateLimit = 30
)

type challenge struct {
	ID        string
	Nonce     string
	Key       ed25519.PublicKey
	ExpiresAt time.Time
}

type session struct {
	DeviceID  string
	ExpiresAt time.Time
}

type rateWindow struct {
	Count     int
	ExpiresAt time.Time
}

type memory struct {
	mu         sync.Mutex
	challenges map[string]challenge
	sessions   map[[32]byte]session
	rates      map[string]rateWindow
}

func newMemory() *memory {
	return &memory{challenges: make(map[string]challenge), sessions: make(map[[32]byte]session), rates: make(map[string]rateWindow)}
}

func (m *memory) clean(now time.Time) {
	for id, item := range m.challenges {
		if !now.Before(item.ExpiresAt) {
			delete(m.challenges, id)
		}
	}
	for id, item := range m.sessions {
		if !now.Before(item.ExpiresAt) {
			delete(m.sessions, id)
		}
	}
	for id, item := range m.rates {
		if !now.Before(item.ExpiresAt) {
			delete(m.rates, id)
		}
	}
}

func (m *memory) allow(key string, now time.Time) bool { return m.allowUpTo(key, rateLimit, now) }

// allowUpTo counts one request against a fixed one-minute window of limit.
func (m *memory) allowUpTo(key string, limit int, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.clean(now)
	window, exists := m.rates[key]
	if !exists {
		if len(m.rates) >= memoryCapacity {
			return false
		}
		window.ExpiresAt = now.Add(time.Minute)
	}
	if window.Count >= limit {
		return false
	}
	window.Count++
	m.rates[key] = window
	return true
}

func (m *memory) putChallenge(c challenge, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.clean(now)
	if len(m.challenges) >= memoryCapacity {
		return false
	}
	m.challenges[c.ID] = c
	return true
}

func (m *memory) consumeChallenge(id string, now time.Time) (challenge, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.challenges[id]
	delete(m.challenges, id)
	return c, ok && now.Before(c.ExpiresAt)
}

func (m *memory) putSession(token, deviceID string, expires, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.clean(now)
	// Keep a small number of independent foreground clients from invalidating
	// each other on renewal while retaining both per-device and global bounds.
	count := 0
	var oldestHash [32]byte
	var oldestExpiry time.Time
	for hash, item := range m.sessions {
		if item.DeviceID == deviceID {
			count++
			if oldestExpiry.IsZero() || item.ExpiresAt.Before(oldestExpiry) {
				oldestHash, oldestExpiry = hash, item.ExpiresAt
			}
		}
	}
	if count >= 4 {
		delete(m.sessions, oldestHash)
	}
	if len(m.sessions) >= memoryCapacity {
		return false
	}
	m.sessions[sha256.Sum256([]byte(token))] = session{deviceID, expires}
	return true
}

func (m *memory) getSession(token string, now time.Time) (session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	hash := sha256.Sum256([]byte(token))
	s, ok := m.sessions[hash]
	if !ok || !now.Before(s.ExpiresAt) {
		delete(m.sessions, hash)
		return session{}, false
	}
	return s, true
}
