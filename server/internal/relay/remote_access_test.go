package relay

import (
	"encoding/json"
	"os"
	"testing"
)

// A shared endpoint fixture contract, never a production relay decoder: the
// relay forwards ciphertext and never sees which sessions a device may reach.
func TestSharedRemoteAccessFixture(t *testing.T) {
	bytes, err := os.ReadFile("../../../protocol/fixtures/remote-access-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		List struct {
			Kind     string `json:"kind"`
			Sessions []struct {
				ID      string           `json:"id"`
				Access  string           `json:"access"`
				Sharing *json.RawMessage `json:"sharing"`
			} `json:"sessions"`
		} `json:"peer_list_response"`
		Access struct {
			Operation string `json:"operation"`
			Access    struct {
				DeviceID   string `json:"device_id"`
				Scope      string `json:"scope"`
				Permission string `json:"permission"`
				CoTyping   *bool  `json:"co_typing"`
			} `json:"access"`
		} `json:"access_request"`
	}
	if err := json.Unmarshal(bytes, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.List.Kind != "response" || len(fixture.List.Sessions) != 2 {
		t.Fatal("invalid peer list fixture")
	}
	for _, session := range fixture.List.Sessions {
		// A paired device learns what it may do, never who else is attached.
		if !validID(session.ID) || (session.Access != "view" && session.Access != "control") || session.Sharing != nil {
			t.Fatal("invalid peer session access")
		}
	}
	access := fixture.Access.Access
	if fixture.Access.Operation != "access" || !validID(access.DeviceID) || (access.Scope != "all" && access.Scope != "shared") ||
		(access.Permission != "view" && access.Permission != "control") || access.CoTyping == nil {
		t.Fatal("invalid device access fixture")
	}
}
