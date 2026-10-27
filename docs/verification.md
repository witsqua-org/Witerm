# Verification Status

This page summarizes what has been tested and what hasn't. The commands are in each guide and in the [README](../README.md#development).

## HCI improvements 1–7 — 2026-10-27

The [improvement summary](design/hci-improvements.md) maps all seven changes to their implementation. The final results supersede the earlier VoiceOver initialization failures.

- **Builds and native tests.** Normal signed macOS and iOS Simulator builds passed. `WitermMacTerminalTests` passed 9 cases; `WitermiOSTerminalTests` passed 15, including camera permission localization, Ctrl reset and accessibility state, 44 pt keys, confirmed bracketed paste and rejection of pending paste after disconnect or in read-only mode.
- **iPhone workflows.** Task choice, large text, address validation and recovery, invitation/server mismatch rejection, scanner-unavailable fallback, English/Chinese/fallback language and invitation review across background/foreground passed. Configuration cases covered saving without credentials or connecting, edit with Save, field-local errors, favorites, search and recovery from an empty search. The final shared field-label correction passed both configuration cases: `.build/apple/Logs/Test/Test-WitermiOS-2026.10.27_16-22-36-+0800.xcresult`.
- **iPad configuration.** Both configuration cases passed on the existing iPad Pro 13-inch simulator in landscape, including the split workspace, search and favorites. It was shut down afterward with its data retained. The retained iPhone 18 Pro was reused without cloning or erasing it.
- **VoiceOver.** All three cases passed on each platform, including speech/navigation and software-keyboard input on iOS. Mac coverage included forward/backward navigation, reading without writing, actual keyboard input and read-only text with large text, a narrow viewport, enhanced contrast and the alternate screen. Mac result: `.build/apple/Logs/Test/Test-WitermMacVoiceOverUITests-2026.10.27_16-42-49-+0800.xcresult`. Each harness launch now initializes the XCTest navigation driver with `enable()`, even when the system setting is already enabled; backward traversal handles entry into the native scroll container. The original speech and no-write assertions remain. Exploratory renderer changes were removed. A final baseline run restored VoiceOver to its initially recorded off state.
- **Mac configuration.** Saving without connecting, editing with Save, favorites, search and deletion of only the disposable profile passed. The test uses Tab traversal and an explicit form scroll to avoid XCTest's automatic scroll hit-point failure. Screenshot review removed duplicate field labels. Final result: `.build/apple/Logs/Test/Test-WitermMacVoiceOverUITests-2026.10.27_16-21-39-+0800.xcresult`.
- **Handoff preparation.** The fixed signed Mac app passed `HandoffFlowTests.testPreparationAndSharingOfFreshSession`: a new disposable session opened its preparation sheet, sharing and stopping sharing updated the actual checkbox, and sharing while remote access was off never reported readiness. Only that session was ended. Run this opt-in test with `TEST_RUNNER_WITERM_HCI_FIXED_APP` and `TEST_RUNNER_WITERM_HCI_SESSION_ID` set to a freshly created `HCI acceptance…` session.
- **SSH.** Package tests passed, with the 7 opt-in cases skipped in the normal run; all 7 live OpenSSH cases passed separately against disposable containers. A real iPhone Simulator SSH UI flow passed host-key verification, typing, SFTP, background disconnect, retained host context and explicit reconnect using the verified pin. Result: `.build/apple/Logs/Test/Test-WitermiOS-2026.10.27_15-47-06-+0800.xcresult`. Fixture profiles, pins, containers, networks and temporary keys were cleaned up.
- **Installed development app.** The fixed `.build/Applications/Witerm.app` was replaced as a whole signed bundle after disabling the old service and separately confirming GUI exit, removal of its launchd registration and exit of its helper. Deep, strict signature verification passed before and after replacement; the old bundle remains under `.build/Applications/Backups/`. Reopening the fixed app restored the prior service-on state. A new helper PID ran from the new fixed bundle, and process inspection confirmed exactly one GUI instance. Remote access settings were unchanged.
- **Session continuity through replacement.** `RegisteredServiceProbe` created one new disposable session. The same shell PID, shell nonce and live child PID survived service stop/start and the whole-bundle update. Actual input through the new GUI returned the original shell PID. Probe cleanup removed only that session and its verified child, and the GUI confirmed it was gone.

Physical-device camera scanning and permission recovery, a new end-to-end phone handoff, one-handed ergonomics, hardware keyboards, iPad multitasking and real-network/background behavior remain outside this simulator run. Previous relay acceptance below is separate historical evidence.

