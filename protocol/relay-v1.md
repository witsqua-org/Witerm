# Encrypted Relay v1

An iOS client lists and attaches to existing Mac sessions through the server. The server routes opaque WebSocket messages; it never decrypts, inspects, stores, or logs them. HTTPS/WSS is required, except for exact loopback hosts in development.

**Out of scope:**
- remote session create or close
- SSH and SFTP
- file transfer and clipboard sync
- forced takeover
- iOS background execution

## Server routes

**Host connection.** `GET /v1/relay/host` (WebSocket, Bearer, macOS only).
- One host connection per device; a new one replaces the old and closes its tunnels.
- Text control messages are at most 4 KiB.
- The server sends `{"type":"ready"}`, then offers: `{"type":"offer","tunnel_id","grant_id"}`. Up to 16 offers queue; overflow closes the connection.

**Create a tunnel.** `POST /v1/relay/tunnels` (Bearer, iOS) with `{"grant_id"}` returns 201 `{"tunnel_id"}`.
- Requires an active grant whose client is the caller and whose host is online.
- The tunnel expires after 30 seconds if unused.

**Join a tunnel.** `GET /v1/relay/tunnels/{id}` (WebSocket, Bearer).
- The role comes from the authenticated device and the grant, never from the caller. One connection per role.
- Binary messages only, at most 65,536 bytes each, forwarded unchanged.

**Limits.**
- 4 tunnels per device, 256 overall, 256 host connections.
- 256 KiB queued per leg; overflow closes the leg instead of dropping data.
- A route is used once. Expiry, disconnect, host replacement, or revocation consumes it.

**Lifetime and revocation.**
- Every socket closes when its token expires.
- Revoking a grant through the API closes both legs immediately.
- A once-per-second check closes sockets whose grant or device is gone, or when the database fails.
- The server pings every 15 seconds with a 5-second deadline.

**Errors.** The existing codes plus `host_offline` and `tunnel_unavailable`. Requests with an `Origin` header are rejected (native clients don't send one), and cookies are never used.

## Handshake

`Noise_XX_25519_ChaChaPoly_SHA256`, using CryptoKit primitives and checked against reference vectors (`fixtures/noise-xx-reference.json`).

- Every connection uses fresh static and ephemeral X25519 keys. These are session keys, not the paired identity.
- XX payloads are empty.

**Prologue.** These fields in order, each followed by LF:

```text
witerm-relay-v1
<normalized server URL>
<tunnel id>
<grant id>
<pairing id>
<host device id>
<host Ed25519 public key, Base64>
<client device id>
<client Ed25519 public key, Base64>
<view|control>
```

Each side builds the prologue from its own locally verified grant, never from server data.

**Identity proofs.** After Split, the client sends an encrypted proof; the host verifies it, then sends its own.

- A proof is `{"role":"client|host","signature":<Base64>}`.
- The signature is made with the device's paired Ed25519 key over `witerm-relay-identity-v1\n<role>\n` followed by the 32-byte handshake hash.
- No terminal operation happens until both proofs verify.
- A wrong key, role, hash, grant, or context closes the route.

**Transport.**
- Nonces use the standard Noise layout: 4 zero bytes, then a little-endian uint64. Associated data is empty.
- Plaintext records are at most 49,152 bytes.
- The handshake and proofs must finish within 10 seconds.
- AEAD, ordering, or nonce-exhaustion errors close the channel.

**Client networking.** Clients use ephemeral URLSessions with no cookies, credential storage, or redirects, and normal certificate validation.

## Terminal messages

Encrypted records carry the [local-agent-v1](local-agent-v1.md) JSON requests and frames.

**Operations.**
- Only `status`, `list`, `attach`, `input`, `resize`, and `detach` are accepted remotely.
- The Mac rejects input, resize, and control attaches for `view` grants, even if the server is malicious.
- The Mac's local service decides who controls a session.

**Tunnels.** Each list or attach uses its own tunnel, with fresh keys and a fresh local grant check.

**Detach.**
- The detach acknowledgement is sent only after the Mac has released control, so another device can take control immediately.
- `detach()` has a 5-second deadline and rejects new input while it waits.

**Trust while connected.** Both sides recheck their local grant every 250 ms, even when idle. The first revocation failure is kept as the reason.

**Liveness.** Clients ping every 5 seconds with a 3-second deadline. These are per-leg health checks; they don't guarantee every network failure is noticed within that time.

**Resizes.** `geometry` frames arrive in order inside the encrypted channel, each before the redraw at its size. The server never learns grid sizes.

**Reconnects** are explicit. Input is never resent automatically.

## Mac side

**Credentials.** The service in `WitermAgent.app` reads the existing identity through the app's Keychain access group; keys are never exported or migrated.

**Allow Remote Access.** Stored in `relay-hosts.json` (`RelayHostConfigurationStore`), with up to 8 entries of `{server_address, device_name, enabled}`, one per server.

- The service runs one listener per enabled server, with at most 8 tunnels in total.
- It reconnects with exponential backoff from 1 to 30 seconds, refreshing tokens on reconnect.
- Turning an entry off or changing it stops only that server's connections. An invalid file stops all of them.

Shared metadata examples are in `fixtures/relay-metadata-v1.json`.
