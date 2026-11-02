# Device Pairing

Pairing lets another device reach a Mac's sessions. It creates a signed, revocable **grant** between two device identities. A grant alone never opens a terminal: the Mac still checks its own records and runs an encrypted handshake first ([Encrypted relay](relay.md)).

Wire format: [pairing-v1](../protocol/pairing-v1.md).

## How it works

1. **Mac** (Continue on Another Device… from a session's header, context menu or File menu, ⌥⌘P; or Settings → Devices → Pair a Device…) makes a 5-minute invitation with a one-time secret and the Mac's public key, shown as a QR code and as copyable text, through the continuation server chosen in Settings → Devices. The screen names that server.
2. **iOS** (Continue from Another Device, on first use or in Devices) scans or pastes it. The invitation names its server; a server the phone doesn't have is added only when the person taps Request Access. iOS pins the Mac's key and shows the Mac's code. Scanning only fills in the invitation; it never opens a link or joins on its own.
3. **iOS** sends the request. This creates a *pending* pairing and grants nothing. The phone shows its own code while it waits. It asks even when it's already paired with that Mac: a code means the Mac expects a request, and approving replaces the current access.
4. **Mac** shows the device's name and code. You choose whether it can type, and what it can open: only the session you started from (the default), sessions you choose, or all sessions on this Mac, and approve. The Mac signs the approval, binding the pairing, both keys, and the permission; the session choice is this Mac's own policy and can be changed later under Settings → Devices ([Encrypted relay](relay.md#using-it)).
5. **iOS** opens the terminal at once when the device can open exactly one; otherwise it lists them.
6. Both devices verify the signature before storing the grant in the Keychain.

Either device can revoke a grant at any time.

To let someone open one session without pairing, the Mac sends a session invitation instead. It uses the same endpoints, and the Mac limits that grant to the session and a time ([Session invitations](relay.md#session-invitations)).

## Trust boundaries

- **Private keys** never leave the device Keychain. Each server address gets its own key, so pairing through one server never authorizes another.
- **Challenges** are single-use, short-lived, and bound to a public key. The server stores only hashes of session tokens.
- **The server can't swap in another Mac key**, because iOS pinned it from the invitation.
- **Only the two participants** can list or revoke their grant.
- **Revocation is final.** A device records a local denial before telling the server, so neither an unreachable server nor a stale grant list can restore access. A revoked pairing can still be read; it just carries no grant.
- **No accounts.** Devices register with their keys. The `users` table only records ownership.

Not available yet: deep links and cloud accounts.

## Testing

- Go and real-PostgreSQL tests: `make test-server`, `make test-integration`.
- Swift signature vectors and offline ledger tests: `make test-core`.
- A live two-device flow against a running server:

  ```sh
  WITERM_PAIRING_TEST_SERVER_URL=http://localhost:37429 swift test --package-path packages/WitermCore --filter PairingTests
  ```

`tools/pairing-smoke` is an independent black-box client using only Go's standard library. It checks replay protection, pending-without-grant, signed approval, isolation from other devices, revocation, and concurrent claims, and never prints tokens or keys. Run it against a separate Compose project so test identities stay out of your main database:

```sh
SERVER_PORT=18080 docker compose -p witerm-smoke up --build -d --wait
docker run --rm --network witerm-smoke_default \
  -v "$PWD/tools/pairing-smoke:/workspace:ro" -w /workspace \
  golang:1.26-alpine go run . http://server:8080
docker compose -p witerm-smoke down -v
```
