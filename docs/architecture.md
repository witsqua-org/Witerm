# Architecture

Witerm reaches a terminal in one of two ways:

1. **Direct SSH.** The app connects straight to an SSH server. Witerm Server isn't involved.
2. **Mac continuity.** A Mac runs shells in a background service. Other devices reach them through Witerm Server, which only relays encrypted bytes.

## Components

**Mac background service** (`apps/mac-agent`)
- Runs as the logged-in user, never as root, and serves a private Unix socket.
- Hosts each session as a shell in Witerm's own tmux server (empty config, private socket).
- Each viewer is a normal tmux client on a real PTY, so a new connection gets a full redraw, never a text snapshot.
- The Mac app and the `witerm` command are both clients, so sessions, sharing, and control are one shared state.
- Closing a window only detaches. Ending a session is an explicit, confirmed action. The service can restart without killing shells.
- Sleep is not a disconnect: tasks pause during sleep. Shutdown doesn't restore processes.

**Apps** (`apps/apple`)
- SwiftUI for Mac and iOS. The Mac app is a client of the background service.
- Private keys and verified grants live only in the device Keychain.
- The apps never show sample devices or sessions.

**Server** (`server`)
- Go with PostgreSQL. Stores device identities, pairings, and grants, and relays encrypted terminal traffic.
- No accounts: devices register with their own keys.
- Online hosts and tunnels live in one process's memory; clients reconnect after a restart.
- Redis waits until several server instances need shared routing, and even then won't carry terminal bytes.

## Trust model

- **Per-server identities.** Each device has an Ed25519 identity per server address, so one server can't replay another's challenge.
- **Explicit pairing.** A Mac invitation, a fingerprint check on iOS, and approval on the Mac (view-only or control).
- **End-to-end encryption.** Noise XX, bound to both paired identities. The server routes ciphertext and can't read or forge it.
- **The Mac decides.** It rechecks its local grant on every connection and request, and while idle. A local revocation closes live channels even if the server still lists the grant.
- **Private until shared.** Paired devices see only shared sessions, and sharing never raises a device's access.
- **One controller per session.** Others must choose view-only; nobody takes control by force.
- **No silent loss.** A full buffer closes the connection so the client reattaches and redraws. Terminal bytes are never dropped quietly.

## Status

| Area | State |
|---|---|
| Server, PostgreSQL, Docker, diagnostics | Done |
| Device identity, pairing (QR or paste), revocation, rate limits | Done |
| Mac sessions that survive app exit, service restart, and sleep | Done |
| Encrypted relay: view, control, handoff, revocation | Done |
| Per-session sharing and the `witerm` command | Done |
| Direct SSH: host keys, Ed25519 and passwords, jump hosts, SFTP, forwarding | Done |
| Remote session create or close, forced takeover, accounts | Not planned yet |
| tmux control mode, multi-window mapping, deep links | Future |

What has actually been tested: [Verification status](verification.md).

## Deployment

The server and PostgreSQL run in separate containers, and the database has no public port. PostgreSQL 18 mounts its volume at `/var/lib/postgresql`. Compose is for local development; a hosted deployment also needs HTTPS ingress, tested backups and restores, key management, and resource limits. See [TLS and deployment](relay.md#tls-and-deployment).
