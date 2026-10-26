package relay

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/coder/websocket"
)

type relayFixture struct {
	Version        int               `json:"version"`
	Ready          map[string]string `json:"host_ready"`
	Offer          map[string]string `json:"host_offer"`
	CreateRequest  map[string]string `json:"create_request"`
	CreateResponse map[string]string `json:"create_response"`
}

func sharedRelayFixture(t *testing.T) relayFixture {
	t.Helper()
	data, err := os.ReadFile("../../../protocol/fixtures/relay-metadata-v1.json")
	if err != nil {
		t.Fatal("shared relay metadata fixture unavailable")
	}
	var fixture relayFixture
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != 1 {
		t.Fatal("shared relay metadata fixture invalid")
	}
	return fixture
}

func TestSharedRelayMetadata(t *testing.T) {
	f := sharedRelayFixture(t)
	if !reflect.DeepEqual(f.Ready, map[string]string{"type": "ready"}) {
		t.Fatal("ready contract changed")
	}
	var actual offer
	data, _ := json.Marshal(f.Offer)
	if json.Unmarshal(data, &actual) != nil || actual.Type != "offer" || !validID(actual.TunnelID) || !validID(actual.GrantID) {
		t.Fatal("offer contract changed")
	}
	encoded, _ := json.Marshal(actual)
	var roundtrip map[string]string
	_ = json.Unmarshal(encoded, &roundtrip)
	if !reflect.DeepEqual(roundtrip, f.Offer) {
		t.Fatal("Go offer wire differs from shared fixture")
	}
	requestData, _ := json.Marshal(f.CreateRequest)
	var request struct {
		GrantID string `json:"grant_id"`
	}
	if !decodeRequest(httptest.NewRecorder(), httptest.NewRequest("POST", "/", strings.NewReader(string(requestData))), &request) || request.GrantID != actual.GrantID {
		t.Fatal("create request contract changed")
	}
	if !reflect.DeepEqual(f.CreateResponse, map[string]string{"tunnel_id": actual.TunnelID}) {
		t.Fatal("create response contract changed")
	}
}

func TestRelayPostgresSharedMetadata(t *testing.T) {
	contract := sharedRelayFixture(t)
	f := newFixture(t)
	h := f.dial(t, "/v1/relay/host", f.host.token, 101)
	var ready map[string]string
	if json.Unmarshal(receive(t, h, websocket.MessageText), &ready) != nil || !reflect.DeepEqual(ready, contract.Ready) {
		t.Fatal("live ready differs from shared metadata")
	}
	request := map[string]string{}
	for key := range contract.CreateRequest {
		request[key] = f.grant.ID
	}
	var response map[string]string
	f.request(t, "POST", "/v1/relay/tunnels", f.client.token, request, 201, &response)
	if len(response) != len(contract.CreateResponse) || !validID(response["tunnel_id"]) {
		t.Fatal("live create response differs from shared metadata")
	}
	var actual map[string]string
	if json.Unmarshal(receive(t, h, websocket.MessageText), &actual) != nil {
		t.Fatal("live offer is malformed")
	}
	want := map[string]string{}
	for key, value := range contract.Offer {
		want[key] = value
	}
	want["tunnel_id"] = response["tunnel_id"]
	want["grant_id"] = f.grant.ID
	if !reflect.DeepEqual(actual, want) {
		t.Fatal("live offer differs from shared metadata")
	}
}
