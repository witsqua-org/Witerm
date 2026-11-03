# Terminal Experience

## Grid size

A session is 20–500 columns by 5–200 rows. Several devices can type in it at once; the grid is that of whoever typed last (or the first to attach), and everyone else follows without reconnecting. The grid changes hands only after its owner has paused for 2 seconds, and a terminal's automatic answers to queries never count as typing, so opening a session on the phone doesn't shrink the Mac's window. A typing device that doesn't own the grid shows the owner's grid, scrollable like a viewer's, until it types; the Mac answers its resize requests with the grid in use and applies them when it types.

**When the grid changes**, the Mac:

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

**Switching terminals.** The Terminal menu lists open terminals: ⌘1–⌘9 show one, ⇧⌘] and ⇧⌘[ step through them. On the Mac, these are sessions on this Mac followed by connected SSH hosts; on iPad and iPhone with a hardware keyboard, the terminals of the paired device open in Terminals followed by connected SSH hosts. A paired terminal switches through the same detach-then-attach as the title's switcher. On the Mac the terminal shown takes keyboard focus, as it does after ⌘N, a click on its sidebar row, Return on the row, or a sheet closing over it; arrowing through the sidebar leaves focus in the list. Focus never changes the grid, and a view-only terminal doesn't take it.

**Color schemes.** System (the platform's text colors), Graphite, Paper, and Ocean. Each scheme has a light and a dark variant and follows the system appearance; there's no in-app light/dark switch. Enhanced contrast, from the setting or the system's Increase Contrast, overrides the scheme. In every scheme, body text reaches at least 13:1 and every ANSI color programs use for text reaches 4.5:1 against the background; `WitermMacTerminalTests` checks both. Changing the scheme repaints colors only: it never changes the grid or its contents. Reduce Transparency applies to the surrounding interface.

**Scrollback.** The Mac and iOS renderers keep their own scrollback. When one attaches, the Mac sends up to 1,000 lines (128 KiB) of the session's earlier output, with colors, above tmux's redraw of the live screen, and keeps tmux off the outer alternate screen so new output scrolls into it. While a full-screen program runs, only its screen is shown. `witerm attach` in a real terminal is unchanged.

**Long output (SSH).** Output is drained off the main thread and fed to the renderer in batches. Nothing is dropped: when more than 1 MiB waits for the renderer, or for the reader of the SSH channel, reading pauses, the SSH window fills, and the host waits until the app catches up. (Before Round 12 the channel kept 64 chunks and ended the session with "could not keep up" whenever one socket read carried more, which `seq 1 100000` on a fast link sometimes did.) The view follows new output while you're at the bottom; scrolled back, it stays where you put it until you return to the bottom. A view that follows output stays exactly on the bottom after the keyboard's animation and after a scroll that comes to rest within half a row of it, so the prompt is never cut off. The reading page VoiceOver reads is rebuilt at most once per run-loop turn, and follows touch scrolling.

**Touch (iPhone and iPad).**

| Gesture | Effect |
|---|---|
| Drag | Scrolls the output. In a program that asked for the mouse, with typing allowed, it goes to the program. A grid wider than the screen pans one direction at a time. |
| Long press | Selects the word under your finger; keep dragging to extend. Lifting shows Copy, Select Line, Select All, and Paste where typing is allowed. Afterwards, dragging a handle moves that end of the selection; a drag anywhere else scrolls. The highlight is the app tint behind text that keeps its color. Works in view-only terminals too. |
| Double / triple tap | Selects a word / line. |
| Tap | Shows the keyboard when typing is allowed, or clears a selection. A terminal that can type shows it on its own when it connects. |
| Pinch | Changes the text size once your fingers lift. |
| Swipe from the left edge | Back: from a terminal to its device's terminals, from those to Terminals. A Mac terminal stays connected until the Mac confirms it released control. |

**Keyboard row.** Esc, Ctrl, Tab, and the arrows come first and fit an iPhone's width (each key keeps its own width, at least 44 pt); then Ctrl+C, Paste, Snippets, symbols, and Home/End/PgUp/PgDn. The Snippets key appears once a snippet is saved. Arrows and page keys repeat while held. A row you reordered in Settings → Keyboard Row is kept.

**Header.** On iPhone the navigation bar is the header, for SSH and paired terminals alike: the name, with the destination underneath (`user@host:port`, or Typing or Watching with its symbol, then the device), a 2 pt edge in the machine's hue, and two buttons. The keyboard button shows `keyboard` or `keyboard.chevron.compact.down` for what it will do. The actions menu starts with smaller and larger text, then Find in Terminal, then SFTP Files and Port Forwarding (SSH) or Terminal Display and Stop Typing / Start Typing (paired; dimmed, with Can only watch, when this device can only watch; while watching, the title says Typing on *device* when someone else types), and ends with Disconnect or Leave (back to the device's terminals; the terminal keeps running). With other terminals open, a chevron beside the title lists them. iPad keeps the terminal header. The Mac has none: the window title and subtitle name the session or `user@host:port` and any state worth a glance, and the toolbar holds the actions.

**Keyboard and layout.** The keyboard never changes the terminal's width. A terminal you type in fits the rows left above the keyboard and its key row, with the prompt as the last whole line, and gets every row back when the keyboard hides; the same rows return each time. For SSH that's a window-size change on the server. A paired session follows the session's grid rules above: a terminal you're watching ignores the keyboard, and a typing device's new size applies only once it types. Under the terminal, the area past the home indicator uses the terminal's own background.

**Find.** On the Mac, Edit → Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G), and Use Selection for Find (⌘E) open SwiftTerm's find bar over the focused terminal. On iPhone, **Find in Terminal** is in the terminal's actions menu; on iPad it's in the header; ⌘F works on both with a hardware keyboard, and ⌘G and ⇧⌘G (Find Next and Find Previous in the Terminal menu) move between matches, opening the bar if it is closed. It shows a find bar under the header with a match count. Search covers the scrollback held by this view; it selects and scrolls only your view and never sends input or resizes the session. A full-screen program's alternate screen isn't scrolled.

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
- Mac views reattach after wake; iOS reconnects to the same session on its own when it returns to the foreground or the network comes back.
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
