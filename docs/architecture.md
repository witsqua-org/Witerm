# Architecture

## Two ways to reach a terminal

1. **Direct SSH.** The app connects straight to an SSH server. Witerm Server is not involved.
2. **Mac continuity.** A Mac runs shells in a background service. Other devices reach those shells through Witerm Server, which only relays encrypted bytes.

## Components

**Mac background service** (`apps/mac-agent`). Runs as the logged-in user, never as root. It serves a private Unix socket and hosts each session as a shell in its own tmux server, with an empty config and a private socket. Each viewer is a normal tmux client on a real PTY. New connections get a full tmux redraw, never a text snapshot.

- Closing a window only detaches. Ending a session is an explicit, confirmed action.
- The Mac app and the `witerm` command are clients of the same service, so sessions, sharing, and control are one state.
- The service can stop and restart without killing shells.
- Sleep, logout, and shutdown are different from a disconnect: tasks do not run during sleep, and shutdown does not restore processes.

**Apps** (`apps/apple`). SwiftUI for Mac and iOS. The Mac app is one client of the background service. Private keys and verified grants live only in the device Keychain. The apps never show sample devices or sessions.

**Server** (`server`). Go with PostgreSQL. It stores device identities, pairings, and grants, and relays encrypted terminal traffic.

- Online hosts and tunnels live in one process's memory. After a restart, clients reconnect.
- Redis is deferred until several server instances need shared routing. Even then, it will not carry terminal bytes.
- There are no accounts: devices register with their own keys.

## Trust model

- Each device has an Ed25519 identity per server address, so one server cannot replay another server's challenge.
- Pairing requires a Mac invitation, a fingerprint check on iOS, and explicit approval on the Mac (view-only or control).
- Terminal traffic is end-to-end encrypted with Noise XX and bound to both paired identities. The server routes ciphertext and cannot read or forge it.
- **The Mac is the final authority.** It rechecks its local grant on every connection and request, and while idle. A local revocation closes live channels even if the server still lists the grant.
- **Sessions are private until shared.** The Mac shows paired devices only shared sessions, and sharing never raises a device's access.
- One controller per session. Other devices must explicitly choose view-only, and nobody can take control by force.
- A full buffer closes the connection so the client can reattach and redraw. Terminal bytes are never silently dropped.

## Status

| Area | State |
|---|---|
| Server, PostgreSQL, Docker, diagnostics | Done |
| Device identity, pairing, revocation, rate limits | Done |
| Mac local sessions that survive app exit, service restart, and sleep | Done |
| Encrypted relay: view, control, handoff, revocation | Done |
| Per-session sharing and the `witerm` command | Done |
| Direct SSH: host keys, Ed25519 and password auth, jump hosts, SFTP, forwarding | Done |
| Remote session create or close, forced takeover, accounts | Not planned yet |
| tmux Control Mode, multi-window mapping, camera pairing, deep links | Future |

See [Verification status](verification.md) for what has been tested.

## Deployment notes

The app and PostgreSQL run in separate containers, and the database has no public port. Compose is for local development. A hosted deployment also needs:

- HTTPS ingress
- tested backups and restores
- key management
- resource limits

PostgreSQL 18 mounts its volume at `/var/lib/postgresql`.
