# Mac Local Terminal

The Mac app runs real shells through a background service. Sessions keep running when you close the window, quit the app, or restart the service, and you can reattach to the same shell later. The [`witerm` command](cli.md) uses the same service, and paired iOS devices reach the sessions you share through the [encrypted relay](relay.md).

## Setup

Needs macOS 14+, Xcode, and tmux.

```sh
brew install tmux
xcodebuild -project apps/apple/Witerm.xcodeproj -scheme WitermMac \
  -destination 'platform=macOS' -derivedDataPath .build/apple \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

1. **First build.** Approve `SwiftTermBuildInfoPlugin` when Xcode asks (it only generates version info) and install Apple's Metal Toolchain. Don't turn off plugin validation globally.
2. **First launch.** The Welcome Tour's second page turns on the local service in place; the main window and Settings → General can too. If macOS asks for approval, the app links to Login Items & Extensions. Help → Welcome Tour shows the tour again.
3. **Sessions** appear under **This Mac**, including ones started with `witerm new`. The list refreshes on its own. ⌘N opens a new session at once, named Terminal N, with the keyboard in it.
4. **Command line.** Settings → Command Line installs `witerm` as a link into the app ([guide](cli.md)).

The `WitermMac` scheme builds `Witerm.app`, whose executable is `Contents/MacOS/Witerm`; quit a running instance by that exact path. The Swift module keeps the name `WitermMac`, so tests still `@testable import WitermMac`.

## Packaging

| Piece | Location in `Witerm.app` |
|---|---|
| Background service | `Contents/Library/LaunchServices/WitermAgent.app` |
| LaunchAgent (registered through SMAppService) | `Contents/Library/LaunchAgents/com.witerm.agent.plist` |
| `witerm` command | `Contents/Helpers/witerm` |

- **No sandbox on the Mac.** A full shell needs it, and a sandboxed app can't register an unsandboxed LaunchAgent ([Apple forum](https://developer.apple.com/forums/thread/802443)). The app and the service keep signing and Hardened Runtime with `Config/WitermDirect.entitlements`. `Config/Witerm.entitlements` is only for sandbox experiments. iOS stays sandboxed.
- **Shared App Group.** The app and the service share `group.com.witerm.$(DEVELOPMENT_TEAM)`, and both provisioning profiles must authorize it. The service uses the app's Keychain access group, so existing identities keep working. Your team ID lives only in the ignored `apps/apple/Config/Signing.local.xcconfig`.
- **The `witerm` command** is a signed Hardened Runtime tool with no entitlements. It reads the App Group from the app's `Info.plist` and connects to the service's socket as the same user.
- **Updating an installed copy.** Turn off the service in the old app, quit it, replace the whole bundle, then turn the service on again. Don't move the app after registering, and don't run several builds at once.

Production Developer ID signing and notarization haven't been done yet.

## Session behavior

- Each session is one shell in Witerm's own tmux server. Terminal, iTerm, and your own tmux are untouched.
- In the app, a session is a **terminal**. Open one to type in it, or **Watch** it, where nothing you press is sent; while it's open, **Stop Typing** and **Start Typing** (the row's context menu, the toolbar's More menu, or Terminal, ⇧⌘T) switch, and the window subtitle and the row's eye show Watching. **Leave** stops showing it here; it keeps running. **End Terminal…** asks for confirmation, then ends the shell and its programs.
- **Rename…** (sidebar context menu, the toolbar's More menu, or Terminal → Rename Terminal…, ⇧⌘R) changes only the display name. The shell, its programs, and every attachment keep running; paired devices see the new name the next time they list sessions. `witerm rename <session> <name>` does the same.
- Stopping the service disconnects viewers but keeps the shells. Continuity across logout, restart, or shutdown isn't promised. Sleep is covered in [Terminal experience](terminal-experience.md#sleep-and-weak-networks).
- Several clients can type in one session; the grid follows whoever typed last. Paired devices type only when this Mac's policy allows, and **Pause Remote Typing** (⇧⌘P, checked in menus while on; the toolbar toggle that appears while another device can type, pressed while paused; or `~p`) leaves them able only to watch. There's no forced takeover.
- Which paired devices reach a session is this Mac's choice: per device (all sessions, or shared ones only) and per session (**Sharing ▸ Keep Private** hides it from every paired device). Narrowing either disconnects the affected devices and keeps the shell. See [Encrypted relay](relay.md#using-it).
- The app's terminals start with up to 1,000 lines of earlier output in their scrollback ([Terminal experience](terminal-experience.md#display)).
- Terminal output stays in local memory and sockets; it's never stored or sent to the cloud. tmux keeps its usual scrollback, and your shell may keep history as configured.
- Clipboard escape sequences are blocked, and only http/https links you click open.

**Security and limits**
- The state directory is 0700 and sockets are 0600. Both sides check the peer's user ID, and a lock stops a second service from starting.
- At most 16 sessions and 32 connections, with bounded input and output queues.
- A viewer that can't keep up is disconnected and redraws when it reattaches. Bytes are never dropped silently.

Protocol details: [local-agent-v1](../protocol/local-agent-v1.md).

## Testing

```sh
make test-local   # WitermCore, service tests, and a real tmux smoke test
```

The smoke tool (`tools/local-agent-smoke`) uses a temporary 0700 directory, its own tmux server, and `/bin/sh`. It checks input and `stty size`, exclusive control and read-only limits, redraw on reconnect, the same shell PID across reconnect and service restart, and explicit close. It cleans up only what it created and never prints terminal content.

### Checking the installed service

`RegisteredServiceProbe` checks that the real, registered service keeps the same shell across lifecycle events. It creates its own test session and never quits the app or restarts the service itself: you do each step by hand, and confirm process state separately before each `verify`.

```sh
swift build --package-path tools/local-agent-smoke --product RegisteredServiceProbe
probe="$(swift build --package-path tools/local-agent-smoke --show-bin-path)/RegisteredServiceProbe"
app="$PWD/.build/Applications/Witerm.app"
group="$(/usr/libexec/PlistBuddy -c 'Print :WitermAppGroup' "$app/Contents/Info.plist")"
socket="$HOME/Library/Group Containers/$group/local/agent.sock"
evidence="$(mktemp -d /private/tmp/witerm-service.XXXXXX)/evidence.json"
"$probe" prepare "$socket" "$evidence"
```

| Step | Do this, then confirm | Then run |
|---|---|---|
| 1 | Quit the app from its menu. The app process is gone; the service still runs. | `"$probe" verify "$evidence" app-exit` |
| 2 | `launchctl kill SIGTERM gui/$(id -u)/com.witerm.agent`. A new service PID appears. | `... automatic-restart` |
| 3 | Reopen the same app. Exactly one copy runs. | `... app-reopen` |
| 4 | Turn the service off in the app (the shell stays alive), then on again. | `... service-stop-start` |
| 5 | Reattach in the app and type something. | `"$probe" cleanup "$evidence"` |

The evidence file holds only test IDs and PIDs. Cleanup checks them before ending anything, so it never touches other tmux servers or shells.
