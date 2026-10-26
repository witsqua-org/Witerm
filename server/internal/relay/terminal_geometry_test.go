package relay

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

// This is a shared endpoint fixture contract, never a production relay decoder.
// The relay forwards opaque ciphertext and does not inspect terminal records.
func TestSharedTerminalGeometryFixture(t *testing.T) {
	bytes, err := os.ReadFile("../../../protocol/fixtures/terminal-geometry-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	type session struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		CreatedAt string `json:"created_at"`
		Columns   int    `json:"columns"`
		Rows      int    `json:"rows"`
	}
	var fixture struct {
		Initial session           `json:"initial_session"`
		Events  []json.RawMessage `json:"events"`
	}
	if err := json.Unmarshal(bytes, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Events) != 4 || !validID(fixture.Initial.ID) {
		t.Fatal("invalid geometry fixture")
	}
	for index, event := range fixture.Events {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(event, &fields); err != nil {
			t.Fatal(err)
		}
		var version int
		var kind string
		if json.Unmarshal(fields["version"], &version) != nil || version != 1 || json.Unmarshal(fields["kind"], &kind) != nil || len(fields) != 3 {
			t.Fatal("invalid terminal event envelope")
		}
		if index%2 == 0 {
			var next session
			if kind != "geometry" || json.Unmarshal(fields["session"], &next) != nil || next.ID != fixture.Initial.ID || next.Name != fixture.Initial.Name || next.CreatedAt != fixture.Initial.CreatedAt || next.Columns < 20 || next.Columns > 500 || next.Rows < 5 || next.Rows > 200 {
				t.Fatal("invalid authoritative geometry")
			}
		} else {
			var encoded string
			if kind != "output" || json.Unmarshal(fields["data"], &encoded) != nil {
				t.Fatal("output must follow geometry")
			}
			data, err := base64.StdEncoding.DecodeString(encoded)
			if err != nil || len(data) == 0 || len(data) > 8192 {
				t.Fatal("invalid terminal output fixture")
			}
		}
	}
}
