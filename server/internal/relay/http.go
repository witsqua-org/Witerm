package relay

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
)

func validUpgrade(r *http.Request) bool {
	hasToken := func(header, want string) bool {
		for _, value := range r.Header.Values(header) {
			for _, token := range strings.Split(value, ",") {
				if strings.EqualFold(strings.TrimSpace(token), want) {
					return true
				}
			}
		}
		return false
	}
	keys := r.Header.Values("Sec-WebSocket-Key")
	if !r.ProtoAtLeast(1, 1) || !hasToken("Connection", "upgrade") || !hasToken("Upgrade", "websocket") || r.Header.Get("Sec-WebSocket-Version") != "13" || len(keys) != 1 {
		return false
	}
	key, err := base64.StdEncoding.DecodeString(strings.TrimSpace(keys[0]))
	return err == nil && len(key) == 16
}
func decodeRequest(w http.ResponseWriter, r *http.Request, target any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	body, err := io.ReadAll(r.Body)
	body = bytes.TrimSpace(body)
	if err != nil || len(body) < 2 || body[0] != '{' {
		fail(w, 400, "invalid_request")
		return false
	}
	// encoding/json otherwise accepts duplicate keys by taking the last one.
	keys := json.NewDecoder(bytes.NewReader(body))
	_, err = keys.Token()
	seen := map[string]bool{}
	for err == nil && keys.More() {
		var token json.Token
		token, err = keys.Token()
		key, ok := token.(string)
		if !ok || seen[key] {
			fail(w, 400, "invalid_request")
			return false
		}
		seen[key] = true
		var value json.RawMessage
		if err == nil {
			err = keys.Decode(&value)
		}
	}
	if err != nil {
		fail(w, 400, "invalid_request")
		return false
	}
	d := json.NewDecoder(bytes.NewReader(body))
	d.DisallowUnknownFields()
	if d.Decode(target) != nil || d.Decode(new(any)) != io.EOF {
		fail(w, 400, "invalid_request")
		return false
	}
	return true
}
