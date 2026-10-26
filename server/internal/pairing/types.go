package pairing

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"
)

type Device struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	PublicKey string `json:"public_key"`
}

type Grant struct {
	ID                string    `json:"id"`
	PairingID         string    `json:"pairing_id"`
	Host              Device    `json:"host"`
	Client            Device    `json:"client"`
	Permission        string    `json:"permission"`
	ApprovalSignature string    `json:"approval_signature"`
	CreatedAt         time.Time `json:"created_at"`
}

type Pairing struct {
	ID        string    `json:"id"`
	Status    string    `json:"status"`
	ExpiresAt time.Time `json:"expires_at"`
	Host      Device    `json:"host"`
	Client    *Device   `json:"client"`
	Grant     *Grant    `json:"grant"`
}

var (
	errUnauthorized = errors.New("unauthorized")
	errForbidden    = errors.New("forbidden")
	errUnavailable  = errors.New("pairing_unavailable")
	errConflict     = errors.New("conflict")
)

func registrationMessage(id, nonce, name, platform string) []byte {
	return []byte(strings.Join([]string{"witerm-device-v1", id, nonce, name, platform}, "\n"))
}

func approvalMessage(p Pairing, permission string) []byte {
	return []byte(strings.Join([]string{"witerm-pair-v1", p.ID, p.Host.PublicKey, p.Client.PublicKey, permission}, "\n"))
}

func decodePublicKey(value string) (ed25519.PublicKey, error) {
	key, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(key) != ed25519.PublicKeySize || base64.StdEncoding.EncodeToString(key) != value {
		return nil, errors.New("invalid public key")
	}
	return key, nil
}

func randomSecret() (string, error) {
	var data [32]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data[:]), nil
}

func randomID() (string, error) {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", err
	}
	data[6] = (data[6] & 0x0f) | 0x40
	data[8] = (data[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", data[0:4], data[4:6], data[6:8], data[8:10], data[10:16]), nil
}

func validID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, c := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func wholeSecond(t time.Time) time.Time { return t.UTC().Truncate(time.Second) }
