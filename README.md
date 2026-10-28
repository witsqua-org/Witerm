# Witerm

An SSH client and Mac terminal continuity app for macOS, iPhone, and iPad.

- **Direct SSH** from Mac or iOS: host-key verification, jump hosts, SFTP, port forwarding. No server needed.
- **Mac terminals that outlive the app.** A background service keeps shells running in a private tmux server after you close the window or quit.
- **Continue on iPhone.** Paired devices view or type in the Mac sessions you allow, alongside the Mac, over an end-to-end encrypted relay. Share a single session with a link, without pairing. The server never sees terminal contents.
- **Command line.** `witerm new --share` starts a shared session in the current folder. The app and the command see the same sessions.

The apps follow the system language (English or Simplified Chinese) and light/dark appearance.

## Repository

| Path | What | Built with |
|---|---|---|
| `apps/apple/` | Mac and iOS apps | SwiftUI, SwiftTerm 1.19.0 |
| `apps/mac-agent/` | Mac background service and `witerm` command | Swift 6, tmux, real PTYs |
| `packages/WitermCore/` | Shared client library: pairing, relay crypto, local service client | Swift 6 |
| `packages/WitermSSH/` | SSH engine | Pinned Citadel source in `vendor/Citadel/` |
| `server/` | Pairing and relay server | Go 1.26, PostgreSQL |
| `protocol/` | Wire protocols and shared test fixtures | |

How the parts fit: [Architecture](docs/architecture.md).

## Quick start

### 1. Server (only for pairing and the relay)

Needs Docker with Compose.

```sh
cp .env.example .env
docker compose up --build -d --wait
curl --fail http://localhost:37429/v1/info
```

- It listens on `127.0.0.1:37429` only.
- The password in `.env.example` is for local development. Replace it before deploying anywhere.
- Data lives in the `postgres_data` volume; `docker compose down -v` deletes it.
- Public deployments use trusted HTTPS on TCP 37429: see [Docker deployment](docs/deployment.md).

### 2. Apps

Needs Xcode 27 (the apps still run on iOS 17 and macOS 14). Put your signing team in the ignored file `apps/apple/Config/Signing.local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_IDENTITY = Apple Development
```

Then build:

```sh
xcodebuild -project apps/apple/Witerm.xcodeproj -scheme WitermMac \
  -destination 'platform=macOS' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcodebuild -project apps/apple/Witerm.xcodeproj -scheme WitermiOS \
  -destination 'generic/platform=iOS Simulator' build
```

The Mac app needs `tmux` (`brew install tmux`). Keychain access needs a normally signed build with a provisioning profile; `CODE_SIGNING_ALLOWED=NO` only proves the code compiles.

### 3. Use

| To | Do |
|---|---|
| Connect over SSH | Mac: File → New SSH Connection (⇧⌘N). iOS: the + button in Terminals. Verify each host's fingerprint on first connect. |
| Open a Mac terminal | Start the local service from the main window, then create a session under **This Mac**. |
| Use the command line | Settings → Command Line → Install, then run `witerm new` in any folder. |
| Continue on iPhone | See below. |
| Share one session without pairing | Session context menu → **Share with a Link…**; on iOS, Machines → **Open Shared Session…** |

**Continue on iPhone:**

1. On the Mac, choose **File → Pair iPhone or iPad…** (⌥⌘P, or the button under **This Mac** in the sidebar). Its QR code appears at once. **Continue on iPhone…** in a session's header walks through the same setup as a checklist.
2. Use the same server on both devices and turn on remote access.
3. On iOS, choose **Continue from My Mac** (first use) and scan or paste the Mac's invitation. Check the fingerprint and send the request.
4. On the Mac, approve view-only or control access, and whether the device reaches all sessions or only those you share.

The Mac and the sessions it allows then appear in the iOS **Terminals** tab. The phone can type while the Mac stays attached. Each app can use up to 8 servers at once.

## Development

```sh
make test              # Go server, WitermCore, WitermSSH
make check             # go vet + gofmt
make test-integration  # PostgreSQL integration tests in Docker
make test-agent        # Mac service and witerm tests (needs tmux)
make test-local        # The above plus a real tmux smoke test
make test-ssh-live     # Real OpenSSH in disposable containers
make test-contrast     # Contrast of the authored color palettes
```

Live tests against a running server are opt-in. The server allows 30 sign-ins per minute per IP, so wait about a minute between full runs.

```sh
WITERM_TEST_SERVER_URL=http://localhost:37429 swift test --package-path packages/WitermCore
WITERM_RELAY_LIVE_SERVER_URL=http://localhost:37429 \
  swift test --package-path apps/mac-agent --filter RelayLiveTests
```

To run the server outside Docker, set `DATABASE_URL` yourself (Go doesn't read `.env`):

```sh
cd server
export DATABASE_URL='postgres://user:password@localhost:5432/witerm?sslmode=disable'
go run ./cmd/server -migrate-only
go run ./cmd/server
```

Never edit an applied migration; add a new numbered one. Contributor rules are in [AGENTS.md](AGENTS.md).

## Documentation

**Using Witerm**
- [Direct SSH](docs/ssh.md): host keys, jump hosts, SFTP, forwarding
- [Mac local terminal](docs/local-terminal.md): the background service, sessions, signing
- [Command line](docs/cli.md): `witerm`, sharing, scripting
- [Device pairing](docs/pairing.md): identities, invitations, grants
- [Encrypted relay](docs/relay.md): remote sessions, privacy, deployment
- [Terminal experience](docs/terminal-experience.md): grid size, display, accessibility, sleep
- [Language and appearance](docs/localization.md)

**Building Witerm**
- [Architecture](docs/architecture.md): components, trust model, status
- [Design guidelines](docs/design/README.md)
- [Verification status](docs/verification.md): what has been tested and what hasn't
- Protocols: [server HTTP](protocol/README.md), [pairing](protocol/pairing-v1.md), [relay](protocol/relay-v1.md), [local service](protocol/local-agent-v1.md)
