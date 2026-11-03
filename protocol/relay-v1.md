# Encrypted Relay v1

An iOS client lists and attaches to existing Mac sessions through the server. The server routes opaque WebSocket messages; it never decrypts, inspects, stores, or logs them. HTTPS/WSS is required, except for exact loopback hosts in development.

**Out of scope:**
- remote session create or close
- SSH and SFTP
- file transfer and clipboard sync
- forced takeover (devices type together instead; see [local-agent-v1](local-agent-v1.md))
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
- 4 tunnels per client device, 8 per Mac (it serves every device paired with it), 256 overall, 256 host connections.
- Per device and minute: 30 host connections and tunnel creations together, and separately 120 tunnel joins. Every list or attach from any client costs its Mac one join, so the Mac's joins have room for four clients at full rate.
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
- Only `status`, `list`, `attach` (with optional `history` and `flow`), `input` (with optional `automatic`), `resize`, `detach`, `redeem` (with `proof`), and, on a flow-controlled attachment, `ack` (with `consumed`) are accepted remotely.
- The Mac answers `list` and `attach` only for sessions its policy lets that device (or that invitation) reach, and each listed session carries `access`, limited to the grant. Others don't appear and attach as `not_found` (`sessionUnavailable` in the Swift client). Narrowing access closes the device's attachment the same way.
- A remote `status` reports only whether tmux is available, never the Mac's servers.
- The Mac rejects input, resize, and control attaches for `view` grants, even if the server is malicious.
- The Mac's local service decides who controls a session.

**Tunnels.** Each list, attach, or redeem uses its own tunnel, with fresh keys and a fresh local grant check.

**Session invitations.** A grant from a session invitation is an ordinary signed grant, but the Mac records the invitation first and the grant reaches nothing until `redeem` arrives on it with the proof described in [local-agent-v1](local-agent-v1.md#sharing). The proof key travels only in the link, never to the server. The client compares the signed permission with the link's before redeeming.

**Detach.**
- The detach acknowledgement is sent only after the Mac has released control, so another device can take control immediately.
- `detach()` has a 5-second deadline and rejects new input while it waits.

**Trust while connected.** Both sides recheck their local grant every 250 ms, even when idle. The first revocation failure is kept as the reason.

**Liveness.** Clients ping every 5 seconds with a 3-second deadline. These are per-leg health checks; they don't guarantee every network failure is noticed within that time.

**Resizes.** `geometry` frames arrive in order inside the encrypted channel, each before the redraw at its size. The server never learns grid sizes.

## Flow control

The server closes a tunnel when a leg's queue passes 16 messages or 256 KiB. It can't slow a sender down instead: coder/websocket handles pongs only while reading, and pings queue behind blocked writes, so not reading one side (or blocking on the other) would fail a heartbeat and close the tunnel anyway. So the two devices pace output between themselves, inside the encrypted channel, and the server stays a bounded forwarder of opaque records. Shared limits and examples: `fixtures/relay-flow-v1.json`.

**Negotiation.**
- A device that acknowledges output adds `"flow": 1` to `attach` (any integer from 1; the Mac speaks version 1).
- A Mac that paces output answers with `"flow": 1` in the attach response. The device acknowledges only then; a confirmation it didn't ask for, or of another version, fails closed.
- A device without `flow` gets the attachment as before: output frames of at most 8 KiB, sent as fast as the relay accepts them, and no `ack`.
- A Mac from before flow control refuses the unknown field with `invalid_request` before attaching anything. The device then attaches once more without `flow`, on a fresh tunnel, and remembers that Mac (by grant, in memory only, for 10 minutes). It never sends `ack` to it.

**Acknowledgements.** `{"version":1,"id":<uuid>,"operation":"ack","consumed":<n>}`, where `n` counts every terminal frame (`output` and `geometry`) after the attach response that the device has handed to its renderer, in total. Geometry an output-only consumer doesn't need counts as handed over. `consumed` never decreases and never exceeds what the Mac sent; anything else ends the attachment. An `ack` is never answered. Watching devices acknowledge too. The device sends one acknowledgement at a time, carrying whatever its renderer took meanwhile, and none once it has started to detach, so the detach request is its last request.

**The Mac's window.**
- At most 8 unacknowledged terminal frames, totalling at most 128 KiB of encrypted WebSocket messages (plaintext plus the 16-byte tag), are in flight to the device. That leaves the server's leg at least 8 messages and 128 KiB for replies.
- While it waits for room, the Mac merges consecutive output into one `output` frame of up to 16 KiB (8 KiB without flow control). Base64 and JSON, without escaped slashes, keep such a record under 22 KB: inside the 49,152-byte record and 65,536-byte message limits. Geometry is its own frame and keeps its place among the output bytes. Nothing is dropped, duplicated, or reordered.
- Once 64 KiB is waiting, the Mac stops taking that attachment's events from its local service, which stops reading the pane for it, so tmux coalesces the screen meanwhile (as for a slow window on the Mac). While an `input`, `resize`, or `detach` waits for the local service's reply (which comes behind output queued before it), the Mac keeps taking events, at most what that service had queued; past 4 MiB waiting the attachment ends.
- If the device acknowledges nothing for 45 seconds while output is unacknowledged, the Mac sends `closed` with `backpressure`; the session keeps running and a new attach redraws it.
- Once a `detach` arrives the Mac sends no more output: the device renders nothing after the reply, and its next attach redraws. The reply itself, like every response and `closed`, is outside the window. An `ack` that arrives while the Mac waits for the device to close after a reply is not taken as the close.
- Revocation checks (every 250 ms), detach acknowledgements, and never resending input work as without flow control.

**Reconnects** run a full handshake and grant check every time. The iOS client reconnects on its own after backgrounding (once its 15-second grace ends) and after a network drop while active, with backoff and at most four tries; never after leaving, revocation, or the session ending. Input is never resent.

## Mac side

**Credentials.** The service in `WitermAgent.app` reads the existing identity through the app's Keychain access group; keys are never exported or migrated.

**Allow Remote Access.** Stored in `relay-hosts.json` (`RelayHostConfigurationStore`), with up to 8 entries of `{server_address, device_name, enabled}`, one per server.

- The service runs one listener per enabled server, with at most 8 tunnels in total.
- It reconnects with exponential backoff from 1 to 30 seconds, refreshing tokens on reconnect.
- Turning an entry off or changing it stops only that server's connections. An invalid file stops all of them.

Shared metadata examples are in `fixtures/relay-metadata-v1.json`.
