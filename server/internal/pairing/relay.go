package pairing

import (
	"context"
	"crypto/sha256"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// RelayIdentity contains no bearer token. Its session reference is process-local.
type RelayIdentity struct {
	Device    Device
	ExpiresAt time.Time
	hash      [32]byte
}

var (
	ErrRelayUnauthorized = errors.New("unauthorized")
	ErrRelayUnavailable  = errors.New("tunnel_unavailable")
	ErrRelayRateLimited  = errors.New("rate_limited")
)

// AuthenticateRelay reuses the pairing session and durable device identity.
func (s *Service) AuthenticateRelay(ctx context.Context, r *http.Request) (RelayIdentity, error) {
	values := r.Header.Values("Authorization")
	if len(values) != 1 || !strings.HasPrefix(values[0], "Bearer ") || len(values[0]) > 128 {
		return RelayIdentity{}, ErrRelayUnauthorized
	}
	token := strings.TrimPrefix(values[0], "Bearer ")
	sess, ok := s.memory.getSession(token, s.now())
	if !ok {
		return RelayIdentity{}, ErrRelayUnauthorized
	}
	d, err := deviceByID(ctx, s.pool, sess.DeviceID)
	if errors.Is(err, pgx.ErrNoRows) {
		return RelayIdentity{}, ErrRelayUnauthorized
	}
	if err != nil {
		return RelayIdentity{}, err
	}
	if !s.memory.allow("relay:"+d.ID, s.now()) {
		return RelayIdentity{}, ErrRelayRateLimited
	}
	return RelayIdentity{Device: d, ExpiresAt: sess.ExpiresAt, hash: sha256.Sum256([]byte(token))}, nil
}

// WithActiveRelayGrant serializes route admission with API revocation. The
// callback must not call back into pairing; it may only publish ephemeral state.
func (s *Service) WithActiveRelayGrant(ctx context.Context, id string, publish func(Grant) error) error {
	s.relayMu.Lock()
	defer s.relayMu.Unlock()
	if !validID(id) {
		return ErrRelayUnavailable
	}
	g, err := loadGrant(ctx, s.pool, `g.id=$1 AND g.revoked_at IS NULL`, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrRelayUnavailable
	}
	if err != nil {
		return err
	}
	return publish(g)
}

// SetRelayRevocationHook installs the single ephemeral router's close hook.
func (s *Service) SetRelayRevocationHook(hook func(string)) {
	s.relayMu.Lock()
	defer s.relayMu.Unlock()
	s.relayRevoked = hook
}

// CheckRelayState checks a bounded router snapshot in two database queries,
// rather than letting many independent timeouts delay revocation detection.
func (s *Service) CheckRelayState(ctx context.Context, identities []RelayIdentity, grantIDs []string) (map[string]bool, map[string]bool, error) {
	deviceIDs := make([]string, 0, len(identities))
	for _, identity := range identities {
		deviceIDs = append(deviceIDs, identity.Device.ID)
	}
	devices, grants := map[string]bool{}, map[string]bool{}
	rows, err := s.pool.Query(ctx, `SELECT id::text FROM devices WHERE id=ANY($1::uuid[]) AND revoked_at IS NULL`, deviceIDs)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, nil, err
		}
		devices[id] = true
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, nil, err
	}
	rows, err = s.pool.Query(ctx, `SELECT g.id::text FROM device_grants g JOIN devices h ON h.id=g.host_device_id JOIN devices c ON c.id=g.client_device_id WHERE g.id=ANY($1::uuid[]) AND g.revoked_at IS NULL AND h.revoked_at IS NULL AND c.revoked_at IS NULL AND g.pairing_id IS NOT NULL`, grantIDs)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, nil, err
		}
		grants[id] = true
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, nil, err
	}
	return devices, grants, nil
}

func (s *Service) RelaySessionActive(identity RelayIdentity) bool {
	s.memory.mu.Lock()
	defer s.memory.mu.Unlock()
	sess, ok := s.memory.sessions[identity.hash]
	return ok && sess.DeviceID == identity.Device.ID && s.now().Before(sess.ExpiresAt)
}
