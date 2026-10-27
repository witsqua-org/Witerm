# Terminal Experience

## Grid size

The controller sets a session's size: 20–500 columns and 5–200 rows. Viewers follow without reconnecting.

**When the controller resizes**, the Mac:

1. sends every attached device a `geometry` event, ahead of the redraw at the new size;
2. resizes each viewer's PTY (tmux sees SIGWINCH);
3. waits until the shell's own terminal reports the new size, then acknowledges and redraws.

tmux 3.8 can delay a pane resize that closely follows another, so the Mac keeps output flowing while it waits.

- If the shell never gets the new size, every viewer is disconnected and the session records the size the shell actually has.
- Every attach starts from the shell's real size, never a stored one. If the size can't be read, the attach fails.

Your own font or window size changes only your view, never the shared grid. A grid larger than your screen keeps its size and scrolls instead of reflowing.

## Display

Mac and iOS share **Terminal Display** settings: text size from 11 to 32 pt (iOS also follows Dynamic Type), enhanced contrast, and optional VoiceOver announcements of new output. On the Mac, ⌘+, ⌘− and ⌘0 change text size.

Colors follow the system's light/dark appearance; there's no in-app theme. Increase Contrast and Reduce Transparency apply to the surrounding interface.

`make test-contrast` checks the authored palettes: at least 4.5:1 for standard and 7:1 for enhanced, which also checks the 16 ANSI colors against the background. Colors chosen by remote programs (24-bit color, ANSI backgrounds) are outside these guarantees.

## Accessibility

**Reading.** Both platforms turn the visible terminal cells into a readable page of text, handling wide CJK characters, combining marks, and emoji.

- Reading is separate from typing: moving through text never moves the cursor or sends input.
- Pages follow visual lines, so a word wrapped across lines reads as two pieces.
- Page up and down move only your view; they're never sent to the remote program.

**Platform APIs.** The Mac uses public NSAccessibility text APIs (ranges, lines, selection, screen rectangles). iOS uses a read-only text view with line, word, and character rotors. Both offer previous page, next page, and jump to cursor.

**Output announcements** are off by default. When on, VoiceOver says "Terminal has new output", throttled. It never reads the whole screen or guesses at password prompts.

## Sleep and weak networks

Before the Mac sleeps, the service closes relay connections but keeps tmux and the shells. On wake, it reloads remote-access settings and listens again.

- Preparing for sleep takes at most 2 seconds and never blocks it.
- Mac views reattach after wake; iOS reconnects to the same session.
- Input is never resent. Logout, restart, and shutdown aren't covered.

Weak-network tests add delay, jitter, and read stalls to test connections only; they aren't system-level packet-loss tests. To prove input wasn't replayed, a test confirms the input ran once, reconnects, and checks it still ran exactly once.

## Native tests

These use in-memory terminals and public accessibility APIs only. They never touch your Keychain, the installed service, or real sessions. Mac test builds keep Hardened Runtime; the extra runpaths load Xcode-signed test frameworks.

```sh
xcodebuild -project apps/apple/Witerm.xcodeproj -scheme WitermMacTerminalTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks @executable_path/../PlugIns/WitermMacTerminalTests.xctest/Contents/Frameworks' test

# Use an existing simulator (xcrun simctl list devices); never create or erase one.
xcodebuild -project apps/apple/Witerm.xcodeproj -scheme WitermiOSTerminalTests \
  -destination "platform=iOS Simulator,id=$WITERM_EXISTING_SIMULATOR_UDID" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -maximum-parallel-testing-workers 1 test
```

### VoiceOver UI tests

`WitermMacVoiceOverUITests`, plus `TerminalVoiceOverTests` in the `WitermiOS` scheme. They drive a fixed in-memory terminal that exists only in DEBUG builds, behind `--witerm-terminal-accessibility-harness`. Run the two platforms one after the other, and the tests restore your VoiceOver setting afterwards.

On the Mac:

- **Before the first run**, close the "Welcome to VoiceOver" window by choosing **Use VoiceOver**, and exit the tutorial. While that window is up, VoiceOver can be on without running, and `enable()` times out.
- **Call `voiceOverService.enable()` before every harness launch**, even when `isEnabled` is true. `isEnabled` reports the system setting, not whether XCTest's driver is ready; skipping `enable()` caused stale speech and failed navigation.
- **Backward navigation** may land on the enclosing scroll view first; interact with it to reach the text.
- **If you turned VoiceOver on yourself** to get past the welcome window, set `TEST_RUNNER_WITERM_HCI_RESTORE_VOICEOVER_OFF=1` on the final baseline run only, so it's turned off again afterwards.
- UI automation's password authorization is a separate prerequisite.

API-level tests don't replace real speech and navigation checks, and simulated sleep notifications don't count as real sleep. Fixtures use a steady cursor, because a blinking one keeps XCTest from ever seeing the app as idle.
