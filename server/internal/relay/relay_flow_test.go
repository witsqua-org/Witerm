package relay

import (
	"encoding/json"
	"os"
	"testing"
)

// A shared endpoint fixture contract, never a production relay decoder: the
// relay forwards ciphertext and never sees flow control. It checks that the
// endpoints' window stays inside this server's per-leg queue.
func TestSharedRelayFlowFixture(t *testing.T) {
	bytes, err := os.ReadFile("../../../protocol/fixtures/relay-flow-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Limits struct {
			Version       int `json:"version"`
			WindowRecords int `json:"window_records"`
			WindowBytes   int `json:"window_bytes"`
			RecordData    int `json:"record_data_bytes"`
			LegacyData    int `json:"legacy_record_data_bytes"`
			StallSeconds  int `json:"stall_seconds"`
			LegMessages   int `json:"relay_leg_messages"`
			LegBytes      int `json:"relay_leg_bytes"`
		} `json:"limits"`
		Attach   map[string]json.RawMessage `json:"attach_request"`
		Response map[string]json.RawMessage `json:"attach_response"`
		Ack      map[string]json.RawMessage `json:"ack_request"`
		Refusal  map[string]json.RawMessage `json:"older_mac_refusal"`
	}
	if err := json.Unmarshal(bytes, &fixture); err != nil {
		t.Fatal(err)
	}
	limits := fixture.Limits
	if limits.Version != 1 || limits.LegMessages != cap(newBoundedQueue().messages) || limits.LegBytes != maxQueuedBytes {
		t.Fatal("the fixture must name this server's per-leg limits")
	}
	// Unacknowledged output leaves room in the queue for replies.
	if limits.WindowRecords*2 > limits.LegMessages || limits.WindowBytes*2 > limits.LegBytes || limits.StallSeconds <= 0 {
		t.Fatal("the flow window must stay well inside a relay leg")
	}
	// A full record, Base64'd in JSON and encrypted, fits one WebSocket message.
	if limits.RecordData <= limits.LegacyData || (limits.RecordData+2)/3*4+256 > 49152 || 49152+16 > maxMessage {
		t.Fatal("a coalesced record must fit the record and message limits")
	}
	var flow int
	var operation, id string
	if json.Unmarshal(fixture.Attach["flow"], &flow) != nil || flow != 1 ||
		json.Unmarshal(fixture.Attach["operation"], &operation) != nil || operation != "attach" ||
		json.Unmarshal(fixture.Attach["id"], &id) != nil || !validID(id) {
		t.Fatal("invalid flow attach")
	}
	var reply string
	if json.Unmarshal(fixture.Response["flow"], &flow) != nil || flow != 1 ||
		json.Unmarshal(fixture.Response["id"], &reply) != nil || reply != id {
		t.Fatal("the Mac confirms the version it enforces")
	}
	var consumed int
	if json.Unmarshal(fixture.Ack["operation"], &operation) != nil || operation != "ack" ||
		json.Unmarshal(fixture.Ack["consumed"], &consumed) != nil || consumed < 0 || len(fixture.Ack) != 4 {
		t.Fatal("invalid acknowledgement")
	}
	var code string
	if _, ok := fixture.Refusal["flow"]; ok || json.Unmarshal(fixture.Refusal["error"], &code) != nil || code != "invalid_request" {
		t.Fatal("an older Mac refuses the field without confirming it")
	}
}
