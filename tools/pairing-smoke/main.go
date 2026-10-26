// pairing-smoke is a black-box development check. Keys and session tokens live
// only in this process. It creates disposable identities; use an isolated DB.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type device struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	PublicKey string `json:"public_key"`
}

type grant struct {
	ID                string `json:"id"`
	PairingID         string `json:"pairing_id"`
	Host              device `json:"host"`
	Client            device `json:"client"`
	Permission        string `json:"permission"`
	ApprovalSignature string `json:"approval_signature"`
}

type pairing struct {
	ID     string  `json:"id"`
	Status string  `json:"status"`
	Host   device  `json:"host"`
	Client *device `json:"client"`
	Grant  *grant  `json:"grant"`
}

type identity struct {
	device
	key   ed25519.PrivateKey
	token string
}

type runner struct {
	base string
	http *http.Client
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: pairing-smoke <development-server-url>")
		os.Exit(2)
	}
	r := runner{base: strings.TrimRight(os.Args[1], "/"), http: &http.Client{Timeout: 10 * time.Second}}
	if err := r.run(); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
	fmt.Println("PASS: independent device proofs, explicit approval, access boundaries, revocation and competing claims")
}

// call never includes request/response contents in errors: those may contain
// invitation secrets or credentials, even when the server behaves incorrectly.
func (r runner) call(method, path, token string, body, result any) (int, error) {
	var input io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return 0, fmt.Errorf("encode request")
		}
		input = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, r.base+path, input)
	if err != nil {
		return 0, fmt.Errorf("construct request")
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := r.http.Do(req)
	if err != nil {
		return 0, fmt.Errorf("%s %s: transport failed", method, path)
	}
	defer response.Body.Close()
	if result != nil && response.StatusCode >= 200 && response.StatusCode < 300 {
		if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(result); err != nil {
			return response.StatusCode, fmt.Errorf("%s %s: invalid response", method, path)
		}
	}
	return response.StatusCode, nil
}

func expect(status, want int, err error, operation string) error {
	if err != nil {
		return err
	}
	if status != want {
		return fmt.Errorf("%s: expected HTTP %d, got %d", operation, want, status)
	}
	return nil
}

func denied(status int, err error, operation string) error {
	if err != nil {
		return err
	}
	if status < 400 || status >= 500 || status == http.StatusTooManyRequests {
		return fmt.Errorf("%s: expected access rejection, got %d", operation, status)
	}
	return nil
}

func (r runner) register(platform, name string) (identity, error) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return identity{}, fmt.Errorf("generate ephemeral test key")
	}
	i := identity{device: device{Name: name, Platform: platform, PublicKey: base64.StdEncoding.EncodeToString(public)}, key: private}
	var challenge struct {
		ID    string `json:"challenge_id"`
		Nonce string `json:"nonce"`
	}
	status, err := r.call("POST", "/v1/auth/challenges", "", map[string]string{"public_key": i.PublicKey}, &challenge)
	if err := expect(status, 201, err, "create challenge"); err != nil {
		return identity{}, err
	}
	message := strings.Join([]string{"witerm-device-v1", challenge.ID, challenge.Nonce, name, platform}, "\n")
	proof := map[string]string{"challenge_id": challenge.ID, "name": name, "platform": platform, "signature": base64.StdEncoding.EncodeToString(ed25519.Sign(private, []byte(message)))}
	var response struct {
		Device device `json:"device"`
		Token  string `json:"access_token"`
	}
	status, err = r.call("POST", "/v1/devices", "", proof, &response)
	if err := expect(status, 200, err, "register device"); err != nil {
		return identity{}, err
	}
	if response.Device.PublicKey != i.PublicKey || response.Device.Platform != platform || response.Token == "" || response.Device.ID == "" {
		return identity{}, fmt.Errorf("registration must bind the supplied device key and platform")
	}
	i.device, i.token = response.Device, response.Token
	status, err = r.call("POST", "/v1/devices", "", proof, nil)
	if err := denied(status, err, "challenge replay"); err != nil {
		return identity{}, err
	}
	return i, nil
}

