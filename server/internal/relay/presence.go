package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/coder/websocket"
	"witerm/server/internal/pairing"
)

// Presence (Round 18, not yet deployed): a client device watches whether
// the Macs it holds grants with are connected to this server, so its lists
// can say Offline the moment the server knows, instead of when a list or an
// attach next fails. It reveals nothing a client couldn't learn by opening a
// tunnel (host_offline), costs one socket instead of a tunnel per check, and
// carries no terminal data.
const (
	maxPresenceGrants    = 16
	maxPresencePerDevice = 2
	presenceBuffer       = 64
)

type watcher struct {
	identity pairing.RelayIdentity
	// Host device ID to the watched grants with it.
	hosts   map[string][]string
	grants  map[string]bool
	updates chan presenceEntry
	cancel  context.CancelFunc
}

type presenceEntry struct {
	GrantID string `json:"grant_id"`
	Online  bool   `json:"online"`
}

type presenceMessage struct {
	Type  string          `json:"type"`
	Hosts []presenceEntry `json:"hosts"`
}

type watchRequest struct {
	Type     string   `json:"type"`
	GrantIDs []string `json:"grant_ids"`
}

var errWatch = errors.New("invalid_request")

// parseWatch accepts exactly {"type":"watch","grant_ids":[...]} with at most
// 16 distinct canonical IDs.
func parseWatch(data []byte) ([]string, error) {
	var request watchRequest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil || decoder.More() || request.Type != "watch" {
		return nil, errWatch
	}
	if len(request.GrantIDs) == 0 || len(request.GrantIDs) > maxPresenceGrants {
		return nil, errWatch
	}
	seen := map[string]bool{}
	for _, id := range request.GrantIDs {
		if !validID(id) || seen[id] {
			return nil, errWatch
		}
		seen[id] = true
	}
	return request.GrantIDs, nil
}

// notifyPresenceLocked tells every watcher of hostID's grants. A watcher
// that can't keep up is closed; its client watches again and gets a snapshot.
func (s *Service) notifyPresenceLocked(hostID string, online bool) {
	for w := range s.watchers {
		for _, grant := range w.hosts[hostID] {
			select {
			case w.updates <- presenceEntry{GrantID: grant, Online: online}:
			default:
				w.cancel()
			}
		}
	}
}

// revokePresenceLocked closes watchers of a revoked grant: the client
// watches again with the grants it still holds.
func (s *Service) revokePresenceLocked(grantID string) {
	for w := range s.watchers {
		if w.grants[grantID] {
			w.cancel()
		}
	}
}

func (s *Service) presenceHandler(w http.ResponseWriter, r *http.Request) {
	identity, ok := s.authenticate(w, r, true, pairing.RelayOpen)
	if !ok {
		return
	}
	if identity.Device.Platform != "ios" {
		fail(w, 403, "forbidden")
		return
	}
	s.mu.Lock()
	count := 0
	for other := range s.watchers {
		if other.identity.Device.ID == identity.Device.ID {
			count++
		}
	}
	s.mu.Unlock()
	if count >= maxPresencePerDevice {
		failError(w, errLimited)
		return
	}
	if !s.acquire() {
		failError(w, errLimited)
		return
	}
	defer s.release()
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(4096)
	ctx, cancel := context.WithDeadline(s.ctx, identity.ExpiresAt)
	defer cancel()
	first, firstCancel := context.WithTimeout(ctx, ioTimeout)
	typ, data, err := read(first, c)
	firstCancel()
	if err != nil || typ != websocket.MessageText {
		return
	}
	ids, err := parseWatch(data)
	if err != nil {
		_ = c.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	watched := &watcher{identity: identity, hosts: map[string][]string{}, grants: map[string]bool{},
		updates: make(chan presenceEntry, presenceBuffer), cancel: cancel}
	for _, id := range ids {
		check, done := context.WithTimeout(ctx, ioTimeout)
		_ = s.pairing.WithActiveRelayGrant(check, id, func(g pairing.Grant) error {
			// Only the grant's own client may watch it.
			if g.Client.ID != identity.Device.ID {
				return errTunnel
			}
			watched.hosts[g.Host.ID] = append(watched.hosts[g.Host.ID], g.ID)
			watched.grants[g.ID] = true
			return nil
		})
		done()
	}
	s.mu.Lock()
	count = 0
	for other := range s.watchers {
		if other.identity.Device.ID == identity.Device.ID {
			count++
		}
	}
	if s.closed || count >= maxPresencePerDevice {
		s.mu.Unlock()
		return
	}
	snapshot := presenceMessage{Type: "presence", Hosts: []presenceEntry{}}
	for _, id := range ids {
		for hostID, grants := range watched.hosts {
			for _, grant := range grants {
				if grant == id {
					h := s.hosts[hostID]
					snapshot.Hosts = append(snapshot.Hosts, presenceEntry{GrantID: id, Online: h != nil && h.ctx.Err() == nil})
				}
			}
		}
	}
	s.watchers[watched] = struct{}{}
	s.mu.Unlock()
	defer func() { s.mu.Lock(); delete(s.watchers, watched); s.mu.Unlock() }()
	message, _ := json.Marshal(snapshot)
	if err := write(ctx, c, websocket.MessageText, message); err != nil {
		return
	}
	go heartbeat(ctx, c, cancel)
	go func() {
		defer cancel()
		// Nothing more is read: any message, or the client closing, ends it.
		_, _, _ = read(ctx, c)
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case update := <-watched.updates:
			data, _ := json.Marshal(presenceMessage{Type: "presence", Hosts: []presenceEntry{update}})
			if err := write(ctx, c, websocket.MessageText, data); err != nil {
				return
			}
		}
	}
}
