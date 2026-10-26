# Encrypted Relay

The relay lets a paired iPhone or iPad use sessions that already exist on a Mac. The server authenticates devices and routes traffic. Only the two devices can read terminal contents. Sessions keep running in the Mac's private tmux server whatever happens to the relay.

Contracts: [relay-v1](../protocol/relay-v1.md) for the relay, [local-agent-v1](../protocol/local-agent-v1.md) for the terminal messages carried inside it.

## Using it

1. Pair the devices through the same server and approve view-only or control access ([Device pairing](pairing.md)).
2. On the Mac, start the local service, create a session, and turn on **Allow Remote Access** under Paired Devices. It is off by default.
3. On iOS, open the Devices tab, pick the Mac, then pick a session.

**Control.** Each session has one controller. If someone else has control, you can watch read-only, but you can't take over by force. **Release Control** switches you to read-only. **Take Control** asks for control once the other device has released it.

**Disconnects.** Backgrounding the app or losing the network keeps the last screen, read-only. Reconnecting is always manual and redraws from tmux. Earlier input is never resent. Revocation removes the screen and the reconnect button.

## What a remote device can do

| Operation | Effect |
|---|---|
| `status` | Check the Mac service |
| `list` | List existing sessions |
| `attach` | Join a session as controller or viewer |
| `input` | Type (controller only) |
| `resize` | Change the grid (controller only) |
| `detach` | Leave; the session keeps running |

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

**What the server can see.** It forwards handshakes and records as opaque bytes, and never parses, stores, or logs them. It can still see:
- devices, their keys and names
- pairings and permissions
- tunnel routes and online status
- message sizes and timing

It can also refuse, delay, or cut connections. Tokens travel only in `Authorization` headers.

**Authorization.** The Mac enforces permissions itself; a server-assigned tunnel is not permission to control.

- Both devices recheck their local grant on every connection, signature, and request, and every 250 ms while idle.
- Revoking writes a local denial first, then tells the server. Live channels close even if the server is unreachable or still lists the grant.
- When the server itself sees a revocation, it closes both legs of the tunnel.
- Read-only grants can never send input or resize.

## Several servers

The Mac stores one Allow Remote Access entry per server, up to 8, in `relay-hosts.json`. The file holds only the address, device name, and on/off state, in a private 0700 directory with 0600 file permissions.

- The service keeps one listener per enabled server and allows 8 tunnels in total.
- Turning one server off or removing it stops only that server's connections. An invalid file stops all of them.

## TLS and deployment

The default Compose setup is for local development. It publishes only `127.0.0.1:8080` and sets `RELAY_ALLOW_LOOPBACK_DEVELOPMENT=true`, which allows plain HTTP and WebSocket for exact loopback hosts only. On a physical phone, `localhost` is the phone itself, so use a reachable HTTPS server with a trusted certificate.

For a hosted server, mount the certificate read-only and set:

```text
HTTP_ADDR=:8443
TLS_CERT_FILE=/run/tls/fullchain.pem
TLS_KEY_FILE=/run/tls/privkey.pem
RELAY_ALLOW_LOOPBACK_DEVELOPMENT=false
```

**Proxies.** A reverse proxy must support WebSocket upgrades and long-lived connections, and must use either TLS passthrough or a certificate-verified HTTPS upstream. The server ignores headers like `X-Forwarded-Proto`, so terminating TLS at a proxy and forwarding plain HTTP is rejected.

**Also needed before going public:**
- random database credentials and database TLS
- backups
- no public PostgreSQL port
- no logging of `Authorization` headers or WebSocket bodies

## Testing

```sh
make test test-integration test-agent
WITERM_RELAY_LIVE_SERVER_URL=http://localhost:8080 \
  swift test --package-path apps/mac-agent --filter RelayLiveTests
```

The live tests pair throwaway in-memory identities against the real server, using a private tmux server and temp directory. They never touch your Keychain or existing sessions. They check:

- real input and grid sizes
- view-only enforcement, even for raw encrypted requests that bypass the SDK
- immediate control handoff after detach
- reconnect redraws and an unchanged shell PID
- local revocation closing live tunnels while the server grant is still valid
- weak-network recovery without resending input

For diagnostics, a DEBUG build with `WITERM_RELAY_TRACE=1` logs stage names and error categories only, never terminal bytes or keys.