func (r runner) create(host identity) (pairing, string, error) {
	var response struct {
		Pairing pairing `json:"pairing"`
		Secret  string  `json:"secret"`
	}
	status, err := r.call("POST", "/v1/pairings", host.token, struct{}{}, &response)
	if err := expect(status, 201, err, "create invitation"); err != nil {
		return pairing{}, "", err
	}
	if response.Pairing.Status != "waiting" || response.Pairing.Host.ID != host.ID || response.Secret == "" {
		return pairing{}, "", fmt.Errorf("new invitation must wait for an explicit client claim")
	}
	return response.Pairing, response.Secret, nil
}

func approval(host identity, client device, id, permission string) map[string]string {
	message := strings.Join([]string{"witerm-pair-v1", id, host.PublicKey, client.PublicKey, permission}, "\n")
	return map[string]string{"permission": permission, "approval_signature": base64.StdEncoding.EncodeToString(ed25519.Sign(host.key, []byte(message)))}
}

func (r runner) grantCount(i identity, want int) error {
	var result struct {
		Grants []grant `json:"grants"`
	}
	status, err := r.call("GET", "/v1/grants", i.token, nil, &result)
	if err := expect(status, 200, err, "list grants"); err != nil {
		return err
	}
	if len(result.Grants) != want {
		return fmt.Errorf("grant visibility: expected %d, got %d", want, len(result.Grants))
	}
	return nil
}

