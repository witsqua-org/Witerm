package pairing

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type queryer interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func deviceByID(ctx context.Context, db queryer, id string) (Device, error) {
	var d Device
	var key []byte
	err := db.QueryRow(ctx, `SELECT id::text,name,platform,identity_public_key FROM devices WHERE id=$1 AND revoked_at IS NULL`, id).Scan(&d.ID, &d.Name, &d.Platform, &key)
	d.PublicKey = base64.StdEncoding.EncodeToString(key)
	return d, err
}

func registerDevice(ctx context.Context, pool *pgxpool.Pool, key []byte, name, platform string) (Device, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return Device{}, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, base64.StdEncoding.EncodeToString(key)); err != nil {
		return Device{}, err
	}
	var d Device
	var revoked *time.Time
	err = tx.QueryRow(ctx, `SELECT id::text,name,platform,revoked_at FROM devices WHERE identity_public_key=$1 FOR UPDATE`, key).Scan(&d.ID, &d.Name, &d.Platform, &revoked)
	if err == nil {
		if revoked != nil {
			return Device{}, errUnauthorized
		}
		if d.Platform != platform {
			return Device{}, errConflict
		}
	} else if errors.Is(err, pgx.ErrNoRows) {
		userID, err := randomID()
		if err != nil {
			return Device{}, err
		}
		deviceID, err := randomID()
		if err != nil {
			return Device{}, err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO users(id) VALUES($1)`, userID); err != nil {
			return Device{}, err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO devices(id,user_id,name,platform,identity_public_key) VALUES($1,$2,$3,$4,$5)`, deviceID, userID, name, platform, key); err != nil {
			return Device{}, err
		}
		d = Device{ID: deviceID, Name: name, Platform: platform}
	} else {
		return Device{}, err
	}
	d.PublicKey = base64.StdEncoding.EncodeToString(key)
	if err := tx.Commit(ctx); err != nil {
		return Device{}, err
	}
	return d, nil
}

// Lock the host before its pairing/grant rows, consistently across all mutations.
// This also serializes concurrent invitation creation and prevents revocation
// of a host device while its grant transaction is in progress.
func lockHost(ctx context.Context, tx pgx.Tx, id string) error {
	var platform string
	err := tx.QueryRow(ctx, `SELECT platform FROM devices WHERE id=$1 AND revoked_at IS NULL FOR UPDATE`, id).Scan(&platform)
	if errors.Is(err, pgx.ErrNoRows) {
		return errUnavailable
	}
	if err != nil {
		return err
	}
	if platform != "macos" {
		return errUnavailable
	}
	return nil
}

func loadPairing(ctx context.Context, db queryer, id string, lock bool, now time.Time) (Pairing, error) {
	var p Pairing
	var hostID string
	var clientID *string
	sql := `SELECT id::text,host_device_id::text,client_device_id::text,status,expires_at FROM pairing_requests WHERE id=$1`
	if lock {
		sql += ` FOR UPDATE`
	}
	err := db.QueryRow(ctx, sql, id).Scan(&p.ID, &hostID, &clientID, &p.Status, &p.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Pairing{}, errUnavailable
	}
	if err != nil {
		return Pairing{}, err
	}
	p.ExpiresAt = wholeSecond(p.ExpiresAt)
	p.Host, err = deviceByID(ctx, db, hostID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Pairing{}, errUnavailable
	}
	if err != nil {
		return Pairing{}, err
	}
	if clientID != nil {
		d, err := deviceByID(ctx, db, *clientID)
		if errors.Is(err, pgx.ErrNoRows) {
			return Pairing{}, errUnavailable
		}
		if err != nil {
			return Pairing{}, err
		}
		p.Client = &d
	}
	if (p.Status == "waiting" || p.Status == "pending") && !now.Before(p.ExpiresAt) {
		p.Status = "expired"
	}
	if p.Status == "approved" {
		g, err := loadGrant(ctx, db, `g.pairing_id=$1 AND g.revoked_at IS NULL`, id)
		if err == nil {
			p.Grant = &g
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return Pairing{}, err
		}
	}
	return p, nil
}

