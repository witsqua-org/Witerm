# Witerm

Witerm is an SSH client and Mac terminal continuity app for macOS, iPhone, and iPad.

- **Direct SSH** from Mac or iOS, with host-key verification, jump hosts, SFTP, and port forwarding. No server needed.
- **Mac terminals that outlive the app.** A background service keeps shells running in a private tmux server after the window or app closes.
- **Continue on iPhone.** Paired iOS devices view or control the Mac sessions you share, through an end-to-end encrypted relay. The relay server never sees terminal contents.
- **Command line.** `witerm new --share` starts a shared session in the current folder; the app and the command use the same sessions.

The apps follow the system language (English, Simplified Chinese) and light/dark appearance.

## How it fits together

| Part | Path | Built with |
|---|---|---|
| Mac and iOS apps | `apps/apple/` | SwiftUI, SwiftTerm 1.19.0 |
| Mac background service and `witerm` command | `apps/mac-agent/` | Swift 6, tmux, real PTYs |
| Shared client library | `packages/WitermCore/` | Pairing, relay crypto, local service client |
| SSH engine | `packages/WitermSSH/` | Pinned Citadel source in `vendor/Citadel/` |
| Pairing and relay server | `server/` | Go 1.26, PostgreSQL |
| Wire protocols and fixtures | `protocol/` | Shared by Go and Swift tests |

More detail: [Architecture](docs/architecture.md).

## Quick start

### 1. Run the server (only needed for pairing and relay)

Requires Docker with Compose.

```sh
cp .env.example .env
docker compose up --build -d --wait
curl --fail http://localhost:8080/v1/info
```

The server listens on `127.0.0.1:8080` only. The password in `.env.example` is for local development; replace it before deploying anywhere. Data lives in the `postgres_data` volume, and `docker compose down -v` deletes it. Public deployments need trusted HTTPS; see [TLS and deployment](docs/relay.md#tls-and-deployment).

### 2. Build the apps

Open `apps/apple/Witerm.xcodeproj` in Xcode 27 (iOS 17 and macOS 14 are still supported).

First, put your signing team in the ignored file `apps/apple/Config/Signing.local.xcconfig`:

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

The Mac app needs `tmux` (`brew install tmux`) and a normally signed build with a provisioning profile, because Keychain access depends on it. `CODE_SIGNING_ALLOWED=NO` only proves the code compiles.

### 3. Use it

- **SSH**: on the Mac, use File → New SSH Connection (⇧⌘N); on iOS, use the SSH tab. Verify each host's fingerprint on first connect.
- **Mac terminal**: start the local service from the main window, then create a session under This Mac.
- **Continue on iPhone**:
  1. On the Mac, open a session and choose **Continue on iPhone…** in its header or context menu.
  2. Follow its preparation checks: use the same server on both devices, pair a device, allow remote access, and share this session.
  3. On iOS, choose **Continue from My Mac** on first use. Scan or paste the Mac's invitation, check the fingerprint, and send the request.
  4. On the Mac, approve view-only or control access. The preparation sheet shows when the session is ready.
  5. For typing on iOS, release the Mac's control using the preparation sheet. Sessions can also be shared with `witerm share`.

  The Mac and its shared sessions now appear in the iOS Devices tab.
- **Command line**: Settings → Command Line → Install, then run `witerm new` in any folder.

Each app can use up to 8 servers at once. Guides: [Direct SSH](docs/ssh.md), [Mac local terminal](docs/local-terminal.md), [Command line](docs/cli.md), [Device pairing](docs/pairing.md), [Encrypted relay](docs/relay.md).

## Development

```sh
make test              # Go server, WitermCore, WitermSSH
make check             # go vet + gofmt
make test-integration  # PostgreSQL integration tests in Docker
make test-agent        # Mac service tests (needs tmux)
make test-local        # Plus a real tmux smoke test
make test-ssh-live     # Real OpenSSH in disposable containers
make test-contrast     # Color contrast of authored palettes
```

Live tests against a running server are opt-in:

```sh
WITERM_TEST_SERVER_URL=http://localhost:8080 swift test --package-path packages/WitermCore
WITERM_RELAY_LIVE_SERVER_URL=http://localhost:8080 \
  swift test --package-path apps/mac-agent --filter RelayLiveTests
```

The server rate-limits sign-ins to 30 per minute per IP. Wait about a minute between full live suites.

To run the server outside Docker, set `DATABASE_URL` yourself (Go does not read `.env`):

```sh
cd server
export DATABASE_URL='postgres://user:password@localhost:5432/witerm?sslmode=disable'
go run ./cmd/server -migrate-only
go run ./cmd/server
```

Never edit an applied migration; add a new numbered one. Contributor rules are in [AGENTS.md](AGENTS.md).

## Documentation

- [Architecture](docs/architecture.md): components, trust model, and status
- [Direct SSH](docs/ssh.md): host keys, jump hosts, SFTP, and forwarding
- [Mac local terminal](docs/local-terminal.md): background service, sessions, and signing
- [Command line](docs/cli.md): `witerm`, sharing, and scripting
- [Device pairing](docs/pairing.md): identities, invitations, and grants
- [Encrypted relay](docs/relay.md): remote sessions, privacy, and deployment
- [Terminal experience](docs/terminal-experience.md): grid sizing, accessibility, sleep, and native tests
- [Language and appearance](docs/localization.md)
- [Design guidelines](docs/design/README.md)
- [Verification status](docs/verification.md): what has been tested and what hasn't
- Protocols: [server HTTP](protocol/README.md), [pairing](protocol/pairing-v1.md), [relay](protocol/relay-v1.md), [local service](protocol/local-agent-v1.md)
