package relay

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"witerm/server/internal/pairing"
)

func TestParseWatchIsStrictAndBounded(t *testing.T) {
	id := "00000000-0000-4000-8000-000000000001"
	if ids, err := parseWatch([]byte(`{"type":"watch","grant_ids":["` + id + `"]}`)); err != nil || len(ids) != 1 {
		t.Fatal("valid watch rejected")
	}
	many := make([]string, maxPresenceGrants+1)
	for i := range many {
		many[i] = `"00000000-0000-4000-8000-0000000000` + string(rune('a'+i/10)) + string(rune('0'+i%10)) + `"`
	}
	for _, body := range []string{`{}`, `{"type":"watch"}`, `{"type":"watch","grant_ids":[]}`, `{"type":"other","grant_ids":["` + id + `"]}`,
		`{"type":"watch","grant_ids":["` + id + `","` + id + `"]}`, `{"type":"watch","grant_ids":["nope"]}`,
		`{"type":"watch","grant_ids":["` + id + `"],"extra":1}`, `{"type":"watch","grant_ids":[` + strings.Join(many, ",") + `]}`} {
		if _, err := parseWatch([]byte(body)); err == nil {
			t.Fatalf("accepted %s", body)
		}
	}
}

// The shared fixture: the watch request parses, invalid ones don't, and
// the server's messages encode exactly as the fixture's.
func TestPresenceFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/relay-presence-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Limits struct {
			MaxGrants  int `json:"max_grants"`
			MaxStreams int `json:"max_streams_per_device"`
		} `json:"limits"`
		Watch    json.RawMessage   `json:"watch"`
		Snapshot json.RawMessage   `json:"snapshot"`
		Update   json.RawMessage   `json:"update"`
		Invalid  []json.RawMessage `json:"invalid_watch"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Limits.MaxGrants != maxPresenceGrants || fixture.Limits.MaxStreams != maxPresencePerDevice {
		t.Fatal("limits differ from the fixture")
	}
	ids, err := parseWatch(fixture.Watch)
	if err != nil || len(ids) != 2 {
		t.Fatal("fixture watch rejected")
	}
	for _, bad := range fixture.Invalid {
		if _, err := parseWatch(bad); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
	for _, tc := range []struct {
		raw     json.RawMessage
		message presenceMessage
	}{
		{fixture.Snapshot, presenceMessage{Type: "presence", Hosts: []presenceEntry{{ids[0], true}, {ids[1], false}}}},
		{fixture.Update, presenceMessage{Type: "presence", Hosts: []presenceEntry{{ids[0], false}}}},
	} {
		ours, _ := json.Marshal(tc.message)
		var a, b any
		_ = json.Unmarshal(ours, &a)
		_ = json.Unmarshal(tc.raw, &b)
		if !reflect.DeepEqual(a, b) {
			t.Fatalf("message %s differs from the fixture %s", ours, tc.raw)
		}
	}
}

// A host connecting and dropping reaches the watchers of its grants at
// once, and only them; a replaced connection says nothing; a watcher that
// can't keep up is closed rather than blocking the router.
func TestPresenceFollowsHostConnections(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := &Service{hosts: map[string]*host{}, tunnels: map[string]*tunnel{}, watchers: map[*watcher]struct{}{}, ctx: ctx}
	wctx, wcancel := context.WithCancel(ctx)
	w := &watcher{hosts: map[string][]string{"mac": {"grant-a"}}, grants: map[string]bool{"grant-a": true},
		updates: make(chan presenceEntry, presenceBuffer), cancel: wcancel}
	other := &watcher{hosts: map[string][]string{"other-mac": {"grant-b"}}, grants: map[string]bool{"grant-b": true},
		updates: make(chan presenceEntry, presenceBuffer), cancel: func() {}}
	s.watchers[w] = struct{}{}
	s.watchers[other] = struct{}{}
	hctx, hcancel := context.WithCancel(ctx)
	h := &host{ctx: hctx, cancel: hcancel, identity: pairing.RelayIdentity{Device: pairing.Device{ID: "mac"}}}
	s.mu.Lock()
	s.hosts["mac"] = h
	s.notifyPresenceLocked("mac", true)
	s.dropHostLocked(h)
	s.mu.Unlock()
	if got := <-w.updates; got != (presenceEntry{GrantID: "grant-a", Online: true}) {
		t.Fatalf("online update %+v", got)
	}
	if got := <-w.updates; got != (presenceEntry{GrantID: "grant-a", Online: false}) {
		t.Fatalf("offline update %+v", got)
	}
	if len(other.updates) != 0 {
		t.Fatal("another Mac's watcher was told")
	}
	// A replaced connection from the same Mac is quiet.
	h2ctx, h2cancel := context.WithCancel(ctx)
	h2 := &host{ctx: h2ctx, cancel: h2cancel, identity: h.identity}
	s.mu.Lock()
	s.hosts["mac"] = h2
	s.dropHostQuietlyLocked(h2)
	s.mu.Unlock()
	if len(w.updates) != 0 {
		t.Fatal("a quiet drop told watchers")
	}
	// Revocation closes the watcher; so does overflowing it.
	s.mu.Lock()
	s.revokePresenceLocked("grant-a")
	s.mu.Unlock()
	if wctx.Err() == nil {
		t.Fatal("revocation kept the watcher")
	}
	full, fullCancel := context.WithCancel(ctx)
	slow := &watcher{hosts: map[string][]string{"mac": {"grant-c"}}, updates: make(chan presenceEntry), cancel: fullCancel}
	s.watchers = map[*watcher]struct{}{slow: {}}
	s.mu.Lock()
	s.notifyPresenceLocked("mac", true)
	s.mu.Unlock()
	if full.Err() == nil {
		t.Fatal("a watcher that can't keep up blocked instead of closing")
	}
}

// End to end against PostgreSQL: the phone watches its grant, sees its Mac
// online, then offline the moment the Mac's host connection closes; another
// device can't watch that grant.
func TestPresenceStreamIntegration(t *testing.T) {
	f := newFixture(t)
	hostConn := f.dial(t, "/v1/relay/host", f.host.token, 101)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, data, err := hostConn.Read(ctx); err != nil || string(data) != `{"type":"ready"}` {
		t.Fatal("host not ready")
	}
	watch := func(token string) *websocket.Conn {
		c := f.dial(t, "/v1/relay/presence", token, 101)
		if err := c.Write(ctx, websocket.MessageText, []byte(`{"type":"watch","grant_ids":["`+f.grant.ID+`"]}`)); err != nil {
			t.Fatal(err)
		}
		return c
	}
	next := func(c *websocket.Conn) presenceMessage {
		_, data, err := c.Read(ctx)
		if err != nil {
			t.Fatal("presence closed")
		}
		var m presenceMessage
		if json.Unmarshal(data, &m) != nil || m.Type != "presence" {
			t.Fatal("invalid presence message")
		}
		return m
	}
	phone := watch(f.client.token)
	defer phone.CloseNow()
	if m := next(phone); len(m.Hosts) != 1 || !m.Hosts[0].Online || m.Hosts[0].GrantID != f.grant.ID {
		t.Fatalf("snapshot %+v", m)
	}
	stranger := watch(f.other.token)
	defer stranger.CloseNow()
	if m := next(stranger); len(m.Hosts) != 0 {
		t.Fatal("another device saw the grant's Mac")
	}
	started := time.Now()
	_ = hostConn.Close(websocket.StatusNormalClosure, "")
	m := next(phone)
	if len(m.Hosts) != 1 || m.Hosts[0].Online {
		t.Fatalf("offline update %+v", m)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("offline took %v", elapsed)
	}
}
