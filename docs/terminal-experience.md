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

Mac and iOS share **Terminal Display** settings: text size from 11 to 32 pt (iOS also follows Dynamic Type), enhanced contrast, the bell, and optional VoiceOver announcements of new output. ⌘+, ⌘− and ⌘0 change text size on the Mac and on iPad with a hardware keyboard.

**Bell.** A program's BEL plays the system alert sound on the Mac, and bounces the Dock icon once when Witerm is in the background. iOS plays a short haptic. Bells closer than 300 ms apart are dropped. **Ring the terminal bell** turns it off.

**Switching terminals.** The Terminal menu lists open terminals: ⌘1–⌘9 show one, ⇧⌘] and ⇧⌘[ step through them. On the Mac, these are sessions on this Mac followed by connected SSH hosts; on iPad, connected SSH hosts.

**Color schemes.** System (the platform's text colors), Graphite, Paper, and Ocean. Each scheme has a light and a dark variant and follows the system appearance; there's no in-app light/dark switch. Enhanced contrast, from the setting or the system's Increase Contrast, overrides the scheme. In every scheme, body text reaches at least 13:1 and every ANSI color programs use for text reaches 4.5:1 against the background; `WitermMacTerminalTests` checks both. Changing the scheme repaints colors only: it never changes the grid or its contents. Reduce Transparency applies to the surrounding interface.

**Find.** On the Mac, Edit → Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G), and Use Selection for Find (⌘E) open SwiftTerm's find bar over the focused terminal. On iPhone and iPad, **Find in Terminal** (also ⌘F with a hardware keyboard) shows a find bar under the terminal header with a match count. Search covers the scrollback held by this view; it selects and scrolls only your view and never sends input or resizes the session. A full-screen program's alternate screen isn't scrolled.

**Snippets.** Saved commands, managed in Settings → Snippets on the Mac and Settings → Snippets on iOS (up to 50, 4 KB each, no control characters except tabs and line breaks). They're stored in this device's preferences only and never sent to a server.
- Mac: Terminal → Insert Snippet types into the focused terminal (⌥⌘1–⌥⌘9 for the first nine). With no terminal focused, the Mac beeps.
- iOS: the **Snippets** key in the keyboard row lists them.
- A snippet is typed like a paste: bracketed when the program asked for that. **Press Return After Inserting** applies to single-line snippets only. On iOS, a multiline snippet goes through the same review as a multiline paste. View-only terminals ignore snippets, like any input.

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
