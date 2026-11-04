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

Mac and iOS share **Terminal Display** settings: text size from 11 to 32 pt (iOS also follows Dynamic Type), enhanced contrast, the bell, and optional VoiceOver announcements of new output. ⌘+, ⌘− and ⌘0 change text size on the Mac and on iPad with a hardware keyboard. On iOS a new text size (from the actions menu, a pinch, ⌘+ or ⌘−) refits a terminal you type in at once: the grid becomes the whole cells of the new size that fit, and the host gets one resize (an SSH window-size change, or a paired terminal's resize request, after the usual settling). A terminal you're watching keeps the session's grid and only draws it larger or smaller. Neither goes through SwiftTerm's soft reset, so a program's modes (such as application cursor keys) are kept.

**Bell.** A program's BEL plays the system alert sound on the Mac, and bounces the Dock icon once when Witerm is in the background. iOS plays a short haptic. Bells closer than 300 ms apart are dropped. **Ring the terminal bell** turns it off.

**Switching terminals.** The Terminal menu lists open terminals: ⌘1–⌘9 show one, ⇧⌘] and ⇧⌘[ step through them. On the Mac, these are sessions on this Mac followed by connected SSH hosts; on iPad and iPhone with a hardware keyboard, the terminals of the paired device open in Terminals followed by connected SSH hosts. A paired terminal switches through the same detach-then-attach as the title's switcher. On the Mac the terminal shown takes keyboard focus, as it does after ⌘N, a click on its sidebar row, Return on the row, or a sheet closing over it; arrowing through the sidebar leaves focus in the list. Focus never changes the grid, and a view-only terminal doesn't take it.

**Color schemes.** System (the platform's text colors), Graphite, Paper, and Ocean. Each scheme has a light and a dark variant and follows the system appearance; there's no in-app light/dark switch. Enhanced contrast, from the setting or the system's Increase Contrast, overrides the scheme. In every scheme, body text reaches at least 13:1 and every ANSI color programs use for text reaches 4.5:1 against the background; `WitermMacTerminalTests` checks both. Changing the scheme repaints colors only: it never changes the grid or its contents. Reduce Transparency applies to the surrounding interface.

**Scrollback.** The Mac and iOS renderers keep their own scrollback. When one attaches, the Mac sends up to 1,000 lines (128 KiB) of the session's earlier output, with colors, above tmux's redraw of the live screen, and keeps tmux off the outer alternate screen so new output scrolls into it. While a full-screen program runs, only its screen is shown. `witerm attach` in a real terminal is unchanged.

**Long output (SSH).** Output is drained off the main thread and fed to the renderer in batches. Nothing is dropped: when more than 1 MiB waits for the renderer, or for the reader of the SSH channel, reading pauses, the SSH window fills, and the host waits until the app catches up. (Before Round 12 the channel kept 64 chunks and ended the session with "could not keep up" whenever one socket read carried more, which `seq 1 100000` on a fast link sometimes did.) The view follows new output while you're at the bottom; scrolled back, it stays where you put it until you return to the bottom. A view that follows output stays exactly on the bottom after the keyboard's animation and after a scroll that comes to rest within half a row of it, so the prompt is never cut off. The reading page VoiceOver reads is rebuilt at most once per run-loop turn, for paired terminals too. It follows touch scrolling when the scroll stops; with VoiceOver running it follows every step. On iOS, output is parsed on the main thread, where SwiftTerm's buffer lives; moving it off would need a change in SwiftTerm.

**Renderer (iOS).** Terminals draw with SwiftTerm's Core Graphics renderer. Debug builds can try SwiftTerm's Metal renderer instead, for measuring only: launch with `-witerm.debug.renderer metal`. Under Metal, Witerm draws the selection handles itself and lines the rows up with the scroll position, but up to one row at the bottom stays blank (a SwiftTerm limitation), so it isn't the default. Findings and numbers are in the [HCI log, Round 15](design/hci-improvements.md#part-2-swiftterms-metal-renderer-on-trial).

**Touch (iPhone and iPad).**

| Gesture | Effect |
|---|---|
| Drag | Scrolls the output, even when your finger rests a moment before moving (anything under half a second), and never selects. Over SSH, in a program that asked for the mouse (tmux with `mouse on`, vim with `mouse=a`, htop), with typing allowed, a one-finger drag is the mouse wheel at your finger instead, one step per row and coasting after a fling, so the program scrolls its own view; it never sends a held button, which those programs would turn into their own selection. A paired terminal always scrolls Witerm's scrollback: the Mac's own tmux keeps the mouse off (tmux 3.6 and later turn it on by default), and the phone ignores a stream from an older Mac that still asks. A grid wider than the screen pans one direction at a time. |
| Long press | Held for half a second (the system's long press): selects the word under your finger; keep dragging to extend. A touch that only stops a fling never starts one. Lifting shows Copy, Select Line, Select All, and Paste where typing is allowed, beside the selection rather than over it. Afterwards, a drag that starts on a handle's knob (a 44 pt target around the dot) moves that end, and the end stays on its row; a drag that starts anywhere else, the selected text included, scrolls, hiding the menu until the scroll stops, and the selection stays. The highlight is the app tint behind text that keeps its color. Works in view-only terminals too. |
| Double / triple tap | Selects a word / line. |
| Tap | Shows the keyboard when typing is allowed, or clears a selection. A terminal that can type shows it on its own when it connects. With the keyboard up, over SSH, a tap is a click for a program that asked for the mouse (vim moves its cursor there). |
| Pinch | Scales the text smoothly about your fingers and shows the size it will set; nothing is recomputed meanwhile. When your fingers lift, that size (whole points, 11–32) applies in the same frame, with one reflow and one resize. A watched terminal keeps the session's grid. With Reduce Motion the text doesn't scale live; the size still shows and applies on lifting. |
| Swipe from the left edge | Back to Terminals. The terminal stays connected (Round 18): a paired one goes on watching off screen, after typing is let go with the Mac's ACK, and reopens as it was. |

**Keyboard row.** Esc, Ctrl, Tab, and the arrows come first and fit an iPhone's width (each key keeps its own width, at least 44 pt); then Ctrl+C, Paste, Snippets, symbols, and Home/End/PgUp/PgDn. The Snippets key appears once a snippet is saved. Arrows and page keys repeat while held. A row you reordered in Settings → Keyboard Row is kept.

**Header.** On iPhone the navigation bar is the header, for SSH and paired terminals alike: the name, with the destination underneath (`user@host:port`, or the device, Typing on *device* when someone else types there, or Can only watch; Round 19: Typing on *device*, at its size, or Sized for *device*, while watching a grid another device set), a 2 pt edge in the machine's hue, and one button, the actions menu. It starts with **Text and Colors** (a submenu: smaller and larger text, then the color scheme), then Find in Terminal, then SFTP Files and Port Forwarding (SSH), and ends with Disconnect (Round 18: for paired terminals too, where it was Leave; a paired terminal keeps running on its Mac). **Keyboard (Round 16).** There's no Typing or Watching mode on iPhone and iPad: the keyboard is the switch. While it's hidden, a 44 pt keyboard button floats over the terminal's bottom right without reserving space (Round 18: the 60 pt strip under the text is gone, so the text uses the full height); it steps up out of the way of text and never covers the cursor; on a paired terminal it asks the Mac for typing (after the detach ACK of the watching connection), and a terminal this device can only watch has none. While it's up, the key row ends with Hide Keyboard, and hiding the keyboard on a paired terminal goes back to watching (the Mac's grid, no resize from this device). With other terminals open, a chevron beside the title lists them. **In landscape on iPhone, while the terminal has the keyboard, the bar steps aside** (it takes 78 pt there, four or five rows at the standard size): the key row then ends, pinned outside its scrolling keys, with Hide Keyboard (`keyboard.chevron.compact.down`, there in every orientation since Round 16) and the actions menu (`…`, the same items as the bar's). Hiding the keyboard, rotating to portrait, or the terminal losing focus (Find in Terminal, a sheet) brings the bar back, and with it the back button, the title and the switcher. With VoiceOver running the bar stays, so the title and state remain where VoiceOver finds them, and the key row has no extra keys. The bar leaves just before the terminal takes the keyboard and returns once the keyboard has gone, so the grid changes at most twice per transition, 50–70 ms apart (within one SSH resize). iPad and an iPhone whose landscape width is regular keep their layout. iPad keeps the terminal header. The Mac has none: the window title and subtitle name the session or `user@host:port` and any state worth a glance, and the toolbar holds the actions.

**Keyboard and layout.** The keyboard never changes the terminal's width. A terminal you type in fits the rows left above the keyboard and its key row, with the prompt as the last whole line, and gets every row back when the keyboard hides; the same rows return each time. On iOS the terminal measures the keyboard's space itself, from where the key row and the keyboard are in the current orientation, so rotating with the keyboard or the key row up gives the new orientation's grid at once (SwiftUI's keyboard avoidance is off for terminals: with only the key row up, iOS reports nothing on rotation, and the space it kept belonged to the old orientation). For SSH that's a window-size change on the server. A paired session follows the session's grid rules above: a terminal you're watching ignores the keyboard, and a typing device's new size applies only once it types. When an iPhone or iPad stops typing because its keyboard went down, it first sets the grid (if it's the one that set it) to what its screen shows while watching, so the watched terminal fills the screen rather than keeping the rows that were above the keyboard (Round 17). Under the terminal, the area past the home indicator uses the terminal's own background.

**Composing keyboards (iOS, Round 20).** With Pinyin and other keyboards that compose (the default in a Chinese, Japanese or Korean iPhone), letters being composed show at the cursor, underlined in the tint and on the terminal's own background, as in any iOS text field. Nothing is sent until the keyboard commits: a candidate types it, and Return, which such a keyboard renames Confirm (确认) while composing, puts the letters on the line as typed; the next Return runs the line, as in the Mac's Terminal. Before, nothing showed while composing, so `ls` and Return looked like a stuck terminal. The terminal's cells never change for it. SwiftTerm 1.19 draws no composition and its `setMarkedText(_:selectedRange:)` and `unmarkText()` can't be overridden, so `TerminalInputView` gives its own class those two Objective-C methods, which call SwiftTerm's and then place the composition (`composingHooks`). DEBUG builds log the shape of keyboard input (lengths, Return, whether it commits a composition as typed, the keyboard's language; never the text) under `com.witerm` / `terminal-input`.

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