func (r runner) run() error {
	status, err := r.call("GET", "/v1/grants", "", nil, nil)
	if err := expect(status, 401, err, "unauthenticated list"); err != nil {
		return err
	}
	host, err := r.register("macos", "Smoke Mac")
	if err != nil {
		return err
	}
	client, err := r.register("ios", "Smoke iPhone")
	if err != nil {
		return err
	}
	outsider, err := r.register("ios", "Smoke Other iPhone")
	if err != nil {
		return err
	}
	otherHost, err := r.register("macos", "Smoke Other Mac")
	if err != nil {
		return err
	}
	fmt.Println("PASS: device identity and challenge replay rejection")
	p, secret, err := r.create(host)
	if err != nil {
		return err
	}
	path := "/v1/pairings/" + p.ID
	status, err = r.call("POST", path+"/join", outsider.token, map[string]string{"secret": "incorrect"}, nil)
	if err := expect(status, 404, err, "wrong invitation secret"); err != nil {
		return err
	}
	var pending pairing
	status, err = r.call("POST", path+"/join", client.token, map[string]string{"secret": secret}, &pending)
	if err := expect(status, 200, err, "join invitation"); err != nil {
		return err
	}
	if pending.Status != "pending" || pending.Grant != nil || pending.Client == nil || pending.Client.ID != client.ID {
		return fmt.Errorf("joining must bind one client without creating a grant")
	}
	if err := r.grantCount(client, 0); err != nil {
		return err
	}
	status, err = r.call("POST", path+"/join", client.token, map[string]string{"secret": secret}, nil)
	if err := expect(status, 200, err, "same-client join retry"); err != nil {
		return err
	}
	status, err = r.call("POST", path+"/join", outsider.token, map[string]string{"secret": secret}, nil)
	if err := expect(status, 404, err, "second-client claim"); err != nil {
		return err
	}
	status, err = r.call("GET", path, outsider.token, nil, nil)
	if err := expect(status, 404, err, "outsider pairing read"); err != nil {
		return err
	}
	status, err = r.call("POST", path+"/approve", otherHost.token, approval(otherHost, client.device, p.ID, "view"), nil)
	if err := denied(status, err, "another host approval"); err != nil {
		return err
	}
	badProof := approval(host, client.device, p.ID, "control")
	badProof["permission"] = "view"
	status, err = r.call("POST", path+"/approve", host.token, badProof, nil)
	if err := denied(status, err, "permission substitution"); err != nil {
		return err
	}
	var approved pairing
	proof := approval(host, client.device, p.ID, "view")
	status, err = r.call("POST", path+"/approve", host.token, proof, &approved)
	if err := expect(status, 200, err, "explicit host approval"); err != nil {
		return err
	}
	if approved.Status != "approved" || approved.Grant == nil || approved.Grant.Permission != "view" || approved.Grant.Host.PublicKey != host.PublicKey || approved.Grant.Client.PublicKey != client.PublicKey {
		return fmt.Errorf("approval must bind the original identities and chosen permission")
	}
	g := approved.Grant
	signature, err := base64.StdEncoding.DecodeString(g.ApprovalSignature)
	if err != nil {
		return fmt.Errorf("invalid grant proof encoding")
	}
	message := strings.Join([]string{"witerm-pair-v1", p.ID, host.PublicKey, client.PublicKey, "view"}, "\n")
	if !ed25519.Verify(host.key.Public().(ed25519.PublicKey), []byte(message), signature) {
		return fmt.Errorf("grant does not carry a verifiable host signature")
	}
	status, err = r.call("POST", path+"/approve", host.token, proof, &approved)
	if err := expect(status, 200, err, "approval retry"); err != nil {
		return err
	}
	if approved.Grant == nil || approved.Grant.ID != g.ID {
		return fmt.Errorf("approval retry created another grant")
	}
	for _, i := range []identity{host, client} {
		if err := r.grantCount(i, 1); err != nil {
			return err
		}
	}
	for _, i := range []identity{outsider, otherHost} {
		if err := r.grantCount(i, 0); err != nil {
			return err
		}
	}
	fmt.Println("PASS: pending approval, key-bound permission proof and participant-only visibility")
	status, err = r.call("DELETE", "/v1/grants/"+g.ID, outsider.token, nil, nil)
	if err := expect(status, 404, err, "outsider revocation"); err != nil {
		return err
	}
	for range 2 {
		status, err = r.call("DELETE", "/v1/grants/"+g.ID, client.token, nil, nil)
		if err := expect(status, 204, err, "participant revocation"); err != nil {
			return err
		}
	}
	for _, i := range []identity{host, client} {
		if err := r.grantCount(i, 0); err != nil {
			return err
		}
	}
	status, err = r.call("GET", path, client.token, nil, &approved)
	if err := expect(status, 200, err, "revoked pairing read"); err != nil {
		return err
	}
	if approved.Grant != nil {
		return fmt.Errorf("revoked grant must not be returned as active")
	}
	fmt.Println("PASS: idempotent revocation and no stale active grant")

	p, secret, err = r.create(host)
	if err != nil {
		return err
	}
	path = "/v1/pairings/" + p.ID
	var wg sync.WaitGroup
	results := make(chan int, 2)
	failures := make(chan error, 2)
	for _, i := range []identity{client, outsider} {
		wg.Add(1)
		go func(i identity) {
			defer wg.Done()
			status, err := r.call("POST", path+"/join", i.token, map[string]string{"secret": secret}, nil)
			if err != nil {
				failures <- err
			}
			results <- status
		}(i)
	}
	wg.Wait()
	close(results)
	close(failures)
	for err := range failures {
		return err
	}
	winners := 0
	for status := range results {
		if status == 200 {
			winners++
		} else if status != 404 {
			return fmt.Errorf("claim race returned unexpected status %d", status)
		}
	}
	if winners != 1 {
		return fmt.Errorf("claim race must have exactly one winner, got %d", winners)
	}
	status, err = r.call("POST", path+"/reject", host.token, struct{}{}, &pending)
	if err := expect(status, 200, err, "reject pending claim"); err != nil {
		return err
	}
	if pending.Status != "rejected" || pending.Grant != nil {
		return fmt.Errorf("rejection must close the invitation without authorizing a device")
	}
	status, err = r.call("POST", path+"/join", client.token, map[string]string{"secret": secret}, nil)
	if err := expect(status, 404, err, "reuse rejected invitation"); err != nil {
		return err
	}
	return nil
}
