package relay

import (
	"encoding/json"
	"os"
	"testing"
)

// A shared endpoint fixture contract, never a production relay decoder: the
// relay forwards Orbit's exchanges as ciphertext like any other record. It
// checks that the endpoints' reply budget fits this server's message limit,
// and that the request carries no key.
func TestSharedRelayOrbitFixture(t *testing.T) {
	bytes, err := os.ReadFile("../../../protocol/fixtures/relay-orbit-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Limits struct {
			Version     int      `json:"version"`
			Record      int      `json:"record_bytes"`
			Budget      int      `json:"reply_budget_bytes"`
			Threads     int      `json:"thread_limit"`
			Operations  []string `json:"operations"`
			Never       []string `json:"never"`
			NeverFields []string `json:"never_fields"`
		} `json:"limits"`
		Request  map[string]json.RawMessage `json:"request"`
		Response map[string]json.RawMessage `json:"response"`
	}
	if err := json.Unmarshal(bytes, &fixture); err != nil {
		t.Fatal(err)
	}
	limits := fixture.Limits
	// A full record plus its 16-byte tag fits one WebSocket message, and a
	// reply leaves room inside the record for the frame around it.
	if limits.Version != 1 || limits.Record+16 > maxMessage || limits.Budget >= limits.Record || limits.Threads <= 0 {
		t.Fatal("an Orbit reply must fit one record and one relay message")
	}
	allowed := map[string]bool{}
	for _, operation := range limits.Operations {
		allowed[operation] = true
	}
	for _, operation := range limits.Never {
		if allowed[operation] {
			t.Fatalf("%s is both allowed and never sent", operation)
		}
	}
	var operation, id string
	if json.Unmarshal(fixture.Request["operation"], &operation) != nil || operation != "orbit" ||
		json.Unmarshal(fixture.Request["id"], &id) != nil || !validID(id) {
		t.Fatal("invalid orbit request")
	}
	var inner map[string]json.RawMessage
	if json.Unmarshal(fixture.Request["orbit"], &inner) != nil {
		t.Fatal("the request carries an Orbit request")
	}
	var innerOperation string
	if json.Unmarshal(inner["operation"], &innerOperation) != nil || !allowed[innerOperation] {
		t.Fatal("the Orbit request must be one a device may send")
	}
	for _, field := range limits.NeverFields {
		if _, present := inner[field]; present {
			t.Fatalf("an Orbit request from a device never carries %s", field)
		}
	}
	var reply string
	if json.Unmarshal(fixture.Response["id"], &reply) != nil || reply != id {
		t.Fatal("the reply answers the request")
	}
}