const grantSelect = `SELECT g.id::text,g.pairing_id::text,g.permission,g.approval_signature,g.created_at,
 h.id::text,h.name,h.platform,h.identity_public_key,c.id::text,c.name,c.platform,c.identity_public_key
 FROM device_grants g JOIN devices h ON h.id=g.host_device_id JOIN devices c ON c.id=g.client_device_id
 WHERE h.revoked_at IS NULL AND c.revoked_at IS NULL AND g.pairing_id IS NOT NULL AND `

func scanGrant(row pgx.Row) (Grant, error) {
	var g Grant
	var signature, hkey, ckey []byte
	err := row.Scan(&g.ID, &g.PairingID, &g.Permission, &signature, &g.CreatedAt, &g.Host.ID, &g.Host.Name, &g.Host.Platform, &hkey, &g.Client.ID, &g.Client.Name, &g.Client.Platform, &ckey)
	g.ApprovalSignature = base64.StdEncoding.EncodeToString(signature)
	g.Host.PublicKey = base64.StdEncoding.EncodeToString(hkey)
	g.Client.PublicKey = base64.StdEncoding.EncodeToString(ckey)
	g.CreatedAt = wholeSecond(g.CreatedAt)
	return g, err
}

func loadGrant(ctx context.Context, db queryer, where string, args ...any) (Grant, error) {
	return scanGrant(db.QueryRow(ctx, grantSelect+where, args...))
}

func (s *Service) create(ctx context.Context, host Device) (Pairing, string, error) {
	if host.Platform != "macos" {
		return Pairing{}, "", errForbidden
	}
	id, err := randomID()
	if err != nil {
		return Pairing{}, "", err
	}
	secret, err := randomSecret()
	if err != nil {
		return Pairing{}, "", err
	}
	raw, _ := base64.RawURLEncoding.DecodeString(secret)
	hash := sha256.Sum256(raw)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Pairing{}, "", err
	}
	defer tx.Rollback(ctx)
	if err := lockHost(ctx, tx, host.ID); err != nil {
		return Pairing{}, "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE pairing_requests SET status='rejected' WHERE host_device_id=$1 AND status IN ('waiting','pending')`, host.ID); err != nil {
		return Pairing{}, "", err
	}
	expires := wholeSecond(s.now()).Add(5 * time.Minute)
	if _, err := tx.Exec(ctx, `INSERT INTO pairing_requests(id,host_device_id,secret_hash,expires_at) VALUES($1,$2,$3,$4)`, id, host.ID, hash[:], expires); err != nil {
		return Pairing{}, "", err
	}
	p, err := loadPairing(ctx, tx, id, false, s.now())
	if err != nil {
		return Pairing{}, "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return Pairing{}, "", err
	}
	return p, secret, nil
}

func (s *Service) pairingTransaction(ctx context.Context, id string, mutate func(pgx.Tx, Pairing) error) (Pairing, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Pairing{}, err
	}
	defer tx.Rollback(ctx)
	var hostID string
	if err := tx.QueryRow(ctx, `SELECT host_device_id::text FROM pairing_requests WHERE id=$1`, id).Scan(&hostID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Pairing{}, errUnavailable
		}
		return Pairing{}, err
	}
	if err := lockHost(ctx, tx, hostID); err != nil {
		return Pairing{}, err
	}
	p, err := loadPairing(ctx, tx, id, true, s.now())
	if err != nil {
		return Pairing{}, err
	}
	if p.Client != nil {
		var active bool
		if err := tx.QueryRow(ctx, `SELECT revoked_at IS NULL FROM devices WHERE id=$1 FOR SHARE`, p.Client.ID).Scan(&active); err != nil {
			return Pairing{}, err
		}
		if !active {
			return Pairing{}, errUnavailable
		}
	}
	if err := mutate(tx, p); err != nil {
		return Pairing{}, err
	}
	p, err = loadPairing(ctx, tx, id, false, s.now())
	if err != nil {
		return Pairing{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Pairing{}, err
	}
	return p, nil
}

