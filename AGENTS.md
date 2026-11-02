# Witerm Development Agreements

## Structure

- `server/`: Go 1.26+, standard-library HTTP, pgx, and PostgreSQL.
- `apps/apple/`: shared SwiftUI sources with separate macOS/iOS targets; Mac embeds a user-level helper.
- `apps/mac-agent/`: Swift 6 local socket service, isolated tmux, and real PTYs.
- `packages/WitermCore/`: Swift 6 shared models and network clients.
- `protocol/`: protocol fixtures that Go and Swift must both follow.

## Verification

- Server changes: run `go test -race ./...` and `go vet ./...` in `server/`; preserve `gofmt` formatting.
- Database changes: run `make test-integration`. Never modify applied migrations.
- Shared model changes: run `swift test --package-path packages/WitermCore`. Protocol field changes must update Go, Swift, and `protocol/fixtures/` together.
- Independent SSH changes: run `swift test --package-path packages/WitermSSH -j 4`. Transport/SFTP/forwarding changes also require isolated OpenSSH acceptance with `python3 tools/ssh-fixture/run.py`. Never implicitly test against user SSH configuration, credentials, or existing hosts. Citadel provenance and patches are recorded in `vendor/Citadel/WITERM-PATCHES.md`.
- Local service changes: run `swift test --package-path apps/mac-agent` and real tmux acceptance using `tools/local-agent-smoke`. Clean only the isolated test sockets created by the tool.
- Apple UI changes: build affected platforms using the README commands.
- Terminal rendering/accessibility changes: run `WitermMacTerminalTests`, `WitermiOSTerminalTests`, and relevant VoiceOver UI tests. Mac XCTest retains Hardened Runtime; test-specific runpaths are documented in `docs/terminal-experience.md`. Use existing simulators only and disable parallel device cloning.
- Docker changes: run `docker compose config --quiet`, an actual build, and health checks. Do not print expanded configuration containing passwords.

## Boundaries

- PostgreSQL stores identities and grants. Keep online connections in process memory initially; do not introduce Redis prematurely.
- The relay forwards only end-to-end encrypted payloads. Never write SSH private keys, terminal input/output, or command history to cloud databases or logs.
- Direct SSH is independent of the server. Verify host keys at every hop; first trust requires explicit verification, and changed keys must block the connection. Credentials remain in memory or the local Keychain after an explicit choice. Never silently downgrade algorithms or fall back to file storage. Port forwarding listens on loopback only; disconnection never replays input.
- Do not advertise unimplemented API capabilities. Current capabilities are `device_identity_v1`, `device_pairing_v1`, and `encrypted_relay_v1`; these cover paired access to existing Witerm sessions, not independent SSH or remote session creation/termination.
- Identity keys are scoped to normalized server addresses. Mac Keychain runtime acceptance requires a signed build with a provisioning profile; do not weaken storage to bypass signing.
- The Mac background service runs as the user. Automatic adoption of existing processes in other terminal apps is not promised.
- UI language follows the system's preferred language, with English fallback and Simplified Chinese localization. App and terminal appearance follow the system; do not add an in-app light/dark override. Keep development status, protocol, and deployment details in documentation rather than product UI.
- Project documentation is written in English.
- Do not commit `.env`, build products, or local signing information.
- Native simulator Keychain acceptance requires a normally signed build. `CODE_SIGNING_ALLOWED=NO` proves compilation only; without a simulated application identity, Keychain access is denied.
- For simulator verification, reuse an existing iPhone 18 Pro simulator on the current Mac. The target device is changeable and machine-specific: choose it by UDID from `xcrun simctl list devices`, preferring one that is already booted and available. Never create devices or erase existing device data. If needed, shut down devices started by tests while retaining their data.
- Keep only one Witerm instance during Mac verification. Before changing build directories, quit the old instance by its exact process path; do not infer successful exit from a keyboard shortcut.
- The local service uses the registered `group.com.witerm.$(DEVELOPMENT_TEAM)` App Group, authorized by both parent/helper profiles, and an SMAppService LaunchAgent. Mac parent and helper follow the non-sandboxed Developer ID path while retaining signing and Hardened Runtime. iOS sandboxing is unchanged. Do not use root or take over other terminals. SwiftTerm is pinned to 1.19.0.

## Local Runtime Constraints

- The fixed development app is `.build/Applications/Witerm.app`; retain one GUI instance. Stop the service and quit the app before replacing a signed bundle. Copy fresh files and swap the whole bundle; never overwrite executables in place.
- The user explicitly selected the non-sandboxed Mac full-terminal path. Real SMAppService registration, persistence after GUI exit, automatic relaunch, and disable/re-enable recovery have passed. The earlier registration blocker no longer reproduces and must not be described as unresolved. See `docs/local-terminal.md`. Never globally reset BTM, edit private databases, or change another app's background permissions.
- System-service acceptance uses `RegisteredServiceProbe` in `tools/local-agent-smoke` and newly created test sessions only. Separately verify actual GUI exit, launchd PID/registration changes, and recovery of the same shell and child process. Probe phase labels alone do not prove lifecycle actions. Reading UI immediately after GUI exit can relaunch the app through automation; confirm exit with process inspection first.
- Initial read-only attach uses the actual dimensions in its response. Thereafter, apply `geometry` and VT output sequentially from the single `events` stream. Never simultaneously consume the compatibility `output` stream or let an observer resize the session.
- Font/viewport changes must not alter a read-only authoritative grid or call the vendor soft-reset path. Keep accessibility reading selection separate from IME input state. Public API/range unit tests do not replace real VoiceOver speech/navigation acceptance. Synthetic sleep notifications do not count as real system sleep. Current scope is in `docs/terminal-experience.md`; test evidence is summarized in `docs/verification.md`.
- iOS control handoff must wait for the `detach()` ACK before creating a new connection. Keep the noninteractive renderer until that ACK so output consumer cancellation cannot preempt release. Disconnected frames remain in memory only and are cleared after revocation. Never resend old input or silently seize control.
- Closing a native renderer cancels its input/output tasks. Current-connection error callbacks must validate active ID and generation; do not swallow disconnection/revocation because the callback task itself was cancelled. Asynchronous connection tasks must still check cancellation.
