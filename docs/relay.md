# Encrypted Relay

The relay lets a paired device use the Mac sessions it's allowed to reach, and lets someone open one session from an invitation link without pairing. The server authenticates devices and routes traffic. Only the two devices can read terminal contents. Sessions keep running in the Mac's private tmux server whatever happens to the relay.

Contracts: [relay-v1](../protocol/relay-v1.md) for the relay, [local-agent-v1](../protocol/local-agent-v1.md) for the terminal messages carried inside it.

## Using it

On the Mac, **Open On ▸** in a terminal's context menu, File, or Terminal (Choose a Device…, ⌥⌘P; a paired device by name; New Device…; Someone Else…), or the toolbar's Open on another device button, walks through these steps one at a time and skips the ones already done:

1. **Server.** Start the local service and turn on **Allow Remote Access** through the continuation server. It is off by default.
2. **Device.** Choose a paired device (allowing it this session if it can't open it yet), pair a new one ([Device pairing](pairing.md)), or invite someone else's device to this session only.
3. **Approve.** For a new device, compare its code and choose what it can open: **only this session** (the default), **sessions you choose**, or **all sessions**, and whether it can type.
4. **Open.** On iOS the session opens as soon as pairing finishes; an already paired device finds it under Terminals → the Mac.

**What a device reaches.** This Mac keeps its own policy for each paired device (Settings → Devices, under each device):

| Setting | Effect |
|---|---|
| Terminals: All terminals | Every terminal except those kept private |
| Terminals: Terminals you choose | The listed terminals, plus any shared with every paired device (`witerm share`) |
| Can watch and type / Can only watch | Can only watch keeps the device watching here, even with a control grant |
| Type at the Same Time as This Mac | Off makes it wait until no one else is typing |

The policy can only narrow the signed grant: a view-only grant never gains control. Devices paired before this policy existed reach shared sessions only. When a session ends it leaves every device's list, so a later session never inherits that access. Narrowing a policy disconnects the attachments it no longer allows.

**Per session.** **Keep Private** (session context menu or the terminal's More menu) hides a session from every paired device, even ones that list it. Sharing a session ends keeping it private, and the reverse. **Stop Sharing** (or `witerm unshare`), shown for sessions shared with every paired device, disconnects only the devices that can no longer reach it. The Mac's terminal header shows which devices are attached and whether they can type.

**Typing together.** Several devices can type in one session at once: this Mac's app and `witerm` always can, and a paired device can when its policy allows it. The window takes the size of whoever typed last; the others see that grid (scrollable on iPhone) until they type. **Pause Remote Typing** in the Mac's terminal header (or `~p` in `witerm attach`) returns paired devices to view-only for that session until you allow it again; nobody takes over by force. A device whose policy doesn't allow typing alongside gets "Session Is Being Controlled" and can watch.

**Disconnects.** Control Center, the app switcher, and system prompts don't disconnect the phone. In the background it stays connected for 15 seconds, then detaches cleanly (releasing control at once) and keeps the last screen in memory. When the app returns, or after a network drop while it's open, it reconnects on its own: a fresh handshake, a fresh grant check, and a redraw from tmux. If someone else then controls a session the device can't type alongside, it reconnects view-only and says so. Earlier input is never resent. Leaving, revocation, and a session ending never reconnect. The app switcher shows a cover instead of terminal contents.

**Earlier output.** On attach, the Mac sends up to 1,000 lines (128 KiB) of the session's earlier output into the renderer's scrollback, above tmux's redraw of the live screen, so dragging scrolls back through it. Nothing is sent while a full-screen program (such as vim) is running. It travels inside the same encrypted channel and is never stored.

## Session invitations

A Mac can share one session with someone whose device isn't paired: **Open On ▸ Someone Else…**.

1. Choose **Can only watch** or **Can watch and type**, and how long access lasts (1, 8, or 24 hours). Access also ends when the terminal ends.
2. The Mac shows a QR code and a `witerm://share?…` link. Keep the sheet open until they join (within 5 minutes).
3. On iOS: **Add Device**, scan or paste. If the link names a server the phone doesn't have, it asks before adding it. The session opens once joined.
4. A watch-only invitation is approved as soon as someone joins. One that can type waits for you to approve that device's name and fingerprint.

**How it stays limited.** An invitation uses the normal pairing endpoints, so the Mac still signs the grant, but:

- The Mac records the invitation (session, permission, expiry) **before** anyone can join. That grant reaches nothing else, ever.
- The link carries a proof key that is never sent to the server. After approval, the phone proves inside the encrypted channel that it holds the key (an HMAC bound to the pairing and its own identity key). Until then the grant reaches nothing, so a server or anyone else who only saw the join secret gets nothing.
- The phone checks that the permission the Mac signed matches the link.
- Each invitation works once, for one device. The Mac closes its attachments at expiry and revokes the grant on the server; **End Access** does it at once.

Share the link only with the person you mean to invite: until it's used, anyone holding it can join.

## What a remote device can do

| Operation | Effect |
|---|---|
| `status` | Check the Mac service |
| `list` | List the sessions this device may reach, with what it may do in each |
| `attach` | Join a session to type or to watch, optionally with earlier output |
| `input` | Type (typing attachments only) |
| `resize` | Ask for the grid (typing attachments only) |
| `detach` | Leave; the session keeps running |
| `redeem` | Prove a session invitation's key (once, on an invitation's grant) |

That's the whole surface. Creating or ending sessions, file transfer, and clipboard sync stay on the Mac. Terminal clipboard escape sequences are blocked, and only links you tap explicitly (http/https) open.

## Security

**Channels.** The Mac keeps an authenticated WebSocket open to the server. iOS asks the server for a short-lived tunnel for one grant, and both devices connect to it. The server assigns each device's role from its authentication, never from what the client claims. Every list or attach uses a fresh tunnel.

**Handshake.** `Noise_XX_25519_ChaChaPoly_SHA256` with fresh keys for every connection.

- The handshake is bound to a context: server address, tunnel, grant, pairing, both device IDs and keys, and permission. Each side builds that context from its own verified grant, so the server can't substitute an identity or permission.
- After the handshake, each side signs the handshake hash with its paired Ed25519 identity, and both signatures must verify before any terminal operation.
- This provides forward secrecy and rejects replayed, reordered, reflected, or tampered records.

**Limits.**
- 65,536 bytes per WebSocket message and 256 KiB queued per leg on the server.
- 49,152 bytes of plaintext per encrypted record.
- If a limit is exceeded or something times out, the connection closes. Data is never dropped silently.

**Heavy output.** A phone is usually slower than the Mac producing output (`seq 1 1000000`, a build log), and the server closes a tunnel whose leg passes 16 messages or 256 KiB. So the phone acknowledges, inside the encrypted channel, the output its renderer has taken, and the Mac keeps at most 8 records and 128 KiB unacknowledged, merging output into records of up to 16 KiB while it waits. Beyond that the Mac stops reading that attachment from its service and tmux coalesces the screen, as it does for a slow window on the Mac. The phone stays attached and ends on the latest screen; lines tmux skipped stay in tmux's scrollback. A phone that takes nothing for 45 seconds is told `backpressure` and reconnects to a redraw. Older phones and older Macs work as before: neither side paces unless both do. Details: [relay-v1](../protocol/relay-v1.md#flow-control).

**What the server can see.** It forwards handshakes and records as opaque bytes, and never parses, stores, or logs them. It can still see:
- devices, their keys and names
- pairings and permissions
- tunnel routes and online status
- message sizes and timing

It can also refuse, delay, or cut connections. Tokens travel only in `Authorization` headers.

**Authorization.** The Mac enforces permissions itself; a server-assigned tunnel is not permission to control. Its relay endpoint tells the local service which paired device and grant each request is for, and the service applies this Mac's policy for that device, or the invitation that grant came from.

- Both devices recheck their local grant on every connection, signature, and request, and every 250 ms while idle.
- Revoking writes a local denial first, then tells the server. Live channels close even if the server is unreachable or still lists the grant.
- When the server itself sees a revocation, it closes both legs of the tunnel.
- Read-only grants can never send input or resize.

## Several servers

The Mac stores one Allow Remote Access entry per server, up to 8, in `relay-hosts.json`. The file holds only the address, device name, and on/off state, in a private 0700 directory with 0600 file permissions.

- The service keeps one listener per enabled server and allows 8 tunnels in total.
- Turning one server off or removing it stops only that server's connections. An invalid file stops all of them.

## TLS and deployment

The default Compose setup is for local development. It publishes only `127.0.0.1:37429` and sets `RELAY_ALLOW_LOOPBACK_DEVELOPMENT=true`, which allows plain HTTP and WebSocket for exact loopback hosts only. On a physical phone, `localhost` is the phone itself, so use a reachable HTTPS server with a trusted certificate.

Use [the public Docker configuration](deployment.md) for trusted HTTPS on TCP 37429. For a hosted server, mount the certificate read-only and set:

```text
HTTP_ADDR=:8443
TLS_CERT_FILE=/run/tls/fullchain.pem
TLS_KEY_FILE=/run/tls/privkey.pem
RELAY_ALLOW_LOOPBACK_DEVELOPMENT=false
```

**Proxies.** A reverse proxy must support WebSocket upgrades and long-lived connections, and must use either TLS passthrough or a certificate-verified HTTPS upstream. The server ignores headers like `X-Forwarded-Proto`, so terminating TLS at a proxy and forwarding plain HTTP is rejected.

**Also needed before going public:**
- random database credentials; database TLS if the database connection crosses hosts
- backups
- no public PostgreSQL port
- no logging of `Authorization` headers or WebSocket bodies

## Testing

```sh
make test test-integration test-agent
WITERM_RELAY_LIVE_SERVER_URL=http://localhost:37429 \
  swift test --package-path apps/mac-agent --filter RelayLiveTests
```

The live tests pair throwaway in-memory identities against the real server, using a private tmux server and temp directory. They never touch your Keychain or existing sessions. They check:

- real input and grid sizes
- view-only enforcement, even for raw encrypted requests that bypass the SDK
- unshared sessions staying invisible, and stopping sharing disconnecting a watching device
- immediate control handoff after detach
- reconnect redraws and an unchanged shell PID
- local revocation closing live tunnels while the server grant is still valid
- weak-network recovery without resending input

`RelayFlowTests` (mac-agent, no server needed) models the server's per-leg limits in process (16 messages plus the one being written, 256 KiB, a 5-second write timeout, close on overflow) with a phone link of about 2 MB/s and a renderer of 1.5 MB/s, and runs bursts through a real private tmux server, the bridge, and the encrypted channel.

For diagnostics, a DEBUG build with `WITERM_RELAY_TRACE=1` logs stage names and error categories only, never terminal bytes or keys.