func (s *Service) join(ctx context.Context, id string, client Device, secret string) (Pairing, error) {
	if client.Platform != "ios" {
		return Pairing{}, errForbidden
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(secret)
	if err != nil || len(raw) != 32 || base64.RawURLEncoding.EncodeToString(raw) != secret {
		return Pairing{}, errUnavailable
	}
	hash := sha256.Sum256(raw)
	return s.pairingTransaction(ctx, id, func(tx pgx.Tx, p Pairing) error {
		var stored []byte
		if err := tx.QueryRow(ctx, `SELECT secret_hash FROM pairing_requests WHERE id=$1`, id).Scan(&stored); err != nil {
			return err
		}
		if subtle.ConstantTimeCompare(stored, hash[:]) != 1 || (p.Status != "waiting" && p.Status != "pending") {
			return errUnavailable
		}
		if p.Client != nil {
			if p.Client.ID == client.ID {
				return nil
			}
			return errUnavailable
		}
		var active bool
		if err := tx.QueryRow(ctx, `SELECT revoked_at IS NULL FROM devices WHERE id=$1 FOR SHARE`, client.ID).Scan(&active); err != nil {
			return err
		}
		if !active {
			return errUnavailable
		}
		_, err := tx.Exec(ctx, `UPDATE pairing_requests SET client_device_id=$2,status='pending' WHERE id=$1`, id, client.ID)
		return err
	})
}

func (s *Service) approve(ctx context.Context, id string, host Device, permission string, signature []byte) (Pairing, error) {
	if host.Platform != "macos" {
		return Pairing{}, errForbidden
	}
	return s.pairingTransaction(ctx, id, func(tx pgx.Tx, p Pairing) error {
		if p.Host.ID != host.ID {
			return errUnavailable
		}
		if p.Client == nil || (p.Status != "pending" && p.Status != "approved") {
			return errConflict
		}
		key, err := decodePublicKey(p.Host.PublicKey)
		if err != nil || !ed25519.Verify(key, approvalMessage(p, permission), signature) {
			return errForbidden
		}
		if p.Status == "approved" {
			g, err := loadGrant(ctx, tx, `g.pairing_id=$1`, id)
			if err != nil {
				return err
			}
			// Ed25519 verification accepts valid alternate nonce/signature
			// encodings produced by different implementations. Idempotency is
			// tied to the verified payload, never to signature byte equality.
			if g.Permission != permission {
				return errConflict
			}
			return nil
		}
		grantID, err := randomID()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO device_grants(id,host_device_id,client_device_id,permission,pairing_id,approval_signature) VALUES($1,$2,$3,$4,$5,$6)`, grantID, host.ID, p.Client.ID, permission, id, signature); err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				return errConflict
			}
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE pairing_requests SET status='approved',consumed_at=now() WHERE id=$1`, id)
		return err
	})
}

func (s *Service) reject(ctx context.Context, id string, actor Device) (Pairing, error) {
	return s.pairingTransaction(ctx, id, func(tx pgx.Tx, p Pairing) error {
		if p.Host.ID != actor.ID && (p.Client == nil || p.Client.ID != actor.ID) {
			return errUnavailable
		}
		if p.Status == "rejected" {
			return nil
		}
		if p.Status != "waiting" && p.Status != "pending" {
			return errConflict
		}
		_, err := tx.Exec(ctx, `UPDATE pairing_requests SET status='rejected' WHERE id=$1`, id)
		return err
	})
}

func (s *Service) grants(ctx context.Context, actor Device) ([]Grant, error) {
	rows, err := s.pool.Query(ctx, grantSelect+`g.revoked_at IS NULL AND (g.host_device_id=$1 OR g.client_device_id=$1) ORDER BY g.created_at,g.id`, actor.ID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	grants := []Grant{}
	for rows.Next() {
		g, err := scanGrant(rows)
		if err != nil {
			return nil, err
		}
		grants = append(grants, g)
	}
	return grants, rows.Err()
}

func (s *Service) revoke(ctx context.Context, id string, actor Device) error {
	s.relayMu.Lock()
	defer s.relayMu.Unlock()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var hostID, clientID string
	if err := tx.QueryRow(ctx, `SELECT host_device_id::text,client_device_id::text FROM device_grants WHERE id=$1 AND pairing_id IS NOT NULL`, id).Scan(&hostID, &clientID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return errUnavailable
		}
		return err
	}
	if actor.ID != hostID && actor.ID != clientID {
		return errUnavailable
	}
	// A still-active client may revoke its grant even if the host identity has
	// already been revoked. Use the same lock order without requiring an active host.
	var lockedHost string
	if err := tx.QueryRow(ctx, `SELECT id::text FROM devices WHERE id=$1 FOR UPDATE`, hostID).Scan(&lockedHost); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE device_grants SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1`, id); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	if s.relayRevoked != nil {
		s.relayRevoked(id)
	}
	return nil
}
