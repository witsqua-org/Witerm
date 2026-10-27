# Terminal Experience

## Grid size

The controller sets a session's columns and rows: 20–500 columns, 5–200 rows. Viewers follow along without reconnecting.

**Resizing.** When the controller resizes:

1. The Mac sends every attached device a `geometry` event, ahead of the redraw at the new size.
2. It resizes each viewer's PTY, which tmux signals with SIGWINCH.
3. It confirms the new size and asks tmux to redraw.

**The acknowledgement is only sent once the shell's own terminal reports the new size.** tmux 3.8 can delay a pane resize that follows another one closely, so the Mac waits, with output still flowing, until the shell sees it.

- If the shell never gets the new size, every viewer is disconnected and the session records the size the shell actually has.
- Every attach starts from the shell's real size, not the stored one, so a stale record can't put a viewer on the wrong grid. If the size can't be read, the attach fails.

Changing your own font or window size only changes your view, never the shared grid. A grid larger than your screen keeps its real size and scrolls instead of reflowing.

## Display

Mac and iOS share **Terminal Display** settings:

- text size from 11 to 32 pt (iOS also follows Dynamic Type)
- enhanced contrast
- optional VoiceOver announcements for new output

On the Mac, ⌘+, ⌘− and ⌘0 change text size. Colors follow the system's light/dark appearance; there is no in-app theme. System Increase Contrast and Reduce Transparency apply to the surrounding interface.

`make test-contrast` checks the authored palettes:
- at least 4.5:1 for standard palettes, 7:1 for enhanced ones
- enhanced mode also checks the 16 ANSI colors against the background

Colors chosen by remote programs (24-bit color, ANSI backgrounds) are outside these guarantees.

## Accessibility

**Reading pages.** Both platforms turn the visible terminal cells into a readable text page, handling wide CJK characters, combining marks, and emoji.

- Reading selections are separate from typing. Moving through text never moves the cursor or sends input.
- Pages follow visual lines, so a word wrapped across lines reads as two pieces.
- Page up and down move only your view; they are never sent to the remote program.

**Platform APIs.**
- **Mac** uses public NSAccessibility text APIs: ranges, lines, selection, and screen rectangles.
- **iOS** uses a read-only text view with line, word, and character rotors.
- Both offer previous page, next page, and jump-to-cursor actions.

**Output notifications** are off by default. When on, VoiceOver says "Terminal has new output" (throttled). It never reads the whole screen or guesses at password prompts.

**Not covered by automated tests:** braille displays and every VoiceOver gesture combination.

## Sleep and weak networks

**Sleep.** Before the Mac sleeps, the service closes relay connections but keeps tmux and the shells. On wake, it reloads remote-access settings and listens again.

- Getting ready for sleep takes at most 2 seconds and never blocks sleep.
- Mac views reattach after wake. iOS reconnects to the same session.
- Input is never resent.
- Logout, restart, and shutdown are not covered.

**Weak-network tests** add delay, jitter, and read stalls to test connections only. They are not system-level packet-loss tests. To show that input wasn't replayed, a test first confirms the input ran once, then reconnects and checks it still ran exactly once.

## Native tests

These tests use in-memory terminals and public accessibility APIs only. They never touch your Keychain, the installed service, or real sessions. Mac test builds keep Hardened Runtime, and the extra runpaths below load Xcode-signed test frameworks:

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

**VoiceOver UI tests.** These are `WitermMacVoiceOverUITests`, plus `TerminalVoiceOverTests` in the `WitermiOS` scheme.

- They use a fixed in-memory terminal that exists only in DEBUG builds behind `--witerm-terminal-accessibility-harness`.
- Run the two platforms one after the other, not in parallel.
- Tests restore your VoiceOver setting afterwards.

On macOS, call `voiceOverService.enable()` before **each** harness launch, including when `isEnabled` is already true. The latter reports the system setting; it does not establish navigation readiness for the current XCTest driver. Checking the setting and skipping initialization caused stale speech and failed navigation even though ordinary SwiftUI controls worked. Backward navigation may land on the enclosing native scroll container first; interact with that container to return to its text.

**On the Mac, before the first run**, check for the "Welcome to VoiceOver" window. If it's open, choose **Use VoiceOver**. VoiceOver can be switched on but not actually running while that window is up, and the test's `enable()` call then times out.

Exit the VoiceOver tutorial before testing navigation. If VoiceOver was initially off and was enabled outside XCTest to finish this welcome step, record that state and set `TEST_RUNNER_WITERM_HCI_RESTORE_VOICEOVER_OFF=1` on the final ordinary-baseline run to restore it afterward. Leave this override unset during the other speech cases. macOS UI automation's password authorization is a separate prerequisite.

**Test infrastructure.** Unit tests of the accessibility APIs don't replace real speech and navigation checks, and simulated sleep notifications don't count as real sleep. Test fixtures use a steady cursor, because a blinking cursor keeps XCTest from ever seeing the app as idle.
