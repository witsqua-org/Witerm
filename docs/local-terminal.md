# Mac Local Terminal

The Mac app runs real shells through a background service. Sessions keep running when you close the window, quit the app, or restart the service, and you can reattach to the same shell later. iOS reaches these sessions through the [encrypted relay](relay.md).

## Setup

Requires macOS 14+, Xcode, and tmux.

```sh
brew install tmux
xcodebuild -project apps/apple/Witerm.xcodeproj -scheme WitermMac \
  -destination 'platform=macOS' -derivedDataPath .build/apple \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

**First build.** Approve `SwiftTermBuildInfoPlugin` when Xcode asks (it only generates version info) and install Apple's Metal Toolchain. Don't turn off plugin validation globally.

**First launch.** Open the app and start the local service from the main window or Settings → General. If macOS asks for approval, the app links to Login Items & Extensions. Sessions appear under **This Mac**.

## How it's packaged

The background service ships inside the app as `Contents/Library/LaunchServices/WitermAgent.app`. It is registered through SMAppService with `Contents/Library/LaunchAgents/com.witerm.agent.plist`.

- **No sandbox.** A full shell needs it, and Apple doesn't let a sandboxed app register an unsandboxed LaunchAgent ([explanation](https://developer.apple.com/forums/thread/802443)). Both the app and the service keep signing and Hardened Runtime and use `Config/WitermDirect.entitlements`. `Config/Witerm.entitlements` is only for sandbox experiments. iOS stays sandboxed.
- **Shared App Group.** The app and the service share `group.com.witerm.$(DEVELOPMENT_TEAM)`, and both provisioning profiles must authorize it. The service uses the app's original Keychain access group, so existing identities keep working. Your team lives only in the ignored `apps/apple/Config/Signing.local.xcconfig`.
- **Updating an installed copy.** Stop the service in the old app, quit it, replace the whole bundle, then start the service again. Don't move the app after registering, and don't run several builds at once.

Production Developer ID signing and notarization have not been done yet.

## Session behavior

- Each session is one shell in Witerm's own tmux server. Terminal, iTerm, and your own tmux are untouched.
- Closing a terminal view only detaches it. **End Session** asks for confirmation and kills the shell's tasks.
- Stopping the service disconnects viewers but keeps the shells running. Continuity is not promised across logout, shutdown, or restart. Sleep is covered in [Terminal experience](terminal-experience.md).
- One controller per session. Other viewers are read-only, and there's no forced takeover.
- Terminal output stays in local memory and sockets. It is never stored or sent to the cloud. tmux keeps its usual scrollback, and your shell may keep history as configured.
- Clipboard escape sequences are blocked, and only links you click (http/https) open.

**Security and limits.**
- The state directory is 0700, sockets are 0600, and both sides check the peer's user ID. A lock prevents two services at once.
- Limits: 16 sessions, 32 connections, and bounded input and output queues.
- A viewer that can't keep up is disconnected and redraws when it reattaches. Bytes are never dropped silently.

Details: [local-agent-v1](../protocol/local-agent-v1.md).

## Testing

```sh
make test-local   # WitermCore + service tests + real tmux smoke test
```

The smoke tool (`tools/local-agent-smoke`) uses a temporary 0700 directory, its own tmux server, and `/bin/sh`. It checks:

- input and `stty size`
- exclusive control and read-only limits
- redraw on reconnect
- the same shell PID after reconnect and service restart
- explicit close

It cleans up only what it created and never prints terminal content.

## Checking the installed service

`RegisteredServiceProbe` checks that a real, registered service keeps the same shell across lifecycle events. It creates a test session and verifies process continuity, but it never quits the app or restarts the service itself. Do each lifecycle step by hand, and check process state separately before each `verify`.

```sh
swift build --package-path tools/local-agent-smoke --product RegisteredServiceProbe
probe="$(swift build --package-path tools/local-agent-smoke --show-bin-path)/RegisteredServiceProbe"
app="$PWD/.build/Applications/Witerm.app"
group="$(/usr/libexec/PlistBuddy -c 'Print :WitermAppGroup' "$app/Contents/Info.plist")"
socket="$HOME/Library/Group Containers/$group/local/agent.sock"
evidence="$(mktemp -d /private/tmp/witerm-service.XXXXXX)/evidence.json"
"$probe" prepare "$socket" "$evidence"
```

| Step | Action, then confirm | Then run |
|---|---|---|
| 1 | Quit the app from its menu. Confirm the app process is gone and the service is still running. | `"$probe" verify "$evidence" app-exit` |
| 2 | `launchctl kill SIGTERM gui/$(id -u)/com.witerm.agent`. Wait for a new service PID. | `... automatic-restart` |
| 3 | Reopen the same app. Confirm only one copy is running. | `... app-reopen` |
| 4 | Turn the service off in the app (shell still alive), then on again. | `... service-stop-start` |
| 5 | Reattach in the app and type something. | `"$probe" cleanup "$evidence"` |

The evidence file holds only test IDs and PIDs. Cleanup checks those identities before ending anything, so it never kills other tmux servers or shells.
