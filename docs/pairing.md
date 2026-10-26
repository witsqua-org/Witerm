# Device Pairing

Pairing lets an iPhone or iPad reach a Mac's sessions. It creates a signed, revocable **grant** between two device identities. A grant alone never opens a terminal: the Mac still checks its own records and runs an encrypted handshake first ([Encrypted relay](relay.md)).

The wire format is in [pairing-v1](../protocol/pairing-v1.md).

## How it works

1. **Mac** (Paired Devices → create invitation): makes a 5-minute invitation containing a one-time secret and the Mac's public key.
2. **iOS** (Settings → Device Pairing, or Pair a Device on the Devices tab): pastes the invitation. iOS checks that it names the current server, pins the Mac's key, and shows the Mac's fingerprint.
3. **iOS** sends the request. This creates a *pending* pairing and grants nothing.
4. **Mac** shows the phone's name and fingerprint. You choose view-only or control and approve. The Mac signs the approval, binding the pairing, both keys, and the permission.
5. Both devices verify the signature before storing the grant in the Keychain.

Either device can revoke a grant at any time.

## Trust boundaries

- **Private keys** never leave the device Keychain. Each server address gets its own key, so pairing through one server never authorizes another.
- **Challenges** are single-use, short-lived, and bound to a public key. The server stores only hashes of session tokens.
- **The server cannot swap in a different Mac key**, because iOS pinned it from the invitation.
- **Only the two participants** can list or revoke their grant.
- **Revocation is final.** The device records a local denial before telling the server, so neither an unreachable server nor a stale grant list can restore access. Reading a revoked pairing's status still works; it just carries no grant.
- **There are no accounts.** Devices self-register with their keys. The `users` table is only an ownership placeholder.

Not available yet: camera scanning, deep links, and cloud accounts.

## Testing

- Go and real-PostgreSQL tests: `make test-server`, `make test-integration`.
- Swift signature vectors and offline ledger tests: `make test-core`.
- A live two-device flow against a running server:

  ```sh
  WITERM_PAIRING_TEST_SERVER_URL=http://localhost:8080 swift test --package-path packages/WitermCore --filter PairingTests
  ```

`tools/pairing-smoke` is an independent black-box client written with only the Go standard library. It checks replay protection, pending-without-grant, signed approval, isolation from other devices, revocation, and concurrent claims. It never prints tokens or keys.

Run it against a separate Compose project so test identities stay out of your main database:

```sh
SERVER_PORT=18080 docker compose -p witerm-smoke up --build -d --wait
docker run --rm --network witerm-smoke_default \
  -v "$PWD/tools/pairing-smoke:/workspace:ro" -w /workspace \
  golang:1.26-alpine go run . http://server:8080
docker compose -p witerm-smoke down -v
```
