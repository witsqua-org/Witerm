package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"witerm/server/internal/pairing"
	"witerm/server/internal/relay"
)

type fakeDatabase struct{ err error }

func (db fakeDatabase) Ping(context.Context) error { return db.err }

func TestReadinessAndLivenessDuringDatabaseFailure(t *testing.T) {
	for _, failed := range []bool{false, true} {
		var dbErr error
		if failed {
			dbErr = errors.New("private database connection details")
		}
		handler := New(fakeDatabase{dbErr})
		for _, path := range []string{"/healthz", "/readyz"} {
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
			want := http.StatusOK
			if failed && path == "/readyz" {
				want = http.StatusServiceUnavailable
			}
			if rr.Code != want || bytes.Contains(rr.Body.Bytes(), []byte("private")) {
				t.Fatalf("failed=%t path=%s: %d %s", failed, path, rr.Code, rr.Body)
			}
		}
	}
}

func TestInfoMatchesSharedContract(t *testing.T) {
	fixture, err := os.ReadFile("../../../protocol/fixtures/server-info.json")
	if err != nil {
		t.Fatal(err)
	}
	rr := httptest.NewRecorder()
	identities := pairing.New(nil)
	router := relay.New(identities)
	t.Cleanup(router.Close)
	New(fakeDatabase{}, identities, router).ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/info", nil))
	var want, got Info
	if err := json.Unmarshal(fixture, &want); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	wantJSON, _ := json.Marshal(want)
	gotJSON, _ := json.Marshal(got)
	if rr.Code != http.StatusOK || !bytes.Equal(wantJSON, gotJSON) {
		t.Fatalf("contract mismatch: %s != %s", gotJSON, wantJSON)
	}
}
