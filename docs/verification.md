# Verification Status

What has been tested, and what hasn't. Commands are in each guide and the [README](../README.md#development).

## Verified

On a development Mac with Xcode 27, existing iPhone 18 Pro and iPad Pro 13-inch simulators (iOS 27), and the local Docker server.

**Server and protocols**
- **Server.** Go tests with the race detector, `go vet`, gofmt, and real-PostgreSQL integration tests: authorization, pairing races, tunnel and revocation races, unchanged ciphertext forwarding, token expiry, limits, and database failure.
- **Pairing.** Shared Go/Swift signature vectors, the black-box `pairing-smoke` client, and a live two-device flow including revocation.
- **Relay crypto.** Noise reference vectors, context binding, and identity proofs. Tampering, replay, reordering, and reflection are rejected. Also: cancellation, timeouts, backpressure, and local revocation despite a stale server grant.
- **Live relay against the real server.** Listing, control and view, handoff right after detach, local revocation, weak networks, and one Mac serving two servers.

**Mac service and command line**
- **Service with real tmux.** Input, `stty size`, exclusive control, read-only limits, alternate-screen redraw, reconnect, and service restart. Resizes are confirmed against the shell's real size, even when tmux delays or drops a pane resize. Start folders with tmux format characters (`#{…}`, `#(…)`, `#[`) are used literally.
- **Sharing.** Unshared sessions stay invisible and can't be attached remotely, even with a valid grant. Stopping sharing disconnects paired devices but keeps the shell and local viewers. Sharing survives a service restart, and a remote `status` doesn't reveal the Mac's servers.
- **`witerm`.** The real binary against a private broker: exit codes, JSON output, and remote access never reported ready while off. On real pseudo-terminals: typing, resizing, `~.` detach, the last frame before shell exit, control release, and terminal restoration. With stdout or stderr blocked and never read, it still exits normally with the right code for help, termination, and service failure; termination right after startup is repeated 20 times. A Bash job-control probe checked suspend and resume. The same cases pass against the installed signed command, which reached the installed service's socket with no entitlements or permission prompt.
- **Installed service persistence.** The same shell, shell variables, and child process survived quitting the app, a launchd restart, turning the service off and on, replacing the whole app bundle, and real system sleep.

**Apps**
- **Signed Mac app.** Settings turned the service off and on with test sessions surviving. Settings → Command Line installed and removed the link; the empty-state hint opens that tab. Sessions started with `witerm` appeared on their own. Share and Stop Sharing worked from the header and context menu. The session checklist for Continue on iPhone shared and unshared a fresh session and never reported ready while remote access was off.
- **Native flows** on the signed Mac app and the simulator: pairing and approval, remote typing at the real grid size, read-only viewing, control release and acquire, server outage and recovery, idle revocation that clears the screen, and pairing through two servers.
- **iPhone and iPad.** First-use task choice, large text, address validation and recovery, invitation/server mismatch, scanner-unavailable fallback, invitation review across background and foreground, saving hosts without connecting, edit with Save, field-level errors, favorites, and search. iPad passed the configuration cases in landscape, including the split workspace.
- **Direct SSH** against disposable OpenSSH containers: keys, passwords, jump hosts, SFTP limits and no-overwrite rules, about 2 MiB each way through L and R forwards, rejection of unknown or changed host keys, and specific errors for a rejected password and a jump target that refuses. Unit tests cover a refused loopback port, error classification, generated Ed25519 keys read back by `ssh-keygen`, RSA key recognition, and OpenSSH config import (first-value-wins, patterns, negation, ProxyJump chains). UI tests on both apps, including two hosts at once, and an iPhone flow covering host-key trust, typing, SFTP, background disconnect, and explicit reconnect.
- **Terminal tests.** `WitermMacTerminalTests` (13) and `WitermiOSTerminalTests` (19): text ranges, mobile control keys, symbol and navigation keys in both cursor modes, the saved key-row order, 44 pt keys, confirmed bracketed paste, pending paste rejected after disconnect or in view-only mode, color-scheme contrast and repaint without touching contents, and snippet input (bracketing, Return only for single lines, review for multiline, ignored when view-only).
- **Round 4 HCI changes (simulator).** Address parsing unit tests (user, host, port, IPv6, `ssh://`, and each error). iPhone UI tests: the one-field host form with More Options, field errors before connecting, key generation, search and filters hidden with few hosts, the first-use choice, and the Settings index (one row per server, server pages for checking, pairing, editing, and removing, including two servers at once and a cancelled slow check). The Mac UI tests were updated for the new form and compile, but haven't been run.
- **Session rename.** Agent tests against real tmux: the new name reaches paired devices, survives a service restart, and rejects control characters and unknown sessions; the relay rejects `rename`. The `LocalAgentSmoke` run renames an attached session and confirms the same shell PID. `witerm rename` is covered by the CLI integration test.
- **Round 2 HCI changes (simulator).** iPhone UI tests: deleting a host shows the Undo bar, and generating a key shows its public key without saving or connecting. The Mac SSH flow test now undoes a deletion and checks the host returns; it needs the signed app and the SSH fixture and hasn't been rerun yet.
- **Accessibility and language.** Real VoiceOver speech and navigation on Mac and iOS (three cases each, including large text, narrow viewports, enhanced contrast, and the alternate screen), contrast checks, and English, Chinese, and fallback launches.

## Not yet verified

- Physical iPhones and iPads: camera scanning and permission recovery, haptics (including the bell), VoiceOver pacing, iPad multitasking, hardware keyboards and the ⌘ shortcut list, one-handed use, final glass appearance.
- The offline banner against real Wi-Fi loss, the Mac bell and Dock bounce, terminal switching shortcuts in the running Mac app, and importing a real `~/.ssh/config`.
- In the running apps: the Mac find bar and Insert Snippet against the focused terminal, rename from the sidebar, the iOS find bar and Snippets key, and color schemes on screen. Their logic is unit-tested; the menus and responder-chain routing have not been driven by UI tests.
- A new end-to-end phone handoff on real networks with the redesigned flow.
- Public HTTPS/WSS deployments across real networks.
- Production Developer ID signing, notarization, and release.
- Session continuity across logout, restart, or shutdown (not promised).
- Braille displays and every VoiceOver gesture.
- Several server instances behind one address.

## Testing caveats

- **Rate limits.** The server allows 30 sign-in challenges per minute per IP and 30 relay connections per minute per device. Back-to-back live suites can fail at random stages with `transport`, `backpressure`, or `CancellationError`. Wait about a minute between runs.
- **Idle detection.** A blinking cursor keeps XCTest from seeing the app as idle, so SSH UI tests pass a steady-cursor argument. The remote terminal has no such switch yet, so its UI steps wait out XCTest's idle timeout. The iOS tab bar shows and hides without animation for the same reason.
- **VoiceOver on the Mac.** See [VoiceOver UI tests](terminal-experience.md#voiceover-ui-tests) for the welcome window and `enable()` requirements.
- **Opt-in app acceptance.** `HandoffFlowTests.testPreparationAndSharingOfFreshSession` runs against the installed app only when `TEST_RUNNER_WITERM_HCI_FIXED_APP` and `TEST_RUNNER_WITERM_HCI_SESSION_ID` name it and a freshly created test session; it ends only that session.
- **Simulators.** Tests reuse an existing simulator; they never create, clone, or erase one.
- **Signing.** Keychain behavior is only meaningful in normally signed builds. Unsigned builds prove compilation only.