## Verified

All of this ran on a development Mac with Xcode 27, an iPhone 18 Pro iOS 27 simulator, and the local Docker server.

- **Server.** Go tests with the race detector, `go vet`, gofmt, and real-PostgreSQL integration tests. These cover authorization, pairing races, tunnel and revocation races, unchanged ciphertext forwarding, token expiry, limits, and database failure.
- **Pairing.** Shared Go/Swift signature vectors, the black-box `pairing-smoke` client, and a live two-device flow including revocation.
- **Relay crypto.** Noise reference vectors, context binding, and identity proofs. Tampering, replay, reordering, and reflection are all rejected. Also covered: cancellation, timeouts, backpressure, and local revocation despite a stale server grant.
- **Mac service, with real tmux.** Input, `stty size`, exclusive control, read-only limits, alternate-screen redraw, reconnect, and service restart.
  - Resizes are confirmed against the shell's real size, including when tmux delays or drops a pane resize.
- **Live relay against the real server.** Listing, control and view, handoff right after detach, local revocation, weak networks, and one Mac serving two servers at once.
- **Sharing.** Unshared sessions stay invisible and can't be attached remotely, even with a valid grant. Stopping sharing disconnects paired devices but keeps the shell and local viewers. Sharing survives a service restart, and remote `status` doesn't reveal the Mac's servers.
- **Command line.** The real `witerm` binary was run against a private broker, checking exit codes, JSON output, and that remote access is never reported ready while it's off. An attach through a real pseudo-terminal checked typing, resizing, `~.` detach, terminal restoration, and immediate control release. The `witerm` embedded in the signed app reached the installed service's socket without entitlements or a permission prompt.
- **Signed Mac app with sharing and the command line.** On the installed bundle:
  - Settings turned the service off and on, and test sessions survived it.
  - Settings → Command Line installed and removed the link, and the empty state's hint followed.
  - Sessions started with `witerm`, including one started while the app was open, appeared on their own.
  - Share and Stop Sharing worked from the header and the context menu, with the status bar matching.
  - The installed `witerm` attached interactively to the registered service.
  - This run found and fixed a layout overflow: unbounded wrapping text pushed the terminal header out of the window.
- **Persistence of the installed, signed service.** The same shell, shell variables, and child process survived each of these:
  - quitting the app
  - a launchd restart
  - turning the service off and on
  - replacing the whole app bundle
  - real system sleep
- **Native app flows** on the signed Mac app and the simulator:
  - pairing and approval
  - remote typing at the real grid size
  - read-only viewing
  - control release and acquire
  - server outage and recovery
  - idle revocation that clears the screen
  - pairing through two servers
- **Direct SSH** against disposable OpenSSH containers. Covers keys, passwords, jump hosts, SFTP limits and no-overwrite rules, about 2 MiB each way through L and R forwards, and rejection of unknown or changed host keys. Both apps' SSH flows pass UI tests, including two hosts connected at once.
- **Accessibility.** Native text-range tests on both platforms, real VoiceOver speech and navigation tests on the Mac and iOS, contrast checks, and language and fallback launches.

## Not yet verified

- Physical iPhones and iPads: haptics, VoiceOver pacing, iPad multitasking, external keyboards, final glass appearance.
- Public HTTPS/WSS deployments across real networks.
- Production Developer ID signing, notarization, and release.
- Session continuity across logout, restart, or shutdown (not promised).
- Braille displays and every VoiceOver gesture.
- Several server instances behind one address.

## Testing caveats

- **Live tests and rate limits.** The server allows 30 sign-in challenges per minute per IP and 30 relay connections per minute per device. Back-to-back live suites can fail at random stages with `transport`, `backpressure`, or `CancellationError`. Wait about a minute between runs.
- **Idle detection.** A blinking cursor keeps XCTest from seeing the app as idle, so SSH UI tests pass a steady-cursor argument. The remote terminal has no such switch yet, so its UI steps wait out XCTest's idle timeout.
- **Animated tab bar.** Animating the iOS tab bar left Liquid Glass animations running that blocked idle detection. The tab bar now shows and hides without animation.
- **VoiceOver on the Mac.** `enable()` can time out while the "Welcome to VoiceOver" window is open. Choose **Use VoiceOver** first. Synthetic sleep notifications are not real sleep.
- **Simulators.** Tests reuse an existing simulator; they never create, clone, or erase one.
- **Signing.** Keychain behavior is only meaningful in normally signed builds. Unsigned builds prove compilation only.
