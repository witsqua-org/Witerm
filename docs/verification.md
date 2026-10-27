# Verification Status

This page summarizes what has been tested and what hasn't. The commands are in each guide and in the [README](../README.md#development).

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
