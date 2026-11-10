# HCI Improvements

## Round 1

Seven interaction changes delivered on 2026-10-27, after reviewing task choice, feedback, error prevention, and recovery against [Figma's introduction to human-computer interaction](https://www.figma.com/resource-library/human-computer-interaction/). The resulting rules are part of the [design guidelines](README.md); test results are in [Verification status](../verification.md).

| # | Change | Result | Main code |
|---|---|---|---|
| 1 | Start with the user's task | First-use iOS offers SSH or continuing from a Mac. SSH needs no server; existing setups skip the choice, and later launches reopen the last tab. | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift) |
| 2 | One Mac-to-iPhone checklist | A session sheet checks the server, pairing, live remote access, and sharing, and can release control. iOS pairs by QR scan or paste, through the same review. | [SessionHandoffView](../../apps/apple/Sources/LocalTerminal/SessionHandoffView.swift), [PairingScannerView](../../apps/apple/Sources/Pairing/PairingScannerView.swift) |
| 3 | Show where input goes | Headers name the destination and show enabled, view only, handoff pending, or disconnected, in words and symbols as well as machine color. | [TerminalHeader](../../apps/apple/Sources/Design/Components.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 4 | Explain connection lifetime | iOS SSH explains background disconnects and keeps the host and reason for an explicit Reconnect. Mac sessions keep running; End Session moves under More and keeps its confirmation. | [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift), [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift) |
| 5 | Separate saving from connecting | Edit uses Save; new hosts offer Save and Connect or Save Without Connecting. Optional names, advanced fields in disclosures, errors beside their fields. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 6 | Common mobile terminal keys | Esc, Ctrl, Tab, Ctrl+C, Paste, and arrows with labels, Dynamic Type, and 44 pt targets. Multiline paste is previewed and dropped on disconnect. | [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift), [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift) |
| 7 | Faster daily navigation | Host search, favorites, and recent-first order; the iPad keeps hosts beside the terminal; device rows lead with name and permission. | [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [RemoteDevicesView](../../apps/apple/Sources/RemoteTerminal/RemoteDevicesView.swift) |

## Round 2

A second pass against the same article's principles (shortcuts, feedback, error handling, reversal, control, memory load) and its context element, also on 2026-10-27.

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Error handling | SSH failures are classified (DNS, refused, timeout, unreachable, jump target, sign-in, sign-in method, algorithms) with a matching message and a **Check Connection…** or **Try Again** action. A rejected credential opens the form instead of retrying it. | [SSHFailureClassification](../../packages/WitermSSH/Sources/WitermSSH/SSHFailureClassification.swift), [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift) |
| 2 | Shortcuts | Menu commands also work on iPad with a hardware keyboard. A Terminal menu switches terminals with ⌘1–⌘9 and ⇧⌘] / ⇧⌘[. | [WitermApp](../../apps/apple/Sources/WitermApp.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift) |
| 3 | Context | A network monitor shows **No Network Connection** above remote work and rechecks servers when the network returns. Nothing reconnects or resends by itself. | [NetworkStatus](../../apps/apple/Sources/Design/NetworkStatus.swift) |
| 4 | Feedback | The terminal bell sounds on the Mac (and bounces the Dock icon in the background) and plays a haptic on iOS, rate-limited and switchable. iOS also gives haptics for SSH connect success and failure. | [TerminalBell](../../apps/apple/Sources/TerminalAccessibility/TerminalBell.swift) |
| 5 | Reversal | Deleting an SSH host is immediate with a 10-second Undo that restores credentials, color, favorite, and order; the snapshot lives in memory only. | [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |
| 6 | Error prevention, user | Ed25519 keys can be generated in the host form, with the public key to copy or share. RSA keys are flagged at the field before connecting. | [SSHKeyGenerator](../../packages/WitermSSH/Sources/WitermSSH/SSHKeyGenerator.swift), [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 7 | Memory load | Hosts can be imported from an OpenSSH config file the person chooses: aliases, addresses, ports, users, and jump chains, never credentials or other options. | [SSHConfigImport](../../packages/WitermSSH/Sources/WitermSSH/SSHConfigImport.swift), [SSHConfigImportView](../../apps/apple/Sources/SSH/SSHConfigImportView.swift) |
| 8 | Control | The iOS key row adds `|` `~` `/` `-`, Home, End, Page Up, and Page Down. | [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift) |

## Round 3

The items Round 2 left open, also on 2026-10-27.

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Memory load, shortcuts | Find in the terminal: SwiftTerm's find bar on the Mac (⌘F, ⌘G, ⇧⌘G, ⌘E), and a find bar with a match count on iOS. Search only selects and scrolls your view. | [WitermApp](../../apps/apple/Sources/WitermApp.swift), [TerminalFindBar](../../apps/apple/Sources/RemoteTerminal/TerminalFindBar.swift) |
| 2 | Control | Rename Mac sessions from the sidebar, the terminal's More menu, or `witerm rename`. A local-only `rename` operation in the service protocol; the relay rejects it. | [local-agent-v1](../../protocol/local-agent-v1.md), [AgentBroker](../../apps/mac-agent/Sources/WitermAgent/AgentBroker.swift), [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 3 | Control, accessibility | Color schemes (System, Graphite, Paper, Ocean), each with light and dark variants that follow the system, contrast-checked, and overridden by enhanced contrast. | [TerminalPalette](../../apps/apple/Sources/TerminalAccessibility/TerminalPalette.swift) |
| 4 | Control | Settings → Keyboard Row chooses and orders the iOS keys; open terminals update. | [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift), [SnippetSettings](../../apps/apple/Sources/Snippets/SnippetSettings.swift) |
| 5 | Memory load | Command snippets, stored on the device only: Terminal → Insert Snippet on the Mac, a Snippets key on iOS. Typed like a paste, reviewed on iOS when multiline, ignored by view-only terminals. | [CommandSnippets](../../apps/apple/Sources/Snippets/CommandSnippets.swift) |

## Round 4

From the fresh HCI review of 2026-10-27 (the "Now" items of its roadmap).

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Task, error prevention | The host form takes one `user@host:port` field and shows what it understood. Connect and Save for Later sit at the bottom; name and jump hosts move under More Options. | [SSHAddressInput](../../apps/apple/Sources/SSH/SSHAddressInput.swift), [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 2 | Crowding, dialogue | Search and Favorites Only appear from eight hosts. The background-disconnect note is shown once, with the first SSH terminal on screen, instead of on the list and the form. | [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |
| 3 | Consistency, memory load | iOS Settings is an index: one row per server with its status, terminal preferences as links that show their current values, and a Display reset scoped to display. Server status is stated once on iOS and Mac. | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [TerminalAppearanceSettings](../../apps/apple/Sources/Design/TerminalAppearanceSettings.swift) |
| 4 | Consistency | Fixed verbs: Leave a Mac session (it keeps running), End Session, Disconnect SSH, Share or Stop Sharing; one icon per idea. | [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |

**Still to evaluate on real hardware:** camera scanning and permission recovery, a full phone handoff, one-handed use, hardware keyboards and their ⌘ shortcut list, iPad multitasking, haptics including the bell, real Wi-Fi loss for the offline banner, and real-network background behavior.

## Round 5

Device continuation, from the review of 2026-10-28 ([issue #3](https://github.com/witsqua-org/Witerm/issues/3)).

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Task, memory load | Continue on Another Device… is one Mac sheet with one question per step (Server, Device, Approve, Open); done steps are skipped and the strip shows what comes next. It replaces the continuation checklist, the Pair sheet, and Share with a Link. | [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift) |
| 2 | Task, shortcuts | Continue from Another Device on iOS opens to the camera with Paste, reads pairing codes and session invitations, takes the server from the invitation, and opens the session once approved. The first-use task choice is gone. | [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift), [InvitationScanner](../../apps/apple/Sources/Pairing/InvitationScanner.swift) |
| 3 | Consistency | One entry point per side: the terminal header, context menu, and File (⌥⌘P) on the Mac; first use and the Devices tab on iOS. | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift) |
| 4 | Error prevention | One continuation server choice, `ServerList.selected`, used by every pairing screen and named on the code screen, so a code is never made for another server. | [ServerList](../../apps/apple/Sources/Server/ServerList.swift) |
| 5 | Control, error prevention | Approval defaults to the session you started from; you can choose sessions or allow all. Policies list sessions in `session_ids`, and an ended session leaves every list. | [LocalModels](../../packages/WitermCore/Sources/WitermCore/LocalModels.swift), [AgentBroker](../../apps/mac-agent/Sources/WitermAgent/AgentBroker.swift) |
| 6 | Error handling | Server addresses fill in `https://`, say what they'll connect to, recognize SSH logins, port 22, paths, credentials and invitations, and offer a fix. Check failures name the host and tell a non-Witerm answer apart. | [ServerAddressInput](../../apps/apple/Sources/Server/ServerAddressInput.swift), [ConnectionModel](../../apps/apple/Sources/ConnectionModel.swift) |
| 7 | Consistency | Mac Settings tabs share one 640 × 600 size. Devices holds the server, remote access, paired devices with an Edit sheet, invitations, and Manage Servers. | [MacSettingsView](../../apps/apple/Sources/Server/MacSettingsView.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift) |
| 8 | Recognition | Platform-neutral words (devices, the other device, continuation server, SSH host, View Only, Can Type, code); the Devices tab; the app is built as Witerm.app; a between-devices icon instead of a QR icon on an entry that also takes paste. | [Localizable](../../apps/apple/Sources/Resources/Localizable.xcstrings) |

**Still to evaluate on real hardware:** the whole continue flow with a camera scan, the Mac and phone flows run together, and VoiceOver through each step.

## Round 6: Mac

From an audit of the Mac app and service on 2026-11-02, against the honest-status and visibility principles.

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Honest status | Remote access shows what the service reports, not only the setting: the sidebar footer says Online, Connecting…, or Local terminal off; Settings → Devices shows This Mac's live state under Allow Remote Access; the Continue sheet's Open step says whether this Mac is online before waiting for the other device. | [MacRemoteAccessSettings](../../apps/apple/Sources/RemoteTerminal/MacRemoteAccessSettings.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift), [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift) |
| 2 | Visibility, privacy | Sidebar rows show a lock for private sessions and which other devices have a session open; the bar under the terminal header also names a private session. | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift) |
| 3 | Consistency | `witerm sessions` reports private sessions and paused typing (also in JSON), and points to Settings → Devices instead of the old Paired Devices. | [CLIRunner](../../apps/mac-agent/Sources/WitermCLI/CLIRunner.swift) |
| 4 | Continuity headroom | The server gives tunnel joins their own per-device budget and lets a Mac hold 8 tunnels, so a second phone or tablet no longer spends the first one's allowance. | [pairing/relay.go](../../server/internal/pairing/relay.go), [relay.go](../../server/internal/relay/relay.go) |

## Round 6: iOS

iOS continuation and terminal tools, from a simulator review on 2026-11-02 (iPhone 18 Pro, no camera).

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Error prevention, accessibility | Without a camera, or without camera permission, the continue sheet shows a short note instead of a square black camera frame, so Paste is on the first screen. At accessibility text sizes the note wraps instead of truncating, and Paste and Type Invitation… come first. | [InvitationScanner](../../apps/apple/Sources/Pairing/InvitationScanner.swift), [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift) |
| 2 | Task, shortcuts | Typing an invitation puts the camera away, so the field and Continue stay above the keyboard (Continue used to be hidden under it), and Return continues instead of adding a line. Scan a Code Instead goes back to the camera on devices that have one. | [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift) |
| 3 | Specific recovery | After a typed or pasted invitation, the way back is Use Another Invitation, which clears the used text; Scan Again stays for scanned codes. A revoked device and an empty session list point to Continue on Another Device instead of a "Device Pairing" screen that no longer exists. | [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift), [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 4 | Feedback, honest status | When the server refuses a request (an expired or used invitation, found against the live server), the waiting screen shows only why and the way back. It no longer keeps asking to compare this device's code and choose Approve, and Cancel Request becomes Cancel. | [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift) |
| 5 | Consistency | Paired device rows in Devices no longer repeat the server name, which the section header already gives when there are several servers, as in Terminals. | [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift) |

## Round 7: Mac

From an HCI review of the Mac app on 2026-11-02, centered on the time after a terminal connects: keyboard first, recognition over recall, progressive disclosure, honest minimal status, and one primary action.

**Baseline and result** (English, measured on the signed app; the "before" figures are the build installed before this round):

| Task or area | Before | After |
|---|---|---|
| ⌘N to the first keystroke in a new session | 2 keys (⌘N, then Return in the naming sheet) | 1 key (⌘N); `LocalSessionFlowTests` types without a click |
| A saved SSH host to the first keystroke | 2 clicks (row, Connect); no keyboard path | Click or arrow to the row, then Return |
| Words and controls in a connected local terminal's chrome | A 44 pt header: 4 status words, 3 labeled buttons (6 words) | No header: 2 icon-only toolbar buttons, and a subtitle only when there's state |
| Sharing bar | A second band of up to 2 lines (15 words when remote access is off) plus a labeled button | None: a subtitle of 2–5 words, and Pause Remote Typing only while another device can type |
| Main window, outside the terminal and session rows | 28 words, 9 controls | 16 words, 6 controls (11 words with remote access off, when there's no footer) |
| Continue sheet, server step | About 61 words, 3 rows, a 17-word explanation | About 41 words, 2 rows, no explanation |
| Continue sheet with nothing paired | Device step, choose Pair a New Device, Continue | Straight to the code; Back offers the other choices |

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Keyboard first, efficiency | ⌘N, and a click on the toolbar's +, opens a session at once, named Terminal N, with the keyboard in it. Naming is deferred to Rename Session… (⇧⌘R), so the naming sheet is gone. | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 2 | Keyboard first, user control | A terminal you open takes focus: ⌘N, ⌘1–⌘9, ⇧⌘] and ⇧⌘[, a click on its row, Return on its row (which also connects a saved host or a session that isn't open), and a sheet closing over it. Arrowing through the sidebar only browses. Focus waits for a sheet to close and never goes to a view-only terminal. | [MacTerminalTextView](../../apps/apple/Sources/TerminalAccessibility/MacTerminalTextView.swift), [NativeTerminalView](../../apps/apple/Sources/LocalTerminal/NativeTerminalView.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift) |
| 3 | Aesthetic and minimal design | No terminal header or sharing bar on the Mac. The window title names the session or host, the subtitle carries only state (View Only; *device* can type or is viewing; Private; Remote Typing Paused; Shared, Shared · Connecting…, or Shared · Remote access off; `user@host:port` for SSH), and the toolbar holds the actions as symbols with tooltips and VoiceOver labels. A 2 pt line in the host's hue still tops an SSH terminal. | [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift), [SSHHostDetail](../../apps/apple/Sources/SSH/SSHHostDetail.swift) |
| 4 | Honest, minimal status | When another device joins or leaves, its name appears in or leaves the subtitle and VoiceOver announces it. Pause Remote Typing appears only while a device can type. The service reports who is attached and whether they can type, not each keystroke, so the Mac says "can type" rather than "typing". The sidebar footer shows only while remote access is on, in one line. Settings → Devices' This Mac row now reads "This Mac, Online" to VoiceOver; it used to drop the state. | [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift) |
| 5 | Shortcuts, flexibility | The Terminal menu adds Rename Session… (⇧⌘R), Pause or Allow Remote Typing (⇧⌘P), and End Session for the selected session. The toolbar loses Refresh (the list updates on its own; ⌘R stays in View). | [WitermApp](../../apps/apple/Sources/WitermApp.swift) |
| 6 | Recognition, help and documentation | The Welcome Tour: four pages in a 440 × 320 sheet (sessions keep running; the background service, switched on in place; Continue on Another Device, ⌥⌘P; `witerm new`). Esc skips, Return and → move on, ← goes back, Get Started opens a new session. It shows while `witerm.onboarding.completedVersion` is below 1, and Help → Welcome Tour replaces Witerm Help, which had no help book. English and Simplified Chinese. | [MacWelcomeTour](../../apps/apple/Sources/Onboarding/MacWelcomeTour.swift), [WitermApp](../../apps/apple/Sources/WitermApp.swift) |
| 7 | Minimal design, task | The Continue sheet drops the server step's paragraph and its duplicate Remote Access row, the device question that the caption already asks, and second lines that repeat a title. Its waiting steps say only "choose Continue from Another Device". With nothing paired, it goes straight to the code. | [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift) |
| 8 | Minimal design, consistency | Empty and disconnected states keep a title and their actions only. Importing SSH hosts has one entry point (File) instead of also a sidebar button. Settings drops footers that explained the relay or the shell profile, and offers Login Items only while macOS waits for that approval. | [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift), [MacSettingsView](../../apps/apple/Sources/Server/MacSettingsView.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift), [CommandLineToolSettings](../../apps/apple/Sources/LocalTerminal/CommandLineToolSettings.swift) |

**Still to evaluate:** a saved SSH host's Return-to-connect and focus against the disposable OpenSSH fixture, real VoiceOver speech for the join and leave announcements and the subtitle, and the phone joining as seen from the Mac in the joint `PhoneContinuityFlowTests` run.

## Round 7: iOS

The time after a terminal connects, minimal visible text, and a first-launch Welcome Tour, from a simulator review on 2026-11-02 (iPhone 18 Pro). Measured against the Round 6 build on the same simulator with the disposable OpenSSH fixture; counts are on-screen controls (tab bar included) and visible words from the accessibility hierarchy, keyboard excluded.

| Task or screen | Before | After |
|---|---|---|
| Saved SSH host to typing | 2 taps (host, Keyboard) | 1 tap (host) |
| Paired Mac session to typing | 3 taps (Mac, session, Keyboard) | 1 tap with one shared session, 2 with several |
| Reconnect a dropped SSH terminal to typing | 2 taps | 1 tap |
| Larger terminal text | 4 taps (More, Terminal Display, +, Done) or pinch | 2 taps (More, Larger) or pinch |
| Find in an iPhone SSH terminal | 1 tap (header) | 2 taps (More, Find); ⌘F unchanged |
| Keys visible without scrolling the key row | 4 and part of a fifth | 7 (Esc, Ctrl, Tab, ←↑↓→) |

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Task, shortcuts | A terminal that can type brings up the keyboard as soon as it connects (SSH, paired Mac sessions, reconnects, and Start Typing), once per connection. The keyboard button's symbol and label say whether it will show or hide it. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift), [TerminalFindBar](../../apps/apple/Sources/RemoteTerminal/TerminalFindBar.swift) |
| 2 | Minimal chrome, consistency | iPhone SSH drops its second header row (address and a permanent "Input Enabled"): the navigation bar shows the name over `user@host:port` with a hue edge, like paired terminals. Back buttons are symbols with spoken names. | [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 3 | Progressive disclosure, frequency | One actions menu per terminal, most frequent first: smaller and larger text, Find, then Files, Forwarding or Display, typing or watching, and Disconnect or Leave last. The duplicate Sessions item and the iPad header's Watch Only button moved into it or went away. | [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 4 | Recognition, direct manipulation | A chevron beside the title lists the other open terminals; for a paired Mac, switching goes through the same detach ACK as any switch. ⇧⌘] and ⇧⌘[ step through SSH terminals on iPhone and iPad. | [TerminalFindBar](../../apps/apple/Sources/RemoteTerminal/TerminalFindBar.swift), [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift) |
| 5 | Task | Tapping a paired Mac in Terminals opens its session directly when it shares only one. The session list drops its heading and "Open to Type"; only View Only is stated, and watching a session you could type in is a long press (and a VoiceOver action) instead of a button on every row. | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 6 | Visibility, error prevention | The terminal no longer clips its prompt under the key row: SwiftTerm's automatic insets are off inside the surface, so the last whole line above the keyboard is the prompt. Hiding the keyboard returns the same rows every time, and the width never changes. Under an iPhone SSH terminal, the terminal's own background continues past the home indicator. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |
| 7 | Efficiency | Keys keep their own width (they had all stretched to 69 pt), so the first seven fit an iPhone. The Snippets key appears once a snippet is saved instead of opening an empty menu. | [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift) |
| 8 | Accessibility, performance | The reading page VoiceOver reads now follows touch scrolling and output-following (SwiftTerm moves its rows without telling the delegate), and is rebuilt once per run-loop turn instead of for every output chunk. The keyboard's animation, and a fling back to the bottom, used to leave a following view a few points short of the bottom (measured: 3.33 pt, aligned to an in-between keyboard height with the same row count), cutting off the foot of the prompt and dropping it from the reading page; a following view is now kept on the bottom after every layout and scroll. Row edges within a millionth of a cell also count as whole on both platforms, so floating-point error deep in the scrollback can't drop a row. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift), [SSHNativeTerminalView](../../apps/apple/Sources/SSH/SSHNativeTerminalView.swift), [TerminalAXDocument](../../apps/apple/Sources/TerminalAccessibility/TerminalAXDocument.swift) |
| 9 | Reliability, performance | Long SSH output no longer ends the session. The shell keeps only 64 chunks and a program printing line by line fills them in moments, so any pause on the main thread (layout, an accessibility snapshot) disconnected `seq 1 3000` with a backpressure error. Output now drains off the main thread into a bounded batch (8 MiB) that the main thread feeds in one go. Both apps share this. | [SSHNativeTerminalView](../../apps/apple/Sources/SSH/SSHNativeTerminalView.swift) |
| 10 | Minimal text | Removed explanatory footers and taglines (Settings and server list, the first-use paragraph and tagline, the Devices continue subtitle) and shortened the SSH background note, the continue instructions, a disconnected card ("Disconnected"), and the empty session list. | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift), [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift) |
| 11 | Help and documentation | Welcome Tour on first launch: Connect over SSH, Continue from Your Mac, and Keys and Gestures (with a miniature key row), each a symbol, a title, and one line; Skip on every page and Get Started last, landing on Terminals. Settings → Help → Welcome Tour reopens it. Shown while `witerm.onboarding.completedVersion` is below 1. | [IOSWelcomeTour](../../apps/apple/Sources/Onboarding/IOSWelcomeTour.swift) |

**Still to evaluate on real hardware:** the keyboard coming up on connect with a hardware keyboard and with VoiceOver, drag handles on a selection, momentum scrolling feel, and the tour with VoiceOver speech.

## Round 8: Mac

A wording and state review of every Mac surface on 2026-11-03, against the shared vocabulary in the [design guide](README.md#wording). Prioritized by harm: a wrong mental model first, then invisible state, missing feedback, and wording. Screenshots before and after are in `.build/screenshots/round8-mac/` (`before-*`, `after-*`, `hover-*`), from the opt-in `Round8ScreenshotTests` and `HoverScreenshotTests`.

**Before and after** (English, signed builds):

| Task or area | Before | After |
|---|---|---|
| A terminal's context menu, typing vs. watching | The same 7 items both ways (Connect, View Only, …): nothing showed which was in effect | Stop Typing and Leave while typing, Start Typing and Leave while watching; Open and Watch when it isn't shown |
| Seeing that you're watching | The subtitle "View Only" only | The subtitle "Watching", an eye on the row, Start Typing in the toolbar, a beep on a key press, VoiceOver "Terminal, Watching" |
| Device step line in the Continue sheet | "Paired · can open “*name*” · view only" (6 words and the name) | "Can only watch “*name*”" (3 and the name) |
| Settings → Devices, under Allow Remote Access | 11 words ("…reach only the sessions you allow, through this server.") | 9 words ("Paired devices can open only the terminals you allow.") |
| Copying a command in Settings → Command Line | No visible change | Copy turns into ✓ Copied for 2 seconds and VoiceOver says Copied |

| # | Surface | What a first-time user would think, vs. what happens | Principle | Change | Main code |
|---|---|---|---|---|---|
| 1 | Toolbar +, File menu, empty states | "New Session" of what? A login session, an SSH session? | Match between system and real world | **New Terminal** everywhere, with the tooltip "A new shell on this Mac. It keeps running after you close it or quit Witerm." | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [WitermApp](../../apps/apple/Sources/WitermApp.swift) |
| 2 | A terminal's context menu | Connect and View Only on a terminal that's already open: is it connected? Which one am I in? Choosing either changed nothing in the menu. | Visibility of system status; consistency | Open and Watch only when it isn't shown here; once shown, a single item titled by what it does next (Stop Typing, Start Typing) and Leave. Connect is for SSH only. | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift) |
| 3 | An open terminal | Watching looked like typing; keys silently went nowhere. | Visibility of system status; error prevention | Subtitle **Watching**; an eye on the row; **Start Typing** (keyboard) in the toolbar only while watching; a key press beeps; VoiceOver reads "Terminal, Watching" and announces each switch. The same switch is in More and Terminal (⇧⌘T). | [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift), [MacTerminalTextView](../../apps/apple/Sources/TerminalAccessibility/MacTerminalTextView.swift), [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 4 | Subtitle, row tooltip, VoiceOver value | "iPhone can type": is it typing? "is viewing" vs. "View Only" for the same idea; another local typist was invisible. | Consistency; visibility | **Typing on *device***, **Watching on *device***, and **Typing in another window** (for `witerm attach` elsewhere on this Mac). The row's value says Typing or Watching instead of "Connected". | [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 5 | Pause Remote Typing | The toolbar's hand icon showed the next action, not the state; the Terminal menu said Allow while the context menu said Pause ✓ for the same state. | Visibility; consistency | A toggle everywhere: pressed in the toolbar, checked in menus, while paused. | [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift), [WitermApp](../../apps/apple/Sources/WitermApp.swift) |
| 6 | Permissions (approve step, invitations, device rows and Edit sheet, Open step) | "View Only", "Can Type", "can open … view only": can it see everything? only read? | Match with the real world; consistency | **Can watch and type** / **Can only watch** as one two-option choice; which terminals: **Only “*name*”**, **Terminals you choose**, **All terminals**. | [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift) |
| 7 | Device Edit sheet | "Revoke Access…": what's revoke? "Type While This Mac Is Attached": attached? | Match with the real world | **Unpair…**, confirmed with what the device loses and that pairing again restores it; **Type at the Same Time as This Mac** with a tooltip for Off. | [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift) |
| 8 | Settings → General and every "local terminal" message | "Local Terminal" read as one terminal; "Disable" with "The current terminal connection will be disconnected" sounded like losing work. | Match with the real world; error prevention | This Mac → **Terminals**: On/Off with **Turn On Terminals** / **Turn Off…**; the confirmation says terminals keep running but can't be opened until it's back on. Errors name what to do in Settings → General. | [MacSettingsView](../../apps/apple/Sources/Server/MacSettingsView.swift), [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift), [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 9 | Servers, everywhere on the Mac | "Continuation server" isn't a thing anyone knows. | Match with the real world | **Relay server** in Devices, Manage Servers, the Continue sheet, the footer's tooltip, address sheets, and errors. | [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift), [ServerViews](../../apps/apple/Sources/Server/ServerViews.swift) |
| 10 | SSH host menus | "Delete Connection" on a connected host reads as Disconnect; "New SSH Connection" and "Add SSH Host…" named one action twice. | Error prevention; consistency | **Delete Host…**, **Edit Host…** (as on iOS), and **Add SSH Host…** everywhere on the Mac, with tooltips on Connect and Disconnect. The trust sheet says "Check that this matches the fingerprint the host's owner gives you." instead of "through a trusted channel". | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [SSHHostDetail](../../apps/apple/Sources/SSH/SSHHostDetail.swift) |
| 11 | End confirmation, rename, left terminal | "End Terminal Session?" didn't say which, or that other devices lose it; "Session Still Running" with Connect. | Error prevention; consistency | **End “*name*”?** with "Its shell and the programs in it stop, here and on every device"; **End Terminal…**; **Rename Terminal**; **Still Running** with Open and Watch. | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift) |
| 12 | Pairing errors, invitations | "Leave This Pairing" reused Leave; "End Access" in Invitations. | Consistency | **Start Over**; **End Invitation**. | [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift) |
| 13 | Busy and spoken messages | "Connecting to session…", "Session Shared", "Session Available to Paired Devices". | Consistency | Opening terminal…, Terminal Shared, Terminal No Longer Private, and the rest in the shared words. | [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 14 | Welcome Tour, Command Line | "Type `witerm new` in Terminal" next to "terminal"; command captions said session and attach. | Match with the real world | Terminals keep running; "in any shell"; captions say terminal, open, and leave. | [MacWelcomeTour](../../apps/apple/Sources/Onboarding/MacWelcomeTour.swift), [CommandLineToolSettings](../../apps/apple/Sources/LocalTerminal/CommandLineToolSettings.swift) |
| 15 | Copy in Settings → Command Line and the empty state | Nothing changed on click; did it copy? | Feedback | ✓ Copied for 2 seconds, announced. | [CommandLineToolSettings](../../apps/apple/Sources/LocalTerminal/CommandLineToolSettings.swift) |

**Hover and pointer.** One shared Mac-only pair in [Components](../../apps/apple/Sources/Design/Components.swift): `witermHover()` (a primary fill at 8%, 16% with Increase Contrast, a 150 ms fade or none with Reduce Motion, none while disabled, through an AppKit tracking area because `onHover` missed the pointer inside scroll views) and `witermLinkPointer()` (the pointing hand on macOS 15+, `NSCursor` before; arrow while disabled). Native controls keep their own behavior.

| Element | Before | After |
|---|---|---|
| Sidebar footer (opens Settings → Devices) | No hover; tooltip named only the server | Hover fill; tooltip "Relay server: *name*. Opens Settings → Devices." |
| Continue sheet device choices | No hover; only part of each card took clicks | Hover fill; the whole card takes clicks |
| Change… (Continue sheet) and Pair a Device… (Settings → Devices) | Arrow pointer | Pointing hand; Change… has a tooltip |
| Welcome Tour page dots | Not interactive | Each dot goes to its page, with hover and a "Page *n* of 4" tooltip; Next and the arrows stay the main path |
| SSH form More Options row and New Key / Existing Key cards | No hover | Hover fill over the whole row or card |
| Snippet rows (Settings → Snippets), SFTP file rows | No hover | Hover fill; snippets get an Edit snippet tooltip |
| Toolbar and menu icons | Some tooltips repeated the label ("More") | Tooltips say what happens: "More for this terminal", "Watching. Start typing here.", "Pause typing from other devices", "Disconnect; the remote shell ends" |
| Terminal text, typing or watching | I-beam (SwiftTerm's cursor rect) | Unchanged, checked with the pointer on screen |

**Verification.** `WitermMacTerminalTests` (26) pass. On this round's signed build: `LocalSessionFlowTests` (now also checking that the row's menu reads Stop Typing, that choosing it makes the row's value, the subtitle, and the toolbar say watching, and that Start Typing switches back), `Round8ScreenshotTests`, and `HoverScreenshotTests` pass; see [Verification](../verification.md).

**Still to evaluate:** real VoiceOver speech for the Typing and Watching announcements, the beep while watching with a hardware keyboard and IME, the hover fill on a light appearance, and the Chinese strings once the catalog has them.

## Round 8: iOS

A wording and system-status review of every iPhone screen (iPad where its code differs) against the shared [Wording](README.md#wording) vocabulary, on 2026-11-03. Each finding is ordered by harm: a wrong mental model first, then hidden state, missing feedback, and wording. Screenshots before and after (English, iPhone 18 Pro simulator) come from the opt-in `ScreenshotTourTests`.

| # | Surface | What a first-time user would think | Principle | Change | Main code |
|---|---|---|---|---|---|
| 1 | Paired terminal → Leave | "Leave" ended in **Terminal Disconnected** with Reconnect and View Only over the frozen screen, so leaving looked like a dropped connection. | Match with the real world; mental model | Leave goes back to the device's terminals, where the one just left is still listed; its VoiceOver hint says it keeps running. | [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 2 | Paired terminal title | Typing or watching showed only as a small keyboard or eye symbol; the words were spoken, never shown. | Visibility of system status | The line under the name reads *Typing · device* or *Watching · device* (or Switching to Typing…, Disconnected, Terminal Ended). State first, so a long device name never truncates it. | [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 3 | Actions menu: Watch Only / Start Typing | "Watch Only" read like a mode label, not an action; a device that could only watch had no item at all, so there was no clue why typing was impossible. | Visibility, recognition | Stop Typing and Start Typing name the switch from the current state; the title changes as soon as it's done and VoiceOver announces Typing or Watching. A device that can only watch shows Start Typing dimmed, with Can only watch under it. | [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift), [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift) |
| 4 | Unpaired while open | The terminal and its list vanished to Terminals with no explanation (the reason sat only in the Devices tab). | Visibility, error recovery | A **No Longer Paired with *device*** banner on Terminals, with how to pair again, until OK; VoiceOver announces it. | [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift) |
| 5 | A terminal that failed to open | A card said **Terminal Disconnected** / Reconnect for a terminal that never connected. | Match with the real world | The card names the terminal with Try Again; the banner above says why. | [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 6 | Permissions on rows, Device Details, the check screen | "View Only" vs "Can Type" vs "Access Level": unclear whose permission, and "Can Type" said nothing about watching. | Consistency, recognition | **Can watch and type** / **Can only watch** everywhere; Device Details says Access and Relay Server. Terminals rows state only the limit (Can only watch); the device's terminal list states it once instead of on every row. | [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift), [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [RemoteModels](../../apps/apple/Sources/RemoteTerminal/RemoteModels.swift), [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift) |
| 7 | Watching a terminal you could type in | Long-press and reconnect offered "View Only", a state name used as a verb. | Consistency | **Watch**, the vocabulary's verb, in the long-press menu, VoiceOver actions, the "typing elsewhere" banner, and beside Reconnect. | [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 8 | Errors and notices | "Session Is Being Controlled", "View-Only Connection", "access was revoked", "check device authorization": jargon a person can't act on. | Help users recognize and recover | Typing on Another Device (Watch, or try again when it stops typing), Can Only Watch, No Longer Paired (unpaired, how to pair again), Terminal Unavailable (pull down to refresh). An automatic reconnect that finds someone typing says "Another device is typing, so you're watching." | [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift) |
| 9 | One-terminal invitation | "Request to Type" and "Open Session" for the two kinds; "Open Session" didn't say it would only watch. | Match with the real world | Request Access (it waits for approval) or Watch (opens at once); the waiting line says Opening the terminal…. | [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift), [JoinSessionModel](../../apps/apple/Sources/Continuity/JoinSessionModel.swift) |
| 10 | Servers | "Continuation server" named a feature, not a thing; the Add/Edit sheets and errors used it too. | Consistency | **Relay server** in Settings → Relay Servers, the add and edit sheets, address errors, the check screen, and the snippets note. Removing one says the devices "stay paired" instead of "are not revoked". | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [ServerViews](../../apps/apple/Sources/Server/ServerViews.swift), [ServerAddressSheet](../../apps/apple/Sources/Server/ServerAddressSheet.swift), [ServerAddressInput](../../apps/apple/Sources/Server/ServerAddressInput.swift), [ConnectionModel](../../apps/apple/Sources/ConnectionModel.swift) |
| 11 | SSH host actions | "Edit Connection" and "Delete Connection" on a host's menu: does Delete disconnect? | Match with the real world | Edit Host and Delete Host (the edit form says Edit SSH Host); Import SSH Hosts… matches the first-use row and the Mac menu. | [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift), [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 12 | SSH terminal header | "Input Enabled" on every SSH terminal (iPad header, iPhone VoiceOver), though SSH can always type. | Minimal text, honest status | Connected, the state that can actually change. The SSH menu's spoken name is Terminal Actions, as for paired terminals. | [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |
| 13 | Settings → Typing; terminal menu "Display" | "Typing" as a settings group would read as the Typing state in Chinese and English alike; "Display" and "Terminal Display" opened the same sheet. | Consistency | The group is Keyboard; both menus say Terminal Display. | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 14 | Welcome Tour page 2 | "Continue from Your Mac … Scan or paste here": *here* was the tour, which can't scan. | Match with the real world | Continue from Another Device: "On the other device, choose Continue on Another Device, then scan its code." | [IOSWelcomeTour](../../apps/apple/Sources/Onboarding/IOSWelcomeTour.swift) |
| 15 | VoiceOver names | "Sessions", "Read-Only Terminal Text", "The session stays connected." | Consistency | The back button from a terminal is the device's name; Terminal Text, Watching; The terminal stays connected. | [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift), [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |

| Screen | Before | After |
|---|---|---|
| Paired terminal title, while typing | name, symbol, device (state only spoken) | name, symbol, *Typing · device* (+1 word, always visible) |
| Leave | 3 controls over a frozen screen (Reconnect, View Only, back) | the device's terminal list (0 extra controls) |
| Paired device on Terminals, can type | 2 words (Can Type) | none |
| Device's terminal list, can only watch | a badge plus "View Only" on every row | the badge only |
| Terminal this device can only watch, actions menu | no typing item | Start Typing, dimmed, with Can only watch |
| Words changed to the shared vocabulary | — | 53 strings added or reworded, 50 retired (`docs/design/round8-strings-ios.json`) |

**Still to check with a Mac (joint run):** the new title line and Stop Typing / Start Typing against a real paired terminal (now in `MacContinuityFlowTests`), Leave landing on the list, the No Longer Paired banner after unpairing from the Mac, and an automatic reconnect that finds another device typing. The phone can't yet say *which* device is typing elsewhere: the relay doesn't report it.

## Round 9: Mac

Opening a terminal on another device, the Continue sheet's opening, who is typing, a phone unpairing itself, hover on sidebar rows, and submenus, from a review on 2026-11-03. Frames, hover shots, and menus are in `.build/screenshots/round9-mac/` (`before-sheet-open-*` and `after-sheet-open-*` with their videos, `hover-*`, `menu-*`).

**The animation from the top-left corner.** The whole Continue sheet animated on its `step`, and the sheet changed `step` on its own right after it appeared (once its checks came back), while its parts were being laid out for the first time; so the server step's form, the buttons, and the device rows slid and grew from the top-left corner to their places for about half a second (frames 5–16 of `before-sheet-open-2`). Now the first step is decided before anything is drawn and applied without animation, only the step's content cross-fades on later changes (`.id(step)` and an opacity transition), and the code step has one layout from the start: a blank tile and "Making a code…" until the code arrives, instead of a spinner row the QR code replaced (`after-sheet-open-2`: a still, empty sheet for 200 ms, then the step at its final size). The Welcome Tour animated its whole sheet on `page` the same way; only the page cross-fades now. No other Mac sheet or popover animates a container; the SSH Undo bar's animation is scoped to the bar.

**Menus, top-level items before → after.**

| Menu | Before | After |
|---|---|---|
| A shown terminal's context menu | 8 (Stop Typing, Leave, Continue on Another Device…, Stop Sharing, Keep Private, Pause Remote Typing, Rename…, End Terminal…) | 6 (Stop Typing, Leave, Open On ▸, Sharing ▸, Rename…, End Terminal…) |
| Toolbar More | 7 | 5 (Stop Typing, Leave, Rename…, Sharing ▸, End Terminal…) |
| Terminal menu, the selected terminal's part | 6 | 7 (adds Open On ▸; Keep Private and Stop Sharing join Pause Remote Typing in Sharing ▸, ⇧⌘P still works) |
| File | 4 (Continue on Another Device…) | 4 (Open On ▸, or Pair a Device… without a terminal) |
| SSH host context menu | 5 | 5, reordered: Connect or Disconnect first, Delete Host… last; no submenu needed at five |

| # | Principle | Change | Main code |
|---|---|---|---|
| 1 | Recognition, efficiency | **Open On ▸** replaces Continue on Another Device… in File, Terminal, and the row's context menu: Choose a Device… (⌥⌘P, the sheet's device step), each paired device by name, New Device…, Someone Else…. A paired device skips the device step: straight to Open when it can already open the terminal, or to its Allow when access must widen. The toolbar button stays icon-only ("Open on another device"); the sheet's caption is "Open “*name*” on Another Device"; its code screens say "On the other device, choose Add Device." | [WitermApp](../../apps/apple/Sources/WitermApp.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift) |
| 2 | Aesthetic and minimal design | **Sharing ▸** holds Keep Private, Pause Remote Typing (checked while on), and Stop Sharing, in the context menu, More, and Terminal. | [WitermApp](../../apps/apple/Sources/WitermApp.swift), [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift) |
| 3 | Visibility of status | The service now tells a paired device who else can type in each terminal (`writers`: other devices by name, this Mac as `{}`, never the device itself; nothing for an invitation's guest), so the iPhone can say "Typing on *device*". | [AgentBroker](../../apps/mac-agent/Sources/WitermAgent/AgentBroker.swift), [remote-access-v1.json](../../protocol/fixtures/remote-access-v1.json) |
| 4 | Visibility of status | A device that unpairs itself leaves the Mac within 10 seconds while the app is active (the paired list is rechecked then, and at once when the app becomes active): Open On ▸, the Continue sheet, and Settings → Devices drop it, an open Edit sheet for it closes, and VoiceOver says "*device* unpaired". Its terminal leaves "Typing on …" within 2 seconds of its attachment closing. | [MacPairedDevices](../../apps/apple/Sources/Pairing/MacPairedDevices.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift) |
| 5 | Feedback, consistency | Sidebar rows (terminals, SSH hosts, New Terminal, Add SSH Host…) get a hover fill in the selection's shape, lighter than selection (6%, 12% with Increase Contrast), never on the selected row; the SSH host page's More menu gets the shared hover. | [Components](../../apps/apple/Sources/Design/Components.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [SSHHostDetail](../../apps/apple/Sources/SSH/SSHHostDetail.swift) |
| 6 | Help | The Welcome Tour's third page is "Open on another device: Choose Open On ▸ and a device, or press ⌥⌘P." | [MacWelcomeTour](../../apps/apple/Sources/Onboarding/MacWelcomeTour.swift) |

**Hover and pointer, round 9.** Native and left as is (they highlight on press, not on hover): bordered and prominent buttons (New Terminal and Add SSH Host… in the empty state, Connect, Edit…, Settings' Check Now, Edit…, Manage Servers…, Copy, Install, the Continue sheet's footer and Copy Invitation, the tour's Skip and Next), toolbar items, segmented controls, switches, pop-up buttons, and menus. Custom and now hovering: sidebar rows and the two sidebar add rows, the sidebar footer, the SSH host page's More, the Continue sheet's choice cards, the tour's page dots, the SSH form's More Options and key cards, snippet rows, and file rows. Open On ▸ and Sharing ▸ are native menus.

**Still to evaluate:** the iPhone showing "Typing on *device*" from `writers` (the iOS side), a real phone unpairing itself while the Mac shows the Continue sheet, and the hover fill on a light appearance.

## Round 9: iOS

Three requests from the Round 8 review, on 2026-11-03: unpair from the iPhone, say who is typing, and a shorter name for the way in. Plus a review of the actions menus for submenus.

| # | Surface | Problem | Principle | Change | Main code |
|---|---|---|---|---|---|
| 1 | Device Details | A pairing could only be ended on the Mac; the phone had no way out. | User control and freedom | **Unpair…**, last and destructive, confirms with the device's name and what this iPhone loses ("…can no longer open its terminals. To use them again, pair again."). While the relay server is told it shows Unpairing… and locks the sheet; a terminal open from that device is left first, after the detach ACK. The device then leaves Terminals and Devices, with "Unpaired from *device*" shown for 4 s in Devices and spoken. Offline, the button is off and the footer says it needs a network connection; if the server isn't reached, the device stays listed and the footer says this iPhone already stopped opening its terminals, and to try again or unpair on the other device. | [RemoteModels](../../apps/apple/Sources/RemoteTerminal/RemoteModels.swift), [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift), [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift) |
| 2 | Watching, refusals, reconnects | "Another device is typing" never said which one. | Visibility of system status | From the Mac's `writers`: Watching · Typing on *device* in the title (the Mac by its paired name), Typing on *device* when Start Typing is refused, "Typing on *device*, so you're watching" after a reconnect, and Typing on *device* under a terminal in the device's list. While you watch a terminal you could type in, the list is fetched every 10 s (each list opens a relay tunnel, and the server allows a device 30 a minute), only on screen and in the foreground, backing off to 60 s on failures. Older Macs keep the general wording. | [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift) (`TypingElsewhere`), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 3 | The way in | "Continue from Another Device" was long and said nothing about pairing; instructions named the Mac's old command. | Recognition, consistency | **Add Device** in Devices, on the first-use screen, on the tour, and as the sheet's title. Instructions say "On the other device, choose Open On ▸ New Device" (camera note, not-an-invitation error, no-longer-paired recovery, tour). A device that shares no terminals says to choose Open On ▸ *this device's paired name*. | [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift), [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift), [IOSWelcomeTour](../../apps/apple/Sources/Onboarding/IOSWelcomeTour.swift) |
| 4 | Host actions menu | Add to Favorites / Remove from Favorites changed title without showing the state; Disconnect sat between ordinary items. | Visibility; error prevention | **Favorite** with a checkmark; Edit Host and Host Keys; then, after a divider, Disconnect and Delete Host. | [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift) |

**Submenus.** Reviewed every iOS actions menu; none was long enough for a submenu to help:

| Menu | Top-level items before | After | Why |
|---|---|---|---|
| Paired terminal (ellipsis) | 5: text size, Find, Terminal Display, Stop/Start Typing, Leave | 5, unchanged | Each is one tap. A submenu would hide Stop/Start Typing, the state switch, behind a second tap. |
| SSH terminal (ellipsis) | 6: text size, Find, SFTP Files, Port Forwarding, Terminal Display, Disconnect | 6, unchanged | SFTP Files and Port Forwarding are the reason to open this menu on an SSH host; grouping them saves one line and costs a tap. |
| SSH host (ellipsis) | 4, Favorite as a changing title, Disconnect second | 4, Favorite checkmarked, destructive items last | State shown; no submenu needed. |
| Terminal row (long press) | 1: Watch | 1 | — |
| Paired device row | no menu; info button | no menu; Unpair in Device Details | A destructive action one level down, with its confirmation. |

**Still to check with a Mac (joint run):** Typing on *device* in the title while watching (now asserted in `MacContinuityFlowTests`), Unpair from the iPhone against the real relay server (the Mac should drop the device), and a refused Start Typing naming who types.

## Round 11: Mac

The production pass from the [Mac audit](audit-mac.md), on the shared design system (`WitermTheme`, `WitermMetrics`, `WitermType`, `WitermSymbols`), on 2026-11-03. Before and after captures, in light (through the DEBUG-only `-witerm.debug.appearance` hook), dark and Chinese, are in `.build/screenshots/audit-mac/` (`live/` before, `after/` after).

| Area | Before | After |
|---|---|---|
| Sheet actions | Five patterns: large capsules, a glass bottom bar plus a toolbar Cancel, toolbar roles, inline, full-width | One `SheetScaffold`: destructive and secondary leading, Cancel (Esc) and the primary (Return, except trust decisions) trailing, regular size |
| Mac sheet sizes | 7 sizes for Mac-owned sheets | 3 widths (400, 520, 600); forms fit their content, multi-step flows keep one height |
| Literal design values in Mac-owned files (distinct) | spacing 14, padding 13, radii 6, fonts 17 | spacing 1 (`0`), padding 0, radii 0, fonts 1 (the tour's 44 pt symbol); 193 token uses |
| Fixed-height Forms in sheets | 6 | 0 (group boxes with their own height) |
| Switches in Settings | Grey-on-dark ink tint in Devices, green elsewhere | System accent everywhere |

| # | Finding | Change | Main code |
|---|---|---|---|
| 1 | M-01 | The scannable image is the **QR code** (Show QR Code, Making a QR code…, step QR Code); **code** is only the compared fingerprint. | [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift) |
| 2 | M-02 | The sidebar footer is a button that selects Devices and then opens Settings, so VoiceOver and Full Keyboard Access land on Devices too. | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift) |
| 3 | M-03, M-05, M-13, M-20, M-27 | `SheetScaffold` for the Open On ▸ sheet, the device Edit sheet, Relay Servers, Rename, the Welcome Tour, the SSH trust sheet and SFTP; the SSH form keeps one footer. Esc cancels and never rejects; Reject has no shortcut. The first step's title names the terminal, without a separate caption. | [SheetScaffold](../../apps/apple/Sources/Design/SheetScaffold.swift) |
| 4 | M-04 | A Mac trust sheet: the key to compare, Cancel (Esc) and Trust and Connect trailing, no Return. | [MacSSHTrustSheet](../../apps/apple/Sources/SSH/MacSSHTrustSheet.swift) |
| 5 | M-06 | No app tint on Settings or system controls in sheets; Mac switches use the system accent. | [MacSettingsView](../../apps/apple/Sources/Server/MacSettingsView.swift), [SelectableCard](../../apps/apple/Sources/Design/SelectableCard.swift) |
| 6 | M-07 | The footer says Offline without a network, and "Can't reach the relay server" after 10 s of Connecting…; Settings → Devices and the Open On ▸ sheet show the offline banner. | [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift) |
| 7 | M-08 | Approve offers "Also unpair the older “*name*”" (on by default) for a pairing with a device of the same name and kind; older pairings end only after the approval succeeds. The same identity's grant still ends first (the server allows one per pair), and if approving then fails it says so: Pairing Not Replaced, show a new QR code. | [DevicePairingModel](../../apps/apple/Sources/Pairing/DevicePairingModel.swift) |
| 8 | M-09 | SFTP on the Mac: a table with selection, double-click to open a folder or download a file, a context menu (Open, Download, Delete…), drag out to Finder, drop in to upload, and a breadcrumb. Same rules: one transfer at a time, cancellable, private temporary folder, never recursive, delete confirmed. | [MacSFTPBrowser](../../apps/apple/Sources/SSH/MacSFTPBrowser.swift) |
| 9 | M-38 | After Stop Typing or Start Typing, this window's earlier attachment is never counted as "Typing in another window" while the listing catches up. | [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 10 | M-15, M-16 | Tour dots: the current page filled, the others outlined in the secondary ink (3:1 or more); its buttons keep focus rings. `SelectableCard` replaces both choice cards: selected fill and 1.5 pt border, hover never on the selected card, the `.isSelected` trait. | [MacWelcomeTour](../../apps/apple/Sources/Onboarding/MacWelcomeTour.swift), [SelectableCard](../../apps/apple/Sources/Design/SelectableCard.swift) |
| 11 | M-21, M-22, M-23, M-31, M-41 | The SSH host page has Connect, Edit… and More in one row under the window title. Disconnect asks first only when the last line isn't a prompt, and a chosen Disconnect returns to the plain page. Favorite is a checkmark, and tooltips say what happens. | [SSHHostDetail](../../apps/apple/Sources/SSH/SSHHostDetail.swift) |
| 12 | M-17, M-18, M-19, M-24, M-25, M-26, M-39, M-40 | Sentence case for toggles; 远程访问 for remote access; "relay server", never "server" alone; no repeated Relay Server header; distinct Settings tab icons; the link symbol for pairing; a separate `step.open` key (打开); new terminals numbered across both languages. | [round11-strings-mac.json](round11-strings-mac.json) |

**Not changed:**
- **M-29.** More Options stays a custom disclosure row, because the shared form's tests click it by identifier. Its animation now follows Reduce Motion (M-28).
- **M-26 (part).** Add SSH Host keeps `network`, because `terminal` is New Terminal's symbol in the same + menu.
- **M-32.** Settings stays one 640 × 600 size, by decision.
- **M-33.** Increase Contrast borders need a token in `WitermTheme`.
- **M-34 (part).** The offline banner, the Import introduction and the snippets footer are shared iOS text.
- **M-35.** Ask Siri is the system's.
- **M-37.** SSH errors are shared model strings.
- **Shared toolbar sheets.** The snippet editor, Import, the relay server address, Host Keys and Port Forwarding keep the system's toolbar placements, which macOS draws as bottom-trailing buttons.

**Verification:**
- **Unit tests:** `WitermMacTerminalTests` (29, with the new `MacProductionPassTests` for M-38, M-40 and when Disconnect asks).
- **On this round's signed build:** `LocalSessionFlowTests`, `ContinueFlowTests.testContinueSheetStartsAtTheFirstUnfinishedStep`, `SSHConfigurationTests`, both `SSHHostFlowTests` (disposable OpenSSH fixture), both `WelcomeTourTests` (English and Chinese), and `AuditScreenshotTests` (light, dark and Chinese) pass.
- **iOS:** builds (`CODE_SIGNING_ALLOWED=NO`).
- **Not run:** `SSHHostManagementTests`, which needs a trusted host left by an earlier native run.
- **Not reachable:** the Approve and device Edit sheets. No device is paired with the relay server, and pairing one needs a phone (the joint run).

## Round 11: iOS

The production pass from the [iOS audit](audit-ios.md), on the shared design system, plus Face ID for saved SSH credentials (the user's decision on F-33), on 2026-11-03. Before and after captures are in `.build/screenshots/audit-ios` (before), `round11-ios/before/ipad-*`, and `round11-ios/after/*`, from the opt-in `AuditScreenshotTests` on the iPhone 18 Pro and iPad Air 11-inch (M4) simulators, one at a time.

| Area | Before | After |
|---|---|---|
| Literal design values in iOS-only files (distinct) | spacing 14, padding 12, radii 4, fonts 14 | spacing 7, padding 6, radii 4, fonts 13, all on the token scale; the only literals left are the 56 pt tour symbol and the rows' chevron size |
| Literal design values in all iOS-compiled code | spacing 15, padding 15, radii 7, fonts 23 | spacing 9, padding 8, radii 6, fonts 22; the rest belong to Mac-shared code the Mac crew owns (key cards, SFTP) |
| Page backgrounds | Canvas on lists, system grouped on forms and sheets | System grouped everywhere (the shared token) |
| A device paired twice | Two rows; Unpair on one removed both | One row per device and relay server, with its widest access |
| Saved SSH credentials | Keychain, readable while unlocked | Face ID, Touch ID or the passcode for every read, once per attempt for every hop |

| # | Findings | Change | Main code |
|---|---|---|---|
| 1 | F-01 | `RemoteTerminalModel.devices` lists one grant per device (control beats view, then newest); Terminals and Devices use it. Unpair already ends every pairing with the device on that server. | [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift), [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift) |
| 2 | F-02, F-03 | The system Paste button gets a graphite fill that keeps its white label above 7:1 in both appearances; Positive is #157043 (lead). | [ContinueFromDeviceFlow](../../apps/apple/Sources/Continuity/ContinueFromDeviceFlow.swift) |
| 3 | F-04 | Each key says its face to Voice Control first ("Ctrl", "Ctrl C"), then its name; keys show the Large Content Viewer. | [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift) |
| 4 | F-05 | `ContentActionLabel`: in-content actions carry a leading symbol and the semibold weight on iOS (the Mac keeps a plain title). | [Components](../../apps/apple/Sources/Design/Components.swift) |
| 5 | F-06, F-12, F-32 | The terminal keeps 6 pt (or the safe area) from each side edge; a Jump to Latest button appears while scrolled back and says when new output arrived; pinching scales live and shows the size it will set. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift) |
| 6 | F-07 | A device row in Devices opens the device's page there: Show Terminals, Access, relay server, code, Unpair…. The ⓘ and the tab jump are gone. | [RemoteModels](../../apps/apple/Sources/RemoteTerminal/RemoteModels.swift) |
| 7 | F-08 | Verified on the iPad: two "Terminals" titles from a split view inside a stack. The split view is now the tab's root on regular width; SSH and paired terminals open in its detail column beside the list, and the tab bar stays. | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |
| 8 | F-09 | iOS lists Find in Terminal (⌘F), Stop/Start Typing (⇧⌘T), Leave and Disconnect in the Terminal menu while ⌘ is held. | [WitermApp](../../apps/apple/Sources/WitermApp.swift) |
| 9 | F-10, F-11, F-20, F-46 | The relay-server sheet says Add or Save (the title fits), focuses its field, and opens full height at accessibility sizes; the server row wraps the name there. The SSH form focuses the address, and at accessibility sizes its actions end the form instead of covering it. | [ServerViews](../../apps/apple/Sources/Server/ServerViews.swift), [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 10 | F-13 | The key row's Paste is the system Paste control, and the edit menu uses the system Paste command, so iOS doesn't ask "Allow Paste?". | [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift) |
| 11 | F-14, F-18, F-19, F-40, F-41 | First use is one list section with neutral tiles (no emblem, no machine hues); a device's terminals are a list with swipe-to-watch; the Terminals section has no title. | [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 12 | F-47, F-48 | Addresses in rows break only between characters, never with a hyphen (`AddressText`); a host named after its address doesn't repeat it. | [Components](../../apps/apple/Sources/Design/Components.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |
| 13 | F-52, F-16 | Terminal text follows Dynamic Type up to xxxLarge; Text and Colors previews the size the terminal really uses. | [TerminalFindBar](../../apps/apple/Sources/RemoteTerminal/TerminalFindBar.swift), [TerminalAppearanceSettings](../../apps/apple/Sources/Design/TerminalAppearanceSettings.swift) |
| 14 | F-17, F-34, F-35, F-28 | Inline titles in every sheet; detents per the audit's table; Snippets without a repeated header or an empty Edit; the find bar stacks at accessibility sizes; Keyboard Row uses checkmarks and an Edit button instead of permanent delete controls. | several |
| 15 | F-21, F-22, F-24, F-25, F-27, F-29, F-30, F-37, F-43, F-50 | Relay server, not server alone (iOS strings); "Requesting access adds this relay server"; Add SSH Host… everywhere; title-case iOS settings labels (the Mac keeps sentence case); Dismiss; Disconnected; fewer always-visible hints; "touch and hold to select"; the device page shows the server's name; QR code for the scannable image. | [round11-strings-ios.json](round11-strings-ios.json) |
| 16 | F-26, F-38, F-44, F-45, F-51 | Swipe actions on host rows (Favorite; Disconnect or Delete Host); haptics for the typing switch, Ctrl and unpairing; the Unpaired note stays until you leave the tab; the preview has an edge; the keyboard button comes before the actions menu on SSH terminals too. | several |
| 17 | F-33 | Saved credentials use `.userPresence` access control, when-passcode-set, this device only, never synced, and a marker attribute so the app asks even where the Keychain doesn't enforce access control (the simulator). Connecting asks once per attempt for every hop; cancelling opens the form for that attempt and keeps what's saved. One line under the switch names what protects them; without a passcode the switch is off. Older items gain protection on their next successful connection; Undo after Delete restores them without reading them. | [SSHStorage](../../packages/WitermSSH/Sources/WitermSSH/SSHStorage.swift), [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift), [SSH](../ssh.md#credentials) |

**Not changed:** F-31 (key cards, the Mac crew's `SelectableCard`), F-42 (the selection color is SwiftTerm's), F-39 for row heights (tiles scale; rows follow the system), F-09's paired terminals in ⌘1–9 and Find Next/Previous, and F-21's shared `ConnectionFeedback` wording (Mac-shared).

**Verification (iPhone 18 Pro, then iPad Air 11-inch (M4), never both booted):** see [audit-ios.md](audit-ios.md#phase-2-status).

## Round 12: iOS

Further production work on 2026-11-03: the Round 11 leftovers, a second review of the Round 11 captures (`.build/screenshots/round11-ios/after/`), the terminal measured against the disposable OpenSSH fixture, and the Face ID edge cases. Roles: **VD** visual and layout designer, **PS** iOS HIG specialist, **AX** accessibility specialist, **IX** interaction designer, **UW** UX writer, **PE** performance engineer, **QA**.

**Terminal numbers** (iPhone 18 Pro simulator, Debug, fixture on loopback). The live numbers come from the opt-in `TerminalPerformanceTests`, the renderer's from `TerminalThroughputTests`. Before is `main` at 65fe241 with only the measuring probe added; each cell gives the runs' range.

| Measure | Before | After |
|---|---|---|
| `seq 1 100000`, first to last output delivered to the renderer | 0.44–0.46 s (about 220,000 lines/s) when it finished; **1 run in 4 ended the session** with "The connection could not keep up" | 0.43–0.44 s (about 230,000 lines/s); 3 of 3 runs complete, plus 300,000 lines read 2 s late in the SSH acceptance |
| Renderer alone, 100,000 lines in 32 KiB batches (feed, reading page, one frame per batch) | 499–507 ms | 510 ms (unchanged: the renderer wasn't the problem) |
| Memory after `seq 1 100000`, from connected | 74.9 → 73.8 MB; 73.2 → 68.5 MB (bounded scrollback, no growth) | 73.1 → 68.4 MB; 71.8 → 68.7 MB; 70.7 → 68.4 MB |
| One scroll step through scrollback (offset, layout, reading page, draw) | 4.0–4.3 ms mean, 6.6–7.6 ms worst (3.6 ms of it drawing) | 4.05 ms mean, 7.5 ms worst (3.6 ms drawing; the new selection colors cost nothing) |
| Approving a new host's key → typeable (keyboard up, prompt on screen) | 0.79–1.12 s | 1.05–1.46 s (the same code path; within the simulator's spread) |
| Connect in the form → typeable, known host | 0.54–0.67 s | 0.65–0.83 s |
| Jump to Latest → prompt | 0.11–0.24 s | 0.09–0.10 s |
| Keyboard shown → prompt above the key row / hidden → the same frame (worst of 5 each) | 0.33–0.42 s / 0.09–0.15 s | 0.27–0.43 s / 0.09–0.10 s |
| Rotation to landscape | 0.08–0.10 s; grid 45×23 → 85×5 → 45×23 | 0.08–0.29 s; same grids |

Times measured by the UI test include its polling (about 50 ms) and the keyboard's animation. The simulator reports no hitch ratio for scrolling, only the deceleration's duration (2.43 s), so smoothness is judged by the per-step cost: about 4 ms on the main thread, half of a 120 Hz frame.

| # | Role | Finding | Change | Main code |
|---|---|---|---|---|
| 1 | PE, QA | **P0.** Long output sometimes ended the SSH session. The shell's output stream held 64 chunks of 8 KiB, and one socket read carrying more (several SSH packets at loopback speed) dropped output and closed the connection with "could not keep up". | The stream counts bytes, not chunks. Past 1 MiB unread, the SSH channel stops reading and NIOSSH stops widening the window, so the host waits; reading resumes under 256 KiB. The renderer's drain also waits while the main thread is 1 MiB behind, instead of failing. Nothing is dropped. | [SSHShell](../../packages/WitermSSH/Sources/WitermSSH/SSHShell.swift), [SSHNativeTerminalView](../../apps/apple/Sources/SSH/SSHNativeTerminalView.swift) |
| 2 | IX, VD | After a long press the selection's handles were drawn but couldn't be dragged (a drag scrolled); after a double tap SwiftTerm's own drag moved the selection's end from anywhere. Selected text was teal with black text, the handles system blue (F-42). | A drag that starts on a handle moves that end (a selection tick, then the edit menu again); anywhere else a drag scrolls. The highlight is the app tint at 28% (40% with Increase Contrast) behind text that keeps its color; handles are the tint. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift) |
| 3 | PS | F-09: ⌘1–⌘9 listed only SSH hosts, and there was no Find Next or Previous. | The Terminal menu lists the paired device's terminals, then connected SSH hosts, for ⌘1–⌘9 and ⇧⌘] / ⇧⌘[ (a paired one switches through detach-then-attach). Find Next (⌘G) and Find Previous (⇧⌘G) move between matches and open the find bar when it's closed. | [WitermApp](../../apps/apple/Sources/WitermApp.swift) (iOS hunk), [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [TerminalFindBar](../../apps/apple/Sources/RemoteTerminal/TerminalFindBar.swift) |
| 4 | IX, VD | With the keyboard up, Add SSH Host showed about two rows between the navigation bar and the pinned Connect and Save for Later; the protection line under Save Credentials sat under them. | Save (without connecting) moves to the sheet's navigation bar, where iOS keeps Save; the bar over the keyboard holds Connect only. The Mac footer keeps Save for Later. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) (iOS hunks) |
| 5 | AX | The Host chip truncated at the default size ("build.e…ple.invalid") and hyphenated at AX5 ("build.exam- / ple.invalid"); relay-server error sentences could break `localhost:37429` like a word. A hyphen is a legal host-name character (F-47). | Chips flow like words onto as many lines as they need; one longer than a line breaks only between characters. A relay server's name inside an error sentence breaks between characters, never with a hyphen; VoiceOver reads the plain sentence. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift), [ConnectionModel](../../apps/apple/Sources/ConnectionModel.swift), [Components](../../apps/apple/Sources/Design/Components.swift) |
| 6 | AX, UW | A failed check was announced as "Title。Recovery" in English too: a Chinese full stop in code. | One localized "%@. %@" ("%1$@。%2$@" in Chinese). | [ServerViews](../../apps/apple/Sources/Server/ServerViews.swift) |
| 7 | UW | F-21 in shared models: "Server Not Found", "The server is reachable", "Invitation From Another Server", "Check with your server administrator", "Disconnect another SSH session…", "The SSH session has ended", "Check the terminal service…". | Relay server wherever the Witerm server is meant (check results, pairing errors, the list's limits); "the host's administrator" for SSH; "Up to 8 SSH hosts can be connected at once"; "The SSH connection ended"; "check that Terminals is on in Settings". | [ConnectionModel](../../apps/apple/Sources/ConnectionModel.swift), [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift), [DevicePairingModel](../../apps/apple/Sources/Pairing/DevicePairingModel.swift), [ServerList](../../apps/apple/Sources/Server/ServerList.swift), [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift) |
| 8 | UW | F-30: the RSA line was always under the key cards; the jump-host note showed without jump hosts; a disconnected host said "Reconnect to open a new SSH shell. Whether previous programs keep running depends on the remote host." (19 words); the idle check said "Check the server connection when you are ready." | The RSA warning appears beside the key as soon as an RSA key is in the field; the jump-host note only with jump hosts; "Reconnecting opens a new shell." (4 words); "Not checked yet."; "Reachable". New Key says "Add its public key to the SSH host." | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift), [ServerViews](../../apps/apple/Sources/Server/ServerViews.swift), [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift) |
| 9 | VD, AX | Cards, badges, chips, the invitation field, the code tile, the tour's tiles and the key row's keys had no edge with Increase Contrast. | `witermOutline` applies `WitermTheme.outline(increasedContrast:)` to each; `witermCard` uses it on iOS (the Mac keeps its hairline); the keys get the same line in UIKit and follow the setting live. | [Components](../../apps/apple/Sources/Design/Components.swift), [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift) |
| 10 | AX | At AX5 the Password / Private Key segmented control kept its small text. | A menu picker at accessibility sizes. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 11 | IX, security | Face ID declined at its first prompt (or turned off for Witerm, or no longer enrolled) ended the attempt with "Unable to access secure storage on this device. Try again later.", which retrying didn't fix; with Face ID off, the line said only "Your passcode protects them." | The same attempt continues with the passcode, and cancelling it is a quiet cancel. A removed passcode (the system deletes saved items with it) offers the password for the attempt. The line says "Your passcode protects them. Face ID is off for Witerm in Settings." The storage rules are unchanged: `.userPresence`, when-passcode-set, this device only, never synced, no file fallback. | [SSHStorage](../../packages/WitermSSH/Sources/WitermSSH/SSHStorage.swift), [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 12 | UW | Deleting any host said "Deleted *name* and its saved credentials." | It says so only when a hop had saved credentials (read from attributes, without a prompt). | [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |
| 13 | UW, PS | On iPad before anything was saved, the detail column said "Choose a Terminal" with nothing to choose. | "No Terminal Open" until a host is saved, then "Choose a Terminal". | [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) (iOS) |
| 14 | QA, IX | With the keyboard up and More Options open, the form couldn't scroll Name and Add Jump Host out from under the pinned Connect bar (its scroll range left the bar out), so a tap meant for Name pressed Connect. | The form's scroll content gets a bottom margin of the bar's measured height. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) (iOS) |
| 15 | PS, QA | Build warnings in our code: `UIDevice.current.name` read off the main actor, an inconsistent `weak self` in the SFTP progress sampler, and "All interface orientations must be supported" for iPad. | The device name is read on the main actor; the sampler captures `self` like the task around it; iPad declares all four orientations (iPhone keeps three), so multitasking and Stage Manager work. A clean WitermiOS build has no warnings from `apps/apple/Sources` (all remaining ones are in vendored Citadel). | [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift), [SSHFilesView](../../apps/apple/Sources/SSH/SSHFilesView.swift), [Info.plist](../../apps/apple/Config/Info.plist) |

**Face ID with many saved hosts.** Each connection asks once for all of its hops. Knowing which hosts have saved credentials reads attributes only, once per tap, so a long list never prompts or slows. Deleting and undoing never reads a credential.

**Reviewed, not changed:**

- F-23's full-width Paste (the system Paste control keeps its own size), F-31 (the Mac crew's key cards), and F-39's row heights (the system's).
- In landscape on iPhone with the keyboard up, the terminal has 5 rows (85 × 5); the navigation bar, key row and keyboard take the rest. Hiding the navigation bar while typing in landscape would give back about two rows. A decision for the lead.
- After Connect, iOS offers "Save Password?" for the password field (into Passwords, which syncs), over the host-key sheet. Suppressing it would also remove AutoFill from Passwords. A decision for the lead.
- The renderer draws with Core Graphics (3.6 ms per full frame here). SwiftTerm's Metal renderer wasn't adopted, because selection, the reading page and handles would all need verifying again; a check on the physical iPhone decides whether it's needed.
- Haptics: success and error on connect, pairing and server checks; a selection tick on the typing switch, Ctrl, a long press and now a handle drag; a light impact at the pinch's limits. Consistent.
- Swipe actions and context menus: host rows (Favorite; Disconnect or Delete Host) and a device's terminals (Watch). Paired devices keep Unpair on their page, behind its confirmation.
- Real VoiceOver speech, Voice Control and Full Keyboard Access were reviewed from code and labels, not by ear.

**Verification:** see [verification.md](../verification.md), Round 12: iOS.

## Round 12: Mac

Further production work on 2026-11-03: the Round 11 leftovers, a second review of the Round 11 after-captures and new captures of the installed build, responsiveness measured before and after, and test coverage for the device Edit sheet and the Approve step without a phone. Captures are in `.build/screenshots/audit-mac/round12/` (`before/` is the installed build, `after/` this round's, each in English light, English dark and Chinese), and the fixture tests' pictures in `.build/screenshots/round12-mac/`. The `after/` pass stops at the snippet editor: Esc didn't close it (fixed, see Keyboard below), so the Settings, SSH and sheet pictures after it are missing; the re-run was stopped because the Mac was in use.

| # | Role | Finding | Change | Main code |
|---|---|---|---|---|
| 1 | PS, VD | The snippet editor, Import SSH Hosts, the relay server address, Host Keys and Port Forwarding used toolbar placements: a title indented in a toolbar band away from the content, a system-blue Done, and fixed minimum heights (Host Keys 420 pt, about 60% blank; Port Forwarding 580 pt). | `SheetScaffold` on the Mac, iOS unchanged: title, content in group boxes, a divider, then destructive and secondary actions leading and Cancel and the primary trailing, each sheet as tall as its content. | [SnippetSettings](../../apps/apple/Sources/Snippets/SnippetSettings.swift), [SSHConfigImportView](../../apps/apple/Sources/SSH/SSHConfigImportView.swift), [ServerAddressSheet](../../apps/apple/Sources/Server/ServerAddressSheet.swift), [SSHHostKeysView](../../apps/apple/Sources/SSH/SSHHostKeysView.swift), [SSHForwardingView](../../apps/apple/Sources/SSH/SSHForwardingView.swift) |
| 2 | IxD | In Port Forwarding, Return in a port field pressed Done and closed the sheet without starting the forward. | Start Forwarding is the sheet's primary (Return); Done is Esc. The fields sit in a two-column grid with trailing labels, and the direction is a segmented control. | [SSHForwardingView](../../apps/apple/Sources/SSH/SSHForwardingView.swift) |
| 3 | UXW, PS | Import SSH Hosts opened with a 29-word paragraph and its two buttons inside the content. | One line ("Keys and passwords aren’t imported."); Choose File… leading, Cancel and Read ~/.ssh/config trailing; hosts are checkboxes. | [SSHConfigImportView](../../apps/apple/Sources/SSH/SSHConfigImportView.swift) |
| 4 | PS, UXW | The snippet editor had a switch titled "Press Return After Inserting" and a footer paragraph. | A checkbox in sentence case, the explanation as its tooltip, Delete Snippet in the footer. | [SnippetSettings](../../apps/apple/Sources/Snippets/SnippetSettings.swift) |
| 5 | A11Y (M-33) | Increase Contrast doubled hover fills, but cards, choice cards and code tiles kept faint or no edges. | `witermOutline`: `WitermTheme.outline(increasedContrast:)` at 1.5 pt with Increase Contrast, on `SelectableCard`, the QR tile and its blank stand-in, the codes on Approve and invitations, the Open step's checklist, the SFTP table, the snippet field and the tmux command. | [SelectableCard](../../apps/apple/Sources/Design/SelectableCard.swift) |
| 6 | VD | The blank QR stand-in (16 pt corners) and the QR tile (14 pt) changed shape when the code arrived. | Both use `Radius.xl`. | [PairingQRCode](../../apps/apple/Sources/Pairing/PairingQRCode.swift) |
| 7 | UXR, IxD (M-08) | Two pairings with one name (a device set up again, older pairing kept) looked like one device listed twice. | Their rows say "Paired *date*" in Settings → Devices and on the Open On sheet's device step, and Settings lists devices by name, oldest pairing first, so the two sit together. The Edit sheet's code fills its row like the groups above it. | [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift), [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift) |
| 8 | PS | Find, Find Next, Find Previous and Use Selection for Find sat at the top of Edit. | Edit ▸ Find ▸, as in every Mac app; the shortcuts are unchanged. | [WitermApp](../../apps/apple/Sources/WitermApp.swift) |
| 9 | PS | The menu bar had no command for a selected SSH host; Connect, SFTP Files, Port Forwarding and Disconnect needed the pointer or Full Keyboard Access in the toolbar. | Terminal menu: Connect, or SFTP Files…, Port Forwarding… and Disconnect (which asks first while a program runs, like the toolbar). | [WitermApp](../../apps/apple/Sources/WitermApp.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift) |
| 10 | IxD | Right-clicking terminal text did nothing. | Copy (with a selection), Paste (only while typing), Select All, and Find…, for Mac and SSH terminals. | [MacTerminalTextView](../../apps/apple/Sources/TerminalAccessibility/MacTerminalTextView.swift) |
| 11 | IxD | Paired devices, relay servers, invitations had no context menu; snippets offered only Delete. | Devices: Edit…, Unpair… (confirmed). Relay servers: Edit…, Check Now, Remove…. Invitations: End Invitation. Snippets: Edit Snippet, Delete. | [MacDevicesView](../../apps/apple/Sources/Pairing/MacDevicesView.swift), [SnippetSettings](../../apps/apple/Sources/Snippets/SnippetSettings.swift) |
| 12 | IxD | Dropping a Finder file on a terminal did nothing; Terminal types its path. | A file dropped on a terminal you're typing in types its path, one shell word each (single-quoted when needed), and never presses Return; watching, the drop is refused. | [MacTerminalTextView](../../apps/apple/Sources/TerminalAccessibility/MacTerminalTextView.swift) |
| 13 | PS, VD | The SSH form's title sat in a toolbar band like the toolbar sheets. | On the Mac the title is in the content's inset, as in `SheetScaffold`. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 14 | UXW, QA | The step strip's last step read "step.open" in English: the catalog's English for that key is the key itself. | The strip uses `terminal.open` (Open, 打开); `step.open` can be removed from the catalog. | [ContinueOnDeviceSheet](../../apps/apple/Sources/Continuity/ContinueOnDeviceSheet.swift) |
| 15 | UXW, PS | A terminal interrupted by too much output said "Paste long text in smaller parts". | Output that outruns the window says so: "It printed faster than this window could show. Open it again; it kept running." Pastes keep their wording. Pair a Device's last step no longer repeats its subtitle as a note. | [NativeTerminalView](../../apps/apple/Sources/LocalTerminal/NativeTerminalView.swift), [LocalTerminalModel](../../apps/apple/Sources/LocalTerminal/LocalTerminalModel.swift) |
| 16 | QA | The device Edit sheet and Approve's "Also unpair the older…" had never been seen live. | A DEBUG-only pairing fixture (`-witerm.debug.pairingFixture 1`) and `DevicePairingFixtureTests`. | [MacPairingFixture](../../apps/apple/Sources/Pairing/MacPairingFixture.swift), [DevicePairingModel](../../apps/apple/Sources/Pairing/DevicePairingModel.swift) |

**Responsiveness (performance engineer), installed build before → this round's build.** From the opt-in `PerformanceTests` against each signed app, with the app's footprint and CPU sampled once a second outside the runner. XCTest times include its own polling (about 0.05 s); launch was also timed outside XCTest. No regression; nothing here needed a fix in the app's own code.

| Measure | Before | After |
|---|---|---|
| Launch to the first window on screen (Launch Services, no restored state, median of 7) | 0.47–0.50 s | 0.42 s |
| Launch to the first sidebar row, after the window (XCTest, 3 runs) | 0.17–0.30 s | 0.11–0.13 s |
| ⌘N to a focused terminal (mean of 5) | 0.34 s | 0.31 s |
| ⌘N to the first command's output (mean of 5) | 1.06 s | 1.01 s |
| 16 terminals: relaunch to the rows listed | 2.2 s | 2.0 s |
| 16 terminals: 32 row hovers, app CPU (XCTest metric, 3 runs) | 0.93 s (29 ms a hover) | 0.84 s (26 ms a hover) |
| 16 terminals: click a row to a focused terminal (mean) | 0.82 s | 0.82 s |
| Opening Rename, Open On, Add SSH Host, Import SSH Hosts, Welcome Tour, Settings (median of 3) | 0.06, 0.006, 0.06, 0.06, 0.03, 0.004 s | 0.06, 0.006, 0.06, 0.02, 0.01, 0.003 s |
| Opening Port Forwarding, Host Keys (toolbar and menu, with XCTest's idle wait) | 0.99, 1.70 s | 0.96, 1.85 s |
| SFTP: double-click a folder of 1,000 files to its first row (median of 3) | 2.8 s | 2.6 s |
| 360,000 lines, 100 every 50 ms (an hour of a busy log) | 244 s, not interrupted | 245 s, not interrupted |
| Footprint before, while printing, and settled after those lines | 92, ~190, 95 MB | 90–100, ~180, 90 MB |

**Found while measuring (not fixed here; for the lead):**
- **A burst of output interrupts a Mac terminal.** `seq 1 1000` keeps up; `seq 1 3600` (17 KB) ends the window's attachment with Terminal Interrupted, on both builds; a million lines never finish. The shell keeps running. The client's event stream holds 64 events and drops the attachment when it's full (`LocalTerminalStreams`, `bufferingOldest(64)`), and the service also ends a connection whose queue passes 256 KB (`AgentConnection.deliveryLimit`); neither waits for the reader, so many small tmux writes overflow the 64 events long before any byte limit. The fix belongs in WitermCore and the service: the socket reader should wait for room (counting bytes, not events), and the service should stop reading a pane while a connection's queue is full, so tmux coalesces the screen for a slow client instead of the window closing. This round only makes the window say what happened.
- **A full accessibility snapshot of the 1,000-file SFTP table** costs the app about 1 GB and 20–35 s of CPU (XCTest's snapshots after End). Listed and left alone, the same table sits at 96–100 MB and 0% CPU, so ordinary use is fine; VoiceOver over a large folder wasn't tried.
- **"Application performed a reentrant operation in its NSTableView delegate"** is logged at every launch of both builds (the sidebar list). No visible effect yet; AppKit says it will become an assert.

**Second pass, checked and kept (QA, PS, A11Y):**
- **Light and dark parity, Chinese.** The installed build's captures match Round 11's after-captures apart from row 15; the Settings strings that were English in Chinese at Round 11 are translated now. New strings this round show in English in Chinese until the catalog takes `round12-strings-mac.json`.
- **Keyboard.** Every Mac sheet now ends in the same footer, so Full Keyboard Access reaches the content first and then the footer, left to right; Esc closes every sheet whose Cancel only closes it (the snippet editor's text field had kept Esc from its Cancel button). Approve and Trust keep no Return.
- **VoiceOver headings.** Every sheet title is a heading; the group titles in Host Keys and Port Forwarding are too.
- **Menu shortcuts.** No conflicts: ⌘R Refresh and ⇧⌘R Rename, ⌘1–9 terminals and ⌥⌘1–9 snippets, ⇧⌘P and ⇧⌘T as noted in M-36.
- **Drag and drop.** Reordering terminals or SSH hosts by dragging was considered and left out: terminals are listed in the order they started (which ⌘1–⌘9 follows) and hosts are ordered favorites first, then by use, so a manual order would fight both. Files dropped on a terminal (row 12) and SFTP's drag in and out are the drags that save typing.

**Not changed:**
- **M-29** (More Options as `DisclosureGroup`) and **M-32** (one Settings size), by earlier decision.
- **M-33 for `witermCard` and `IssueBanner`.** Both are shared components outside the Mac hover block; they can use `witermOutline` the same way.
- **M-34 (part), M-37.** The offline banner, the snippets footer and SSH's "session" errors are shared iOS text.
- **M-35.** Ask Siri is the system's.
- The SSH form keeps its own grouped `Form` and footer bar; only its title moved.

**Verification:**
- `WitermMacTerminalTests` (33, with the new `MacRound12Tests`: dropped paths are one shell word each, the terminal's menu offers Paste only while typing, the Open step's title is a word, and "Paired *date*").
- On this round's signed build: `DevicePairingFixtureTests` (the Edit sheet; Approve with "Also unpair the older…" on, which leaves one Fixture iPhone; Approve with it off, which leaves two with their dates; and Approve in Chinese), `LocalSessionFlowTests.testRenameAndFindInFreshSession`, `ContinueFlowTests.testContinueSheetStartsAtTheFirstUnfinishedStep`, `SSHConfigurationTests.testSaveEditFavoriteAndSearchWithoutConnecting`, `SSHHostFlowTests.testCreateTrustConnectAndRemoveFixtureHost` (disposable OpenSSH fixture), both `WelcomeTourTests`, and `PerformanceTests`. `AuditScreenshotTests` (light, dark and Chinese) ran up to the snippet editor; after the Esc fix its re-run was cut short by another app coming to the front, and wasn't repeated while the Mac was in use.
- WitermiOS builds (`CODE_SIGNING_ALLOWED=NO`) with the shared-file changes.

## Round 13: iOS

Two decisions the lead took from Round 12's "Reviewed, not changed" list, on 2026-11-03, on the iPhone 18 Pro simulator against the disposable OpenSSH fixture. Captures are in `.build/screenshots/round13-ios/` (`before/`, `after/`, and the attempts `e2/`, `e2b/`, `e3/`); landscape captures come out in the portrait buffer, rotated.

| # | Finding | Change | Main code |
|---|---|---|---|
| 1 | After Connect, iOS offered "Save Password?" into Passwords, which syncs, over the host-key sheet (`before/offer-2.png`; twice in one run: a new host and its reconnect). SSH credentials stay on this device: in memory, or the protected Keychain after **Save Credentials on This Device**. | The password and passphrase fields are marked as one-time codes on iOS, the one kind iOS 27 leaves alone: no offer after Connect, a reconnect, Cancel, or a swipe down. Typing and pasting (the field's edit menu) still work. Passwords AutoFill no longer fills these fields, by design. Witerm's own Face ID–protected saving is unchanged. The Mac form keeps its password type. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) (`sshSecretInput`) |
| 2 | In landscape on iPhone with the keyboard up, the navigation bar (78 pt) took rows from a terminal that had five (85 × 5). | While the terminal has the keyboard in landscape, the bar steps aside. The key row then ends, pinned outside its scrolling keys, with Hide Keyboard and the bar's actions menu (the same items: text size, Find, SFTP Files, Port Forwarding, Terminal Display, Disconnect; or for a paired terminal Terminal Display, Stop or Start Typing, Leave). Hiding the keyboard, portrait, or the terminal losing focus brings the bar back with the back button, the title and the switcher. The bar stays while VoiceOver runs, in portrait, on iPad, and on regular widths. Paired-Mac and SSH terminals share it. | [TerminalFindBar](../../apps/apple/Sources/RemoteTerminal/TerminalFindBar.swift) (`TerminalTypingBar`), [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift), [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |

**Suppressing Save Password, what was tried** (`SSHTypingChromeTests.testConnectingDoesNotOfferToSaveThePassword`, offers counted and declined, never accepted):

| Attempt | New host | Reconnect | Cancel, swipe down |
|---|---|---|---|
| Before: `.textContentType(.password)` | offered | offered | not run |
| No content type | offered | offered | not run |
| No content type, fields emptied before the form closes | none | none | offered (a swipe down closes the sheet without the form's code) |
| `.textContentType(.oneTimeCode)` (kept) | none | none | none |

**Landscape numbers** (`SSHTypingChromeTests.testLandscapeTypingGivesTheTerminalTheBarsRows`, five hide-and-show cycles). This simulator shows only the key row for the keyboard, as with a hardware keyboard, and that couldn't be changed within this round's rules; so the keyboard-up grids are with the key row alone. With the software keyboard (Round 12: 85 × 5) the same 78 pt give four or five rows, about 85 × 9, not measured here.

| Measure | Before | After |
|---|---|---|
| Grid, keyboard (key row) up / down | 85 × 15 / 85 × 17 | 85 × 20 / 85 × 17 |
| Keyboard shown → typeable (and bar gone) | 0.24–0.30 s | 0.33–0.37 s, once 0.55 s |
| Keyboard hidden → gone (and bar back) | 0.03–0.05 s | 0.08–0.10 s |
| Grid changes per show / hide | 1 / 1 | 2 / 2: show 52–69 ms apart (the bar leaves, then the key row's inset arrives); hide 5–8 ms apart (one frame). Both within the SSH resize's 75 ms settling, so the host gets one window-size change. |
| Portrait with the key row up / after landscape | 45 × 41 / 45 × 13 | 45 × 41 / 45 × 13 |

Times include the test's polling (about 50 ms). The bar leaves when the terminal is about to take the keyboard (a new will-change focus notice, posted before the responder change) and returns when the keyboard has gone; first tries that followed focus after the change, or the keyboard's will-show notification (not posted for the key row alone), left 0.27–0.6 s between the two grids.

**Found, not changed:**

- Rotating with the key row up leaves the terminal's keyboard inset stale until the keyboard is next hidden or shown: in landscape the terminal runs 32 pt under the key row (85 × 22 instead of 85 × 20; before: 85 × 17 instead of 85 × 15), and back in portrait it's 13 rows tall with the rest of the screen empty (45 × 13 instead of 45 × 41), on the build before this round too. Round 12's rotation test checked only the columns.
- Larger or smaller text from either actions menu (the bar's in portrait too) changes the cell size at once, but the grid kept its columns and rows for the 5 s the test waited (85 × 22 with 18 pt rows, which no longer fit). The size is kept and applies fully at the next launch. Not checked on the build before this round; the font path wasn't changed.

**Verification:** see [verification.md](../verification.md), Round 13: iOS.

## Round 14: iOS layout

Two layout bugs Round 13 found, and the owner's "scrolling and zooming are not very smooth" on iPhone, on 2026-11-03, on the iPhone 18 Pro simulator against the disposable OpenSSH fixture. Paired-Mac and SSH terminals share the renderer (`RemoteNativeTerminalView.TerminalSurface`), so each fix covers both. The simulator stays in hardware-keyboard mode, so "keyboard up" means the key row alone; its display runs at 60 Hz. Captures: `.build/screenshots/round14-ios/` (`before/`, `after/`, `smooth-before/`, `smooth-baseline/`, `smooth-after/`).

| # | Finding | Root cause | Change | Main code |
|---|---|---|---|---|
| 1 | Rotating with the key row up kept the old orientation's keyboard space: landscape ran 32 pt under the key row (85 × 22 instead of 85 × 20), and back in portrait the terminal was 45 × 13 with the rest of the screen empty, until the keyboard next hid or showed. The host got the wrong size too (`stty size`: 13 45). | SwiftUI's keyboard avoidance. With only the key row up, iOS reports nothing when the device rotates; the last report (will-change-frame, will-hide and did-change-frame, all with the key row's frame) is in the old orientation's screen coordinates, and SwiftUI kept applying it: portrait's frame (y 822) lies off a landscape screen, so no inset; landscape's (y 350) on a portrait screen leaves 490 pt. UIKit's `keyboardLayoutGuide` was just as stale (its top at 350 in portrait). The key row's own frame was always right. | Terminals opt out of SwiftUI's keyboard avoidance; the surface measures the covered height itself (`TerminalKeyboardOverlap`) from where its key row is now, in the current screen coordinates, plus the last keyboard report only when it was made for the current screen size (another field's keyboard, such as the find bar's). It re-measures when the key row lays out or enters or leaves its window, on the keyboard's did-notifications, and in its own layout (rotation, the bar). While the key row's window hasn't rotated yet, or the key row slides away below the screen, the last value stands, so no grid for the old orientation flashes and the rows return together with the navigation bar. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift), [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 2 | Larger or Smaller text (either actions menu, ⌘+ and ⌘−, the size setting) changed the cells at once, but the grid kept its columns and rows (45 × 41 at 15 pt, where 41 × 39 fit), and the host was never told. | `updateFontSize` zeroes the terminal's frame so SwiftTerm's font setter can't resize (that path soft-resets the terminal, clearing modes such as application cursor keys), then layout gave the same frame back. SwiftTerm refits its grid in layout only when its size differs from its last layout's, so nothing refit. | A typing view lays the terminal out once at zero size, so the next layout fits whole cells of the new size through SwiftTerm's own resize path (no soft reset), which tells the host once (an SSH window change after its 75 ms settle; a paired resize request after 100 ms). A watched (view-only) or frozen grid keeps the Mac's columns and rows as before and only draws them at the new size. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift) (`updateFontSize`) |
| 3 | Pinch: each step quantized the scale to whole points (a 7 % jump per point at 14 pt), scaled about the view's center rather than the fingers, and asked for a full layout every step (10 steps: 12 layouts, 15 reading-page rebuilds). On lifting, the transform was dropped before the new font arrived through a SwiftUI round trip (font 9 ms, grid 21 ms later), so the old size showed in between. | The gesture handler called `setNeedsLayout` per step, and the size reached the view only through UserDefaults and SwiftUI. | The live scale is continuous (within 11–32 pt) and anchored where the pinch began; only the size readout moves (layout returns early while pinching). On lifting, the surface applies the whole-point size itself, under the scaled view, then drops the transform, saves the size, and lays out once (one reflow, one resize); SwiftUI's later update with the same size is a no-op. Reduce Motion keeps the readout without live scaling. | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift) (`pinchMoved`, `pinchEnded`) |
| 4 | Scrolling rebuilt the reading page (VoiceOver's text) on 0.84 of frames; a paired terminal also rebuilt it synchronously for every SwiftTerm `scrolled` and `rangeChanged` callback. | Every content-offset change asked for a refresh. | While a finger scrolls (or its fling coasts) and VoiceOver isn't running, the refresh waits until the scroll ends (0.01 per frame after); with VoiceOver running it follows every step as before. Paired terminals coalesce like SSH ones. The touch-scroll state is a flag of our own: asking `UIScrollView.isDecelerating` per output chunk walked the focus system (1.5 s of main thread over 3 million lines in the first version, found with Time Profiler). | [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift) |

**Layout numbers** (`SSHTypingChromeTests`).

| Measure | Before | After |
|---|---|---|
| Portrait, key row up / down | 45 × 41 / 45 × 42 | 45 × 41 / 45 × 42 |
| Landscape right after rotating (key row up) | 85 × 22, 32 pt under the key row | 85 × 20, ending on the key row (85 × 21 → 85 × 20 on the way, 35–45 ms apart) |
| Portrait again after landscape (key row up) | 45 × 13, 472 pt empty; host 13 45 | 45 × 41 (45 × 40 → 45 × 41, 29 ms apart); host 41 45 |
| Landscape hide → show, grids per change and their span (5 cycles) | show 2 in 52–69 ms, hide 2 in 5–8 ms (Round 13) | show 2 in 52–59 ms, hide 2 in 5–7 ms; the first hide is no longer special |
| Larger text, 14 → 15 pt | 45 × 41 kept for the 5 s waited | 41 × 39 within 0.45 s of the tap (the test's polling; the reflow is in the same layout pass), host `stty size` 39 41; back to 45 × 41 in 0.43–0.69 s |

The first fixed build measured the overlap as soon as the key row moved below the screen at hiding, 0.4 s before the keyboard said it had hidden and the bar came back, so a hide gave two grids 420 ms apart (two host resizes). Keeping the last value until the key row leaves its window fixed that (5–7 ms). A rule that let any newer "keyboard gone" report override a visible key row was tried and dropped: opening the actions menu posts such a report, and the terminal then ran under the key row.

**Smoothness numbers** (`SSHTypingChromeTests.testScrollingAndPinchStaySmooth`: three fast flings through `seq 1 100000`, a slow drag while `seq 1 3000000` streams, and a pinch to 1.5 ×). Frame pacing comes from the app's own display-link probe (DEBUG, layout probe only), which runs only from the first movement to 0.4 s after the last. The test doesn't query the app while it measures: each XCTest query snapshots the app's accessibility on the main thread, and the first measuring run, which polled, showed 2–5 hitches of 43–119 ms per gesture that were the test's own. "Before" for scrolling is this round's build with the deferral switched off (`smooth-baseline/`); "before" for the pinch is the build before the pinch change (`smooth-before/`).

| Measure | Before | After |
|---|---|---|
| Flings: frames, hitches (over 1.5 frames), worst frame | 530, 0, 16.7 ms | 532, 0, 16.7 ms |
| Flings: drawing per frame, mean / worst | 2.55 / 3.90 ms | 2.78 / 3.90 ms |
| Flings: reading-page rebuilds per frame | 0.84 | 0.01 |
| Drag during live output: hitches, worst frame, drawing | 0, 16.7 ms, 2.52 ms | 0, 16.7 ms, 2.66 ms |
| Renderer alone, one scroll step (`TerminalThroughputTests`): layout / reading / draw / total, worst | 0.16 / 0.24 / 3.6 / 4.0 ms, 6.9 ms | 0.17 / 0.25 / 3.6 / 4.0 ms, 6.8 ms (programmatic steps, so the deferral doesn't apply) |
| Pinch: layouts while the fingers move (10 steps) | 12, with 15 reading rebuilds | none (1 at lifting), 4 reading rebuilds (lifting) |
| Pinch: work per step | a full layout, about 1.5 ms | under 1 ms (transform and readout) |
| Pinch: lifting → new font / new grid | 9 / 21 ms, the old size shown in between | 1–2 / 10–12 ms, in the same pass |
| Pinch: the lifting frame | not measured cleanly (polled run) | one frame of 53–62 ms: 1–2 ms font, 4–5 ms saving the size (UserDefaults observers, the announcement), 15–18 ms the reflow at the new width (SwiftTerm rewraps the scrollback), the rest not attributed by the sampler (SwiftUI's update, XCTest's accessibility client) |

Time Profiler (`xctrace record --template 'Time Profiler' --device <simulator> --attach <pid>`, 160 s over the same test, `.build/r14-smooth.trace`): of 40.8 s on the main thread, 14.5 s was SwiftTerm parsing the 3.1 million lines of output (`Terminal.feed` → `EscapeSequenceParser.parse`, 8.3 s of it in `Terminal.scroll`), 10.7 s XCTest's own queries and logging, 4.6 s Core Animation commits, 1.7 s drawing (`drawTerminalContents`), 1.0 s SwiftUI rendering. Nothing else of ours showed per frame once the reading page waited; the once-a-second activity update and the paired writers poll (every 10 s, only while watching) didn't register.

**What's left, with numbers.** Drawing is now the per-frame cost while scrolling: SwiftTerm's Core Graphics renderer redraws the whole visible grid on every content-offset change, 2.5–2.8 ms a frame here (4.0 ms worst; 3.6 ms in the renderer test). That fits the simulator's 16.7 ms frames with no hitches, and an 8.3 ms ProMotion frame, but uses a third to a half of it. Not switched to the Metal renderer, as asked; a measurement on the iPhone 17 Pro decides. Expected to differ on a 120 Hz device: the budget halves, so the same draw cost is a larger share; hitches there would show first in full-speed flings and at the pinch's lifting frame (the reflow alone is about two 120 Hz frames). Heavy output is still parsed on the main thread (about 4.7 µs a line here).

**Reviewed, not changed:** the find bar's software keyboard after rotation (its keyboard posts its own reports; not reproducible in hardware-keyboard mode), an undocked iPad keyboard with the key row (covered by the overlap's rule and a unit test, not run), and the pinch's lifting frame (the reflow is SwiftTerm's resize; a later round could rewrap the scrollback lazily).

**Verification:** see [verification.md](../verification.md), Round 14: iOS layout.

## Round 15: iOS selection and renderer trial

The owner's report "dragging now automatically selects text" on iPhone, and a trial of SwiftTerm's Metal renderer behind a DEBUG switch, on 2026-11-04, on the iPhone 18 Pro simulator against the disposable OpenSSH fixture. Paired-Mac and SSH terminals share the renderer (`RemoteNativeTerminalView.TerminalSurface`), so each fix covers both. Captures: `.build/screenshots/round15-ios/` (`r15-before*/` on the old gesture code with the new probe, `r15-after*/`).

### Part 1: dragging selected text

**The owner's case, confirmed: the Mac's tmux asked for the mouse.** The report came from the iPhone 17 Pro, in a paired-Mac terminal at a plain shell prompt, right after tapping into it ("once input mode is enabled, swiping starts selecting text; view-only scrolls smoothly"). The Mac service runs each session in its own tmux (`-f /dev/null`), and the phone draws that tmux client's output. tmux 3.6 and later default `mouse` to **on** even without a configuration file (this Mac has tmux 3.8: `show-options -g mouse` → `mouse on`), so on every attach, resize and re-attach the client sends `ESC[?1006h ESC[?1000h ESC[?1002h`, for viewers too (captured through a real PTY with the service's options and `TERM=xterm-256color`). While typing, Witerm let SwiftTerm's mouse drag through whenever mouse reporting was on, so a one-finger swipe went to tmux as a held button. tmux started a copy-mode selection (shared by every client of the session) and copied it on release. Watching never reports the mouse, so the same swipe scrolled. The fix is on both ends:

- **Mac service:** its tmux sets `mouse off` when a session is made and again before each attach (for sessions made by an older service). `AgentTests.testTmuxNeverAsksViewersForTheMouse` (real tmux, its own socket) fails on the old service, with `?1000h`, `?1002h` and `?1006h` on the first attach, after a resize, on a re-attach and for a viewer, and passes now. An older Mac service keeps sending them until it's updated, which the phone handles on its own:
- **iPhone:** a paired terminal's touches stay Witerm's whatever its stream asks for (`passesMouseToPrograms` off): a swipe scrolls Witerm's scrollback and a tap stays a tap, as when watching (`TerminalSelectionTests.testPairedTerminalsKeepTouchesWhenTheirTmuxAsksForTheMouse`, fed the captured bytes). For SSH, where a program the person runs asked for the mouse, a one-finger swipe never sends a held button: it sends wheel steps at the finger (below).

The other causes below were found on the way and also fixed. Each was reproduced with a new UI test in `SSHTypingChromeTests` on the old gesture code (the same build with only the DEBUG probe added: the selected character count and the handles' knob positions in the layout probe's label), then fixed.

| # | Cause (confirmed) | Fails before | Change |
|---|---|---|---|
| 1 | Witerm's selection long press fired after **0.35 s** (UIKit's own is 0.5 s). A finger that rested a moment before swiping became a long press, and the swipe then extended the selection instead of scrolling. | `testSlowStartSwipeScrollsWithoutSelecting` (rest 0.4 s, then a 200 pt drag), 3 of 3 attempts: 467 characters selected, Copy shown, no scroll (top row 375 → 375). | The long press takes 0.5 s. It is cancelled when the terminal (or the wide grid's sideways scroll) starts dragging, can't begin while either is dragging or coasting, and a touch that lands on a coasting fling only stops it (`SelectionPressGate`). After: nothing selected, no menu, and each swipe scrolled back (375 → 363 → 341 → 318). |
| 2 | With a selection, a drag grabbed a handle within 22 pt **plus half a row** of the text's corner, not of the knob SwiftTerm draws 6 pt above the first character and below the last, and it was tested where the finger was once the drag was recognized (about 10 pt along), so a swipe toward a handle took it from farther away. The selection lasted until a tap, so one accidental selection kept catching later swipes. | `testSwipesNearASelectionScrollAndItsHandlesStillDrag`: a swipe up from the text 30 pt below the end knob moved the selection (36 → 40 characters) and didn't scroll (`r15-before3/`). Dragging the end knob 100 pt left grew the selection instead (36 → 62, the end jumped to the row the knob hangs in), and the edit menu, placed at the lift point, covered the rows under the selection, so the next drag there landed on the menu (`r15-before/`). | A handle is grabbed only within a 44 pt square centered on its knob, from where the finger came down. The end being dragged keeps the finger's offset from the middle of its character, so it doesn't jump rows. The edit menu is placed beside the selection and its knobs (the interaction's target rectangle), not over them. A first version tested the touch-down point from the pan's translation, which is still zero when it asks to begin, and the swipe toward the handle still took it (36 → 113); the drag now records where its finger came down. After: both swipes scrolled with the selection unchanged (top row 375 → 368, then forward to 372), the knob drag shortened it (36 → 24), and Copy then the Paste key typed exactly those 24 characters. |
| 3 | When a program asks for the mouse (tmux `mouse on`, vim `mouse=a`, htop) and the terminal can type, SwiftTerm's drag sent a held button (press, motion, release), which those programs turn into their own selection. Witerm also let *any* SwiftTerm drag begin then, including its selection drag left over from a double tap. This is the paired case above when the stream comes from Witerm's tmux. | `testSwipesScrollProgramsThatAskForTheMouse` over SSH, typing: in tmux with `mouse on` a 220 pt swipe didn't scroll (tmux selected, copied and left copy mode); in `vim -c 'set mouse=a'` it started Visual mode across 13 lines (`r15-mouse-before/`). | A one-finger swipe never sends a button. For a program that asked for the mouse it sends wheel steps (buttons 64/65, in the program's encoding, at the finger's cell), one per row dragged, and coasts after a fling with UIScrollView's deceleration; a touch stops the coast without selecting. Without the mouse it scrolls Witerm's scrollback. Taps still click (with the keyboard up, as before), and a long press still makes Witerm's own selection, never sent. No SwiftTerm drag begins. After: tmux scrolled into copy mode with no selection (`[85/362]`), vim scrolled with no Visual mode, a tap moved vim's cursor, and at a plain prompt with the keyboard up the swipe scrolled Witerm's scrollback. |

**Starting a scroll with a selection (HIG).** As in other iOS text, the selection stays and the edit menu steps aside while the text scrolls, and returns beside the selection when the scroll stops (if any of it is on screen). The touch that starts the scroll usually closes the menu already; the terminal brings it back.

**Deliberate mouse drags** (resizing tmux panes, a mouse selection in vim) aren't offered. A two-finger drag would compete with the pinch, and a key-row toggle is more chrome for a rare need; tmux and vim have keyboard equivalents, and Witerm's long press selects and copies locally. A later round can add a toggle, off by default, if it's missed.

**Alternate screen without the mouse** (`less`, `man`): unchanged. The swipe moves nothing, since that screen has no scrollback. Sending arrow keys there, as macOS Terminal does under DECSET 1007 (alternate scroll mode), would be the HIG-consistent next step; not done, because few programs set 1007 and the keys would reach the program.

**Unit tests** (`TerminalSelectionTests`, 6): the knobs' positions; a 44 pt target on each knob and none on the text 30 pt away (the points the old target took); the menu's rectangle containing both knobs; swipes as the wheel in mouse mode (SGR `ESC[<64;…M` per row dragged, never a button) and as scrolling otherwise or when watching; a paired terminal fed the tmux client's captured bytes keeping its touches; the 0.5 s long press.

**Gesture log (DEBUG builds, for confirming on the iPhone).** Each gesture on a terminal is logged with os_log, subsystem `com.witerm`, category `terminal-gestures`, never terminal content: which recognizer asked to begin and the answer, when it began and ended, the mouse mode, whether the view reports the mouse, has the keyboard and accepts input, whether a selection is active, and, when a selection starts, which recognizers were running (on the view and its window). To read it:

- iPhone: Console.app → the iPhone in the sidebar → Start, then filter `subsystem:com.witerm category:terminal-gestures`. Or afterwards: `sudo log collect --device-udid 00008150-000259AE36C0401C --last 10m --output r15-gestures.logarchive`, then `log show r15-gestures.logarchive --predicate 'subsystem == "com.witerm" AND category == "terminal-gestures"'`.
- Simulator: `xcrun simctl spawn <simulator-udid> log stream --level info --predicate 'subsystem == "com.witerm" AND category == "terminal-gestures"'`.

A swipe in a paired terminal should log `shouldBegin=true UIScrollViewPanGestureRecognizer[scroll]` and `allowMouseReporting=false`; a line `selectionStarted running=[…]` names whatever started a selection.

### Part 2: SwiftTerm's Metal renderer, on trial

SwiftTerm 1.19.0 (unchanged) has an opt-in Metal renderer. A DEBUG-only switch selects it for iOS terminals: launching with `-witerm.debug.renderer metal` (a launch argument, so it lasts for that launch only); anything else, or nothing, keeps Core Graphics, the default. Builds with the `WITERM_RENDERER_TRIAL` compilation condition get the switch too, for optimized measurements on the phone. `-witerm.debug.metalRaw YES` turns off Witerm's fixes below, for comparison. Nothing appears in product UI. UI tests pass it through with `WITERM_RENDERER=metal` (and `WITERM_METAL_RAW=1`); `testRendererTrialScreens` captures the same steps with either renderer (`r15-screens-*`).

**What differs under Metal, and what Witerm does about it** (iPhone 18 Pro simulator, light appearance):

| Area | Under Metal, as SwiftTerm draws it | Witerm's fix (trial only) | Result |
|---|---|---|---|
| Row positions while scrolled | The renderer draws whole rows from the top of its view, starting at the first row the scroll offset reaches, and ignores the part of that row scrolled past. The text sat up to a row lower than where touches, the selection and its handles are (`r15-screens-metal/…-2-selection.png`: the handles half a row above the highlight), moved in whole-row steps while the content scrolled smoothly, and the prompt's foot was cut off at the bottom. | The Metal view moves up by the part of a row scrolled past, so every row is where Core Graphics puts it; a plain view in the terminal's background sits under it. | Rows, highlight and handles line up (`r15-screens-metal3/`), and the selection UI tests pass under Metal. **Left:** the renderer can't draw below its first row plus the view's height, so a strip of up to one row at the bottom stays blank, which hides the lower part of the prompt while following output. Fixing that needs SwiftTerm itself (offset its rows by the scrolled part and draw one more). |
| Selection handles | Not drawn: SwiftTerm draws them only in its Core Graphics path. | Witerm draws the same line and 12 pt knob over the Metal view, in the handle color, from `selectionKnobs()`. | Handles show and drag: `testSlowStartSwipeScrollsWithoutSelecting` and `testSwipesNearASelectionScrollAndItsHandlesStillDrag` pass with `WITERM_RENDERER=metal` (long press, swipes near a handle, a knob drag, Copy). |
| Selection highlight | The tint at 28% (40% with Increase Terminal Contrast) behind text that keeps its color | none needed | Same as Core Graphics. |
| Cursor | SwiftTerm hides its caret view and draws the cursor itself | none | Drawn (a steady block in the tests). Blinking wasn't checked. |
| Increase Terminal Contrast, color schemes | Redrawn: a color change marks every row dirty and the renderer rebuilds them. Ocean's text measured `#0E2A3A` on `#F2F7FA`, System back to `#000000` on `#FFFFFF`, with no fix. | none needed (rebuilding the renderer on color changes was tried and removed) | Same as Core Graphics. The system's light/dark and Increase Contrast weren't toggled (system settings); they take the same `installColors` path. |
| Reading view (VoiceOver's text) | Built from SwiftTerm's buffer, not the renderer | none | The same text either way (the tests read it). Real VoiceOver wasn't run. |
| Pinch to zoom | The live transform scales the Metal layer as it does the Core Graphics one | none | Works; the frame where the fingers lift is slower (below). |
| Jump to Latest, font changes and reflow, rotation | Work | none | `testScrollingAndPinchStaySmooth` (pinch, reflow, host resize, the size back) and `testRendererTrialScreens` (landscape and back, Jump to Latest). |
| Watch mode (read-only grid) | The fixed grid is laid out as before; the Metal view follows the terminal's bounds | none | Not run: it needs a paired Mac. |
| Console | SwiftTerm's Debug build prints "Metal FPS" every second while drawing | none | Debug log noise only. |

**Numbers** (iPhone 18 Pro simulator, 60 Hz, Debug, `SSHTypingChromeTests.testScrollingAndPinchStaySmooth` against the fixture: three fast flings through `seq 1 100000`, a slow drag while `seq 1 3000000` streams, a pinch to 1.5×). Ranges over four runs of each renderer (three plain, one under Time Profiler; memory from the third). As the libghostty spike found ([renderer-evaluation.md](renderer-evaluation.md)), timing `draw(_:)` alone measures only Core Graphics recording its commands; the rasterizing happens later, in Core Animation's commit on the main thread. So the probe now also measures **main-thread busy time per frame**: everything the main run loop does between two display-link frames (observers on its waking and sleeping), including parsing, layout, drawing, the commit and Metal's encoding. Hitches come from the same display-link probe (an interval over 1.5 frames); the Animation Hitches instrument doesn't run on the simulator.

| Measure | Core Graphics (default) | Metal (with Witerm's fixes) |
|---|---|---|
| Flings: hitches per 3 flings, worst frame | 0–1, 16.7–33.3 ms | 0–2, 33.3–39.8 ms |
| Flings: main-thread busy per frame, mean / p95 / worst | 3.9–4.3 / 5.3–5.7 / 6.1–24.8 ms | 2.2–3.0 / 7.5–10.0 / 9.8–12.6 ms (one first fling 74 ms) |
| Flings: drawing timed per frame, mean / p95 | 2.1–2.3 / 2.8–3.0 ms (recording only) | 1.7–1.9 / 7.0–8.5 ms (building rows and encoding) |
| Drag during live output: hitches; busy mean / p95 | 0; 2.9–4.2 / 4.8–5.7 ms | 0–2 (worst 58.9 ms); 1.8–2.4 / 5.0–8.5 ms |
| Pinch: hitches, worst frame (the lifting frame) | 1–2, 36–67 ms | 1–3, 55–92 ms |
| Pinch: main-thread busy in the lifting frame | 11–41 ms | 21–68 ms |
| Pinch: lifting → new font / new grid | 0–2 / 4–16 ms | 2–6 / 12–19 ms |
| Pinch: drawing of the first frame at the new size | 3.4–3.7 ms | 8–16 ms (a new glyph atlas) |
| Memory (physical footprint) after `seq 1 100000` / after 3 million lines and the pinch | 74.7 / 75.5 MB (79.6 MB at the end of the screens test) | 71.1 / 73.4 MB (75.5 MB) |

The mean main-thread time per frame drops by about a third with Metal, but its p95 is about 1.5× Core Graphics', and the tail decides hitches: whenever the top row changes (every few points of a fling), the renderer rebuilds every visible row, because the first row is part of its cache key. At 120 Hz (8.3 ms a frame) Core Graphics' p95 of 5.3–5.7 ms fits; Metal's 7.5–10.0 ms doesn't.

**Main-thread split** (Time Profiler over the whole test, about 36 s of main-thread time with either renderer):

| Bucket | Core Graphics | Metal |
|---|---|---|
| XCTest's queries and accessibility snapshots (the test's own) | 14.6 s | 14.6 s |
| Parsing output (`Terminal.feed`, mostly the 3 million lines) | 12.9 s | 13.0 s |
| Drawing: `drawTerminalContents` (recording) / the Metal renderer (rows, encoding) | 1.6 s | 1.1 s |
| Core Animation commit (for Core Graphics including replaying the recorded drawing) | 2.4 s | 1.8 s |
| Layout | 0.3 s | 0.4 s |
| Logging, UIKit's update cycle, other | 4.2 s | 4.7 s |

Drawing plus commit is 4.0 s with Core Graphics and 2.9 s with Metal. Parsing is the same and dominates whenever output streams.

**For the lead: keep Core Graphics as the default.** On the simulator Metal saves about a third of the average per-frame main-thread time, but its slow frames are slower, the pinch's lifting frame is slower, and its bottom-row clipping can't be fixed without changing SwiftTerm. The libghostty spike's harness saw the same shape (Metal's fling p95 4.75 ms against Core Graphics' 4.4 ms, and more hitches under heavy output). Whether either renderer hitches at 120 Hz is for the iPhone 17 Pro to show; the steps are below.

**Parsing on the main thread.** Yes. SSH (`SSHNativeTerminalView`, whose batches are drained off the main thread) and paired terminals both call `TerminalView.feed(byteArray:)` on the main actor; parsing took 12.9–13.0 s of main-thread time in these runs. SwiftTerm documents `feed` as callable from a background thread, but nothing guards its buffer: both renderers read lines at draw time, and selection, search, the reading view, resizing and the key row's `send` (which, by SwiftTerm's own contract, must run on the thread that feeds) all use the same state on the main thread. Moving parsing off it would need a SwiftTerm change (a lock, or a snapshot handed to the renderer) and would still have to keep Witerm's ordering: `geometry` and VT output applied in order from the single `events` stream, and an SSH window change only after the output before it. Not feasible inside Witerm alone; reported, not changed.

**Measuring on the iPhone 17 Pro** (steps for the lead; not run). The switch is DEBUG-only, so use either the usual Debug build (it has the motion probe) or an optimized build with the trial's condition:

1. Build and install. If the provisioning profile has expired (2026-11-10 06:01 UTC), renew it by building once in the Xcode IDE first.
   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodebuild build -project apps/apple/Witerm.xcodeproj -scheme WitermiOS -configuration Release \
     -destination id=00008150-000259AE36C0401C -derivedDataPath .build/apple-device-release \
     SWIFT_ACTIVE_COMPILATION_CONDITIONS=WITERM_RENDERER_TRIAL
   xcrun devicectl device install app --device 00008150-000259AE36C0401C \
     .build/apple-device-release/Build/Products/Release-iphoneos/WitermiOS.app
   ```
   For the Debug build: `-configuration Debug`, `-derivedDataPath .build/apple-device`, and `Debug-iphoneos`, as in [handoff.md](../handoff.md).
2. Launch with one renderer. The argument lasts for that launch only:
   ```sh
   xcrun devicectl device process launch --device 00008150-000259AE36C0401C --terminate-existing \
     com.witerm.ios -witerm.debug.renderer metal
   ```
   For Core Graphics, launch the same way without `-witerm.debug.renderer metal`. To add SwiftTerm's own Metal signposts, add `--environment-variables '{"SWIFTTERM_PROFILE": "1"}'`.
3. Find the process: `xcrun devicectl device info processes --device 00008150-000259AE36C0401C | grep WitermiOS`.
4. Record while the owner does the same gestures each time (connect an SSH host, run `seq 1 100000`, three fast flings back, Jump to Latest, a slow drag while `seq 1 3000000` runs, Ctrl+C, pinch out, pinch back):
   ```sh
   xcrun xctrace record --device 00008150-000259AE36C0401C --template 'Animation Hitches' \
     --attach <pid> --time-limit 90s --output .build/r15-device-metal-hitches.trace
   xcrun xctrace record --device 00008150-000259AE36C0401C --template 'Time Profiler' \
     --attach <pid> --time-limit 90s --output .build/r15-device-metal-time.trace
   ```
   Then relaunch without the argument and record `r15-device-coretext-…` the same way.
5. Compare: open the traces in Instruments (hitches per gesture, the worst hitch, the frame where the pinch lifts, the main thread's split), or list their tables with `xcrun xctrace export --input <trace> --toc` and export one with `--xpath`.

**Verification:** see [verification.md](../verification.md), Round 15: iOS.
## Round 16: iOS structure

The owner's eight requests for the iPhone and iPad app, on 2026-11-04, decided by the HCI lead in [iOS information architecture](ia-ios-round16.md) (inventory, the structure, every duplicate removed, Settings' frequent and Advanced split, swipe rules, and the terminal chrome). Before and after captures: `.build/screenshots/round16-ios/before/` (the opt-in `AuditScreenshotTests`, English, light) and `.build/screenshots/round16-ios/after/` (the same test, and `InformationArchitectureTests` under `after/round16/`).

### Phase A: lists, Devices, Settings, swipes, Text and Colors

| Request | Before | After | Main code |
|---|---|---|---|
| 4. Terminals grouped by device, no drill-down, one entry point each | One untitled section mixing paired devices (a chevron into each device's terminal list) and SSH hosts; an **Open** section for live hosts; first-use rows, a **+** in the bar, and Devices repeating Add SSH Host…, Import, Add Device and every host action | One list: a section per paired device (name, Online / Offline / Checking…, its terminals as rows; offline says so in one line), **Shared with You** for invitation grants, then **SSH Hosts** (live cards first, then favorites and recent; Add SSH Host… and Import SSH Hosts… as its last rows). Search Terminals covers every section; ⌘1–⌘9 follow the list's order. Each device's terminals are listed on their own (`RemoteTerminalModel.listTerminals`), so one offline device never hides another; opening one from the list detaches any open terminal on that relay server and attaches after the ACK (`open(_:on:)`). The per-device terminal screen is no longer routed to: the paired workspace shows only while a terminal is displayed. | [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift), [SharedTerminals](../../apps/apple/Sources/Mobile/SharedTerminals.swift) |
| 5. Devices: devices and their servers only | Add Device, paired devices (Show Terminals on each page), SSH Hosts with every host action | Add Device, **Paired Devices** (the server on the row when there are several), **Relay Servers** (moved from Settings ▸ Connections, with Add Relay Server). Show Terminals is gone. | [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift), [RemoteModels](../../apps/apple/Sources/RemoteTerminal/RemoteModels.swift) |
| 2–3. Categories and Advanced | Appearance (Text and Colors ▸, Bell and VoiceOver ▸), Keyboard (Keyboard Row ▸, Snippets ▸), Connections (Relay Servers ▸), Help | **Terminal** (Text and Colors, Snippets ▸), **Help** (Welcome Tour), **Advanced** ▸ (Increase Terminal Contrast, Keyboard Row ▸, Terminal Bell, Announce New Output) | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift) |
| 8. Appearance and size in one collapsible group | Text and Colors was a page; the terminal's Terminal Display sheet repeated it with the key row, snippets, bell and VoiceOver | Settings ▸ Terminal ▸ **Text and Colors** is a disclosure group showing "14 pt · System" until opened (font size and preview, color scheme and preview, Restore Display Defaults). The terminal's sheet on iOS holds only text and colors; the in-terminal submenu is Phase B. | [TerminalAppearanceSettings](../../apps/apple/Sources/Design/TerminalAppearanceSettings.swift) |
| 1. Swipe actions | SSH hosts: Favorite leading, Disconnect or Delete Host trailing; a device's terminals: Watch | Unchanged for hosts (full swipe deletes, since Undo restores), now also a long-press menu identical to the ••• menu. Paired devices: trailing **Unpair…**, never a full swipe and not offered offline, always the existing confirmation; also in the long-press menu. Relay servers: trailing **Remove…** (confirmed), and a long-press menu with Check Connection, Edit Address and Remove Relay Server…. Terminals keep Watch (swipe and long press), with no delete: ending a terminal is its Mac's decision. | [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), [DevicesView](../../apps/apple/Sources/Mobile/DevicesView.swift) |

**Invitation grants.** A grant joined from a one-terminal invitation looks like any grant to the phone, so the phone now records its ID and end time when it joins (`SharedTerminals`, in this device's defaults, no secrets; pruned when the relay server stops listing it or a day after it ends). Those grants are listed under Shared with You and not in Devices. A grant joined before this round is still listed as a paired device.

**Test fixture.** `-witerm.debug.remoteFixture 1` with the relay server `https://relay.fixture.invalid` (DEBUG only) stands in for three paired Macs (one online, one watch-only, one offline) and one shared terminal, in memory, so the new layouts, Unpair's confirmation and its swipe can be tested without a Mac or a relay server and without revoking anything real. `InformationArchitectureTests` uses it; its last test gives the fixture machines' colors back.

### Phase B: the keyboard is the switch

| Request | Before | After | Main code |
|---|---|---|---|
| 6. Keyboard button bottom right | In the navigation bar (both kinds of terminal) and the iPad header, toggling show and hide | A 44 pt glass button (gray with Reduce Transparency) at the terminal's bottom right, 16 pt from the trailing safe area, in an 8 + 44 + 8 pt strip of its own under the text, so it never covers the cursor line or Jump to Latest; only while the keyboard is hidden. While it's up, the key row ends with **Hide Keyboard** in every orientation (the arrows still fit beside it on a 402 pt iPhone: text keys' insets 10 → 8 pt, spacing 6 → 5 pt). Identifiers stay `sshKeyboard` and `remoteKeyboard`; VoiceOver reads it after the terminal text. | `TerminalSurface` in [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift), [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift), [SSHNativeTerminalView](../../apps/apple/Sources/SSH/SSHNativeTerminalView.swift) |
| 7. No Typing or Watching modes | Typing / Watching in the title and VoiceOver announcements, Start Typing and Stop Typing in the menu and as ⇧⌘T, Watch as a swipe, a long press, an issue action and in the reconnect card, "Switching to Typing…" | The keyboard is the state. The paired keyboard button calls the existing `switchMode()` (detach ACK, then attach to type; the new renderer takes the keyboard when shown). Hiding the keyboard (Hide Keyboard, a swipe on the keyboard, or closing Find without it) switches back to watching after 0.4 s if focus doesn't return, not while Find or a sheet (the paste review) is up or in the background. Asking to type while someone else types, and opening a terminal then, fall back to watching with Typing on *device* (the automatic path), never by force. The title says only the device, Typing on *device*, Can only watch, Showing Keyboard… / Hiding Keyboard… or the connection's state; the switch no longer covers the terminal with the connection card. ⇧⌘T, the menu items, every Watch action, the announcements, and the unreachable per-device terminal list are gone from iOS. | [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift), [RemoteTerminalModel](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalModel.swift), [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift) |
| 8. In the terminal | Smaller and Larger Text loose at the top of the menu, and a Terminal Display sheet | One **Text and Colors** submenu: Decrease and Increase Text Size side by side, then the color scheme. The sheet is gone (contrast, bell and VoiceOver are in Settings ▸ Advanced). | [TerminalFindBar](../../apps/apple/Sources/RemoteTerminal/TerminalFindBar.swift), [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift) |

**Kept on purpose.** Tapping an SSH terminal still raises the keyboard (Round 15's touch model; nobody else can be typing there); tapping a paired terminal while watching never starts typing. The Mac app is unchanged: a window has no software keyboard, so its Typing and Watching states stay. **Safety rules** (AGENTS.md) hold: typing is only ever taken by the explicit keyboard-button tap; every switch waits for the detach ACK; nothing is resent; a watch-only grant gets no button.

**Not verified here:** the software keyboard (the simulator stays in hardware-keyboard mode, so only the key row shows), a swipe-down dismissal, and the paired-Mac path live (built, unit- and fixture-tested; the joint `MacContinuityFlowTests` was updated and built for the lead to run). VoiceOver speech, and Voice Control saying "Show Keyboard", weren't tried by hand.

## Round 17: iOS

The owner's four approved recommendations from Round 16 and five issues found on the iPhone 17 Pro, on 2026-11-04, on the iPhone 18 Pro simulator. Paired terminals now open on the simulator through the DEBUG remote fixture's Mac (`FixtureMac`, in memory, below), so the paired path was exercised for the first time without a Mac; SSH ran against the disposable OpenSSH fixture. Midway through, the simulator began showing the real software keyboard (see Verification), so most results here are with it. Captures: `.build/screenshots/round17-ios/` (`before/` and `before-soft/` on the code before the fixes, `after/` and `after-soft/`).

### B1: the black half screen

**Root cause.** Typing in a paired terminal sets the Mac's grid to this phone's size, and with the software keyboard up that's the rows above it (45 × 21 on a 402 × 874 pt iPhone). Hiding the keyboard switches to watching 0.4 s later, and a watching device shows the Mac's grid as the Mac has it, never resizing it (AGENTS.md). The resize to the keyboard-hidden size never reached the Mac: the full-height layout comes only once the keyboard reports it has gone, then the renderer waits 100 ms to coalesce resizes, and the switch to watching turned the renderer non-interactive, which drops a pending resize. So the watched grid stayed 45 × 21 and the 305 pt below it showed the terminal's black background. The Round 14 overlap logic and the Round 16 strip were measured and are right (SSH, which never watches, got all 38 rows back with no gap); the simulator's hardware keyboard hid it because the key row alone costs one row (41 against 42), which the strip then covered.

**Fix.** Hiding the keyboard now tells the Mac the size this screen watches at, the whole terminal less the keyboard button's strip (`TerminalSurface.watchingFit`), before the detach, in the same ordered connection (`RemoteTerminalModel.stopTyping(fitting:)`). It's best effort: when another writer owns the grid the Mac keeps theirs, as the service's rules say. Watched, the grid is 45 × 38 and fills the text area (15.7 pt left over, under one row).

| | Before | After |
|---|---|---|
| Software keyboard (DEBUG stand-in): typing, then hidden | 45 × 21, then watching 45 × 21 with 305 pt blank (`before-soft/b1-2-watching.png`) | 45 × 21, then 45 × 38, 15.7 pt left over |
| Real software keyboard | 45 × 23, then watching 45 × 23 with 271 pt blank (`before-real/`) | 45 × 23, then 45 × 38 |
| Hardware keyboard (key row only) | 45 × 41, then watching 45 × 41, 35 pt of it under the keyboard button | 45 × 41, then 45 × 38 |

Tests that fail first: `PairedTerminalFixtureTests.testHidingTheKeyboardWatchesAGridThatFillsTheScreen` (21 ≠ 38 rows with the stand-in, 23 ≠ 38 with the real software keyboard, 41 ≠ 38 with the hardware keyboard), and the unit test `TerminalKeyboardInsetTests.testWatchingFitIsTheKeyboardHiddenSizeAndFillsTheView`.

**Log for the owner's iPhone** (DEBUG builds, never terminal content): subsystem `com.witerm`, category `terminal-layout`. Each keyboard notification (`keyboard wcf|dcf|ds|dh frame=…`), each layout that changed anything (`layout mode=… focused=… keyboard=[frame@screen] keyRow=[…] overlap=… strip=… view=… text=… grid=CxR fixed=… fit=… gridHeight=…`), focus changes, `stopTyping releaseGrid=CxR`, and the background steps (`background remaining=…`, `park`, `foreground away=…`, `resumed in place in …`, `resume cover removed after … ms`). In Console.app: `subsystem:com.witerm category:terminal-layout`; afterwards: `log show <archive> --predicate 'subsystem == "com.witerm" AND category == "terminal-layout"'`.

### The four approved recommendations

| # | Change | Main code |
|---|---|---|
| A1 | **End Invitation…** on a Shared with You terminal: a trailing swipe (never a full swipe) and the long-press menu, not offered offline. The confirmation says it can't be undone ("End Invitation to “Demo”? This iPhone can no longer open it. This can’t be undone: to open it again, Alex’s MacBook must invite you again."). It deletes only that grant on the relay server (a participant may), leaves an open terminal from it after the detach ACK, and removes the row; a failure says the invitation is still in effect. "End Invitation" is the Mac's word for the same thing. | [TerminalsHome](../../apps/apple/Sources/Mobile/TerminalsHome.swift), `RemoteTerminalModel.endInvitation` |
| A2 | While VoiceOver runs, Announce New Output is in Settings ▸ Terminal and not in Advanced; without VoiceOver it's in Advanced only. One toggle, one key (`TerminalAnnounceOutput.key`). | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift), [TerminalAppearanceSettings](../../apps/apple/Sources/Design/TerminalAppearanceSettings.swift) |
| A3 | Tapping a watched paired terminal starts typing, as the keyboard button does (detach ACK, then attach to type), when nobody else types there. When the latest list says someone does, the tap keeps watching, speaks "Typing on *device*" with a warning tap, and asks nothing. A Mac that refuses anyway (someone started meanwhile) keeps it watching and names them. A tap that lands on a fling only stops it (`TapGate`); a tap with a selection only clears it. | `TerminalInputView.tapToType`, [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| A4 | Invitations joined before Round 16 stay listed under Devices: no change, documented in the [IA](ia-ios-round16.md). | — |

### B2–B4: the key row, menus, floating buttons

- **Hide Keyboard (B2)** is now the same system glass capsule as the keyboard button it stands in for, 44 pt and round (solid gray with a soft shadow under Reduce Transparency, and the outline with Increase Contrast), instead of a flat filled rectangle. The key row fades out at an edge with more keys past it (36 pt) and flashes its scroll indicator once it appears. **Swipe down to dismiss**: on the key row, a swipe down hides the keyboard; it can't conflict, since the row only scrolls sideways and its keys act on touch-up (a swipe cancels the touch, so nothing is sent). On the text, `keyboardDismissMode` stays `.interactive` (as in Messages), but a drag there is scrolling (or the wheel in mouse mode), and on the simulator a drag from a short shell's text didn't move the keyboard; the key row's swipe is the dependable gesture. Hiding by any of these watches with the full-screen grid.
- **No menu from a menu (B3, now a rule in the [Design Guidelines](README.md#interaction-principles)).** Audit of every iOS menu: the terminal's ••• menu (paired, iPad header, SSH) and the key row's actions key each opened **Text and Colors** as a submenu. Now its contents are inline at the top of the same menu: one row of Decrease Text Size, the size (which restores 14 pt) and Increase Text Size that keeps the menu open while stepping, like Safari's zoom, then the color scheme as a checkmarked section. Nothing else nested: SSH host ••• and long-press menus, paired device, relay server, snippet and SFTP menus, the Snippets key, the title's switcher and the edit menu are flat; the Mac's menu bar keeps its submenus. Menus drop the accessibility identifiers of a control group's buttons, so tests find those by label.
- **Floating buttons (B4).** Jump to Latest (the only scroll-to-bottom button on iOS, shared by SSH and paired terminals) was a gray capsule 12 pt from the text; now it and the keyboard button share `FloatingTerminalButton`: 44 pt glass capsule, the same fallback and shadow, restyled when Reduce Transparency changes, the same trailing inset (16 pt or the safe area), Jump to Latest 8 pt above the text's bottom and the keyboard button in its strip. Labels unchanged (Jump to Latest, Show Keyboard), with the Large Content Viewer.

### B5: three minutes in the background

iOS gives a backgrounded app a background task of about 30 seconds (30.0 s on the simulator), not guaranteed, and then suspends it; Witerm uses no background modes. So the window is a policy, kept two ways:

- **Paired:** the same connection while the app runs. Five seconds before the background time ends (25 s here), the terminal is **parked**: the link detaches with the Mac's ACK, so control is released, but the renderer, screen, scrollback and keyboard stay. Returning within 3 minutes opens a new link in the same mode and hands it to the same renderer under a still picture of the old screen, removed once the redraw has paused for 0.15 s (at most 1.5 s), so nothing blank, reset or "Reconnecting" shows. If someone else types there now, it watches and says so. A link found dead within 10 s of returning is resumed the same way. Past 3 minutes it reconnects as before (visible). Keys typed while the link is being replaced are dropped, never resent.
- **SSH:** the connection simply stays open. While suspended nothing answers the host, so a host that probes clients (`ClientAliveInterval`) may close it; the fixture's sshd doesn't. Past 3 minutes the connections are closed when the app next runs ("Disconnected after 3 minutes in the background"). A connection the host closed meanwhile ends with its reason and Reconnect: a new SSH connection is a new shell, so it can't be resumed in place.

| Away | Paired (fixture Mac) | SSH (OpenSSH fixture) |
|---|---|---|
| 10 s | **Same connection kept**; typing again 0.80 s after returning (0.74 in another run), no new link, no cover | **Same connection kept** (the same `$$`); typeable 0.33 s after returning |
| 60 s | **Resumed in place** (parked at 26.9 s with ACK); typing again 0.81 s after returning; one new link; cover up 278 ms; nothing else on screen changed | **Same connection kept**: the app was suspended, the TCP connection stayed, the same `$$` answered; typeable 2.67 s after returning |
| 170 s | **Resumed in place**; typing again 0.78 s; cover 471 ms | **Same connection kept**, the same `$$`; typeable 3.42 s |
| over 180 s | Reconnects visibly on return (as before) | Closed on return with the reason and Reconnect |

For SSH, "typeable" is the test's check (keyboard up, the prompt on the last line, the actions menu there); the extra 2 to 3 s after a suspension wasn't attributed. "Typing again" is measured from the app being active until the terminal has the keyboard and is typing (the probe), sampled every 50 ms; Disconnected and Opening never appeared. The fixture's Mac answers after 150 ms per step, so on a real relay a resume takes a handshake and an attach longer (about 1 s on a good network, more on cellular), during which the old screen shows and typing is dropped. Not run: the real relay path (the Mac app and its service weren't touched); a physical phone, where iOS may give less background time, and where a suspended app's sockets may be closed by iOS itself.

### Fixture Mac and test seams (DEBUG only)

- `PairedTerminalLink` is what the renderer and model use of an attachment; `RemoteTerminalAttachment` conforms, and so does `FixtureLink`. `FixtureMac` follows the service's rules: typing attaches set the grid, watchers get geometry, one typer at a time (the fixture's Macs don't type alongside), Can only watch refuses typing, a terminal the Mac types in refuses typing, input echoes, and a link left open across more than 20 s in the background fails on return, as the relay server would have closed it.
- `-witerm.debug.softwareKeyboard YES` gives terminals a plain input view the size of the iPhone's keyboard, for simulators with a hardware keyboard; `-witerm.debug.voiceOverRunning YES` puts Announce New Output where VoiceOver would.
- The layout probe adds `mode`, `fitRows`, `gap`, `overflow`, `links`, `covers`, `coverMs` and `focused`.

**Verification:** see [verification.md](../verification.md), Round 17: iOS.

## Round 18: iOS

Requests from the owner after Round 17 on the physical iPhone 17 Pro, on 2026-11-04, worked on the iPhone 18 Pro simulator through the DEBUG fixture Mac (`FixtureMac`) and the disposable OpenSSH fixture. The simulator was in hardware-keyboard mode this round (the key row alone, 18 pt of it over the terminal) and wasn't changed; the DEBUG stand-in keyboard (`-witerm.debug.softwareKeyboard YES`) covers the software keyboard. Captures: `.build/screenshots/round18-ios/` (`before/`, `before-soft/` with `terminal-layout.log`, `after/`).

### 1. The obstruction at the bottom

**Cause.** Round 16's keyboard button sat in a strip of its own under the text (8 + 44 + 8 pt), so with the keyboard down the text stopped 60 pt short of the bottom; a watched grid, which can't fill part of a row, then left up to one more row (15.7 pt) blank above the strip. Together that was a 76 pt band of background at the bottom of every paired terminal while watching (three rows lost, and a near-empty strip with one button in it), and a 60 pt band on an SSH terminal with the keyboard down. With the keyboard up there was no band, because the strip goes away while the key row is there; that's why it read as "much better" after Round 17. The home indicator's safe area wasn't part of it (it lies under the terminal, in the terminal's own background), and the watched grid was the size the phone set (Round 17's fit), except that the fit left out the strip.

| | Before | After |
|---|---|---|
| Paired, watching, portrait (layout log) | `text=390x662 strip=60 grid=45x38 gridHeight=646`: 75.7 pt blank at the bottom | 45 × 42, 7.7 pt left over, at the top |
| Paired, watching, landscape | 60 pt strip under the text | 85 × 17, 12.7 pt left over, at the top |
| SSH, keyboard down, portrait / landscape | 45 × 38 and 85 × 14 with a 60 pt band | 45 × 42 and 85 × 17, no band |
| Keyboard up (key row only; stand-in keyboard) | No band (45 × 41; 45 × 21) | Unchanged |

**Change.** The keyboard button floats over the terminal (Round 17's floating-button style: 44 pt system glass, gray with Reduce Transparency) at the text's bottom right and reserves nothing: the text and its grid take the whole height (`TerminalSurface.contentBounds`, `watchingFit`). Jump to Latest sits just above it when both show.

**When text is under it, the button moves; the content doesn't.** The HIG asks that controls over content not hide what matters, and that content stay stable. Lifting the text would bring the band back, and a faded control reads as disabled. So from its resting place the button steps up one row at a time, within the text's lower half, to the first place with only blank cells under it, and it never covers the cursor. With text everywhere (a full-screen program) it rests at the bottom unless the cursor is there, and then sits just above the cursor's row (`placeKeyboardButton`). It moves with a 0.2 s animation (none with Reduce Motion) after output and layout. Only the button moves: no grid change and no resize come from it.

A watched grid's leftover of less than one row goes to the top, so the last line sits on the bottom edge; the surface's background is the terminal's own, as before. Round 14–17 guarantees hold: rotation fit and reflow (`TerminalLayoutTests`, `TerminalReflowTests`); a watcher never resizes the Mac's grid except with Round 17's stop-typing fit (now the whole view); and showing or hiding the keyboard changes the grid once (the strip's hold-for-focus logic went with the strip).

Tests that fail first: `PairedTerminalFixtureTests.testTheTerminalUsesTheFullHeightWithTheKeyboardDown` (a 75.7 pt band while watching before; under one row in portrait and landscape, keyboard up and down, after) and `SSHTypingChromeTests.testTheTerminalUsesTheFullHeightWithTheKeyboardDown` (60 pt in portrait and landscape before; none after). Unit tests: `KeptPairedTerminalTests.testKeyboardButtonFloatsOverTheTextAndReservesNoSpace` and `testKeyboardButtonStaysOffTheCursor` (a full last line with the cursor at its end: the button rises clear of it with the grid unchanged, and returns when the screen clears). `TerminalKeyboardInsetTests.testWatchingFitIsTheKeyboardHiddenSizeAndFillsTheView` now expects the whole view.

### 2. Back keeps a paired terminal connected

Before, Back on a paired terminal detached it (and `RemoteTerminalWorkspace.onDisappear` aborted it), so reopening reconnected and redrew. Now Back (the button, the edge swipe, switching terminals from the title, an SSH terminal taking the tab) keeps it connected, as SSH terminals already were.

- **The renderer belongs to the model** (`PairedTerminalHost`, like `SSHTerminalHost`), not to a view; the SwiftUI view only places its surface. Off screen it keeps taking the Mac's output, and since the phone acknowledges what its renderer has taken (Round 13 flow control), acknowledgements keep flowing: the Mac never stalls, or times out, a terminal that isn't on screen.
- **Back while typing stops typing first**, as hiding the keyboard does (Rounds 16 and 17): the Mac gets the watching size, typing is let go with the detach ACK (the typing renderer stays until then), and a watching link with its own renderer takes over. All of this happens after the list is already back (`KeptPairedTerminal.State.releasing`). A release that fails disconnects the terminal; nothing is resent, and typing is never held off screen.
- **Reopening is instant**: the same renderer and attachment, with no new link, no Opening…, and no resume cover. It shows watching; the keyboard button or a tap types, as usual.
- **Terminals shows Connected** on a row with a live attachment, on screen or kept: the same green `StatusBadge` ("Connected", `WitermSymbols.connected`) as a connected SSH host's card, and ", connected" in its VoiceOver value.
- **Limits.** The relay server allows a device 4 tunnels at once (`maxClientTunnels`). An attachment holds one for as long as it lasts, and listing a device's terminals (and, while watching, who types there) needs one for a moment. So **at most 3 paired attachments** stay connected, the one on screen included, across relay servers (`PairedKeepAlive.limit`). Opening a fourth disconnects the one left longest ago, after its detach ACK and before the new one attaches, and the new terminal says so for 8 seconds (dismissable, and spoken): "Disconnected “Terminal 1” to keep 3 terminals connected. It keeps running." Listings wait for a free tunnel (`TunnelGate`), so three kept terminals and several devices never ask for a fifth.
- **Memory.** Each renderer keeps its screen and SwiftTerm's 500 lines of scrollback, so it's bounded; `PairedTerminalHost.approximateBytes` estimates about 0.5 MB of cells at 45 columns. Measured as the process footprint (layout probe) on the simulator: 67.2 MB with one terminal open, 69.1 MB with one kept and one open, 80.1 MB with two kept and one open, and 80.7 MB at the limit with a fourth opened (three live). That's about 13.5 MB for three live paired terminals, most of it the first renderer's caches.
- **Background.** Round 17's 3-minute rule applies to every kept terminal too. Each is detached with its ACK five seconds before iOS's background time ends (its screen and renderer kept), resumed in place with a new watching link when the app returns within 3 minutes, and disconnected after that.
- **Endings still end them.** Revocation (a kept link failing with a trust error removes the device and shows No Longer Paired); Unpair and End Invitation… (each kept terminal of that grant is detached with its ACK first); the Mac ending the terminal (its row leaves at once); a device listing that no longer has the grant. A transient network failure of a kept link is resumed in place once; if that fails, it's disconnected and its row stops saying Connected.

### 3. Disconnect

iOS has one word for ending a connection: **Disconnect**, for paired terminals and SSH hosts alike.

| Where | Paired terminal | SSH host |
|---|---|---|
| Row, trailing swipe | Disconnect (gray), only while connected; never a full swipe | Disconnect (gray) while connected, never a full swipe; Delete Host (red, full swipe, Undo) while not connected |
| Row, long press | Disconnect, only while connected; on Shared with You, also End Invitation… (red, confirmed) after a divider | Favorite, Edit Host, Host Keys, then Disconnect, then Delete Host (red) last, after a divider |
| Terminal ⋯ menu | Disconnect, last, where Leave was | Disconnect, last (no longer red) |
| Hardware keyboard | Disconnect (Leave is gone from the iOS command list) | Disconnect |

**No full swipe, no confirmation.** Disconnecting is reversible (reopening connects again, and a paired terminal keeps running on its Mac), so it asks nothing and isn't red. But an SSH disconnect ends the remote shell, so a single full swipe shouldn't do it by accident, and a swipe should behave the same on every connected row; the full swipe stays with Delete Host, which Undo restores. Delete Host never sits beside Disconnect in a swipe, and in menus it's last, red, after a divider. The phone can't end a Mac terminal (`close` is never accepted remotely, [protocol/relay-v1.md](../../protocol/relay-v1.md)), so the paired item's hint says where it keeps running: "Keeps running on *device*." in the terminal menu, and "The terminal keeps running on the other device." on rows. The Mac keeps Leave for its windows.

Tests that fail first (before, the row had no Connected badge after Back, and the menu said Leave): `PairedKeepConnectedTests` (5): Back keeps the terminal connected and reopens it with the same link and no cover; Disconnect by swipe (a full swipe only reveals it), long press and the ⋯ menu; a fourth terminal disconnects the oldest, with the note; the fixture Mac ending a kept terminal (`exit`) takes its row away; Unpair lets its kept terminals go. Unit tests: the renderer takes output off screen (`testHostTakesOutputOffScreen`), the eviction order, and the tunnel gate.

**Fixture (DEBUG):** typing `exit` and Return in a fixture terminal ends it 10 s later on every link and drops it from the list, as a shell would.

### 4. Offline shows at once

The owner: "The home screen indicators should update immediately when a device goes offline."

**How status was learned.** Only by listing a device's terminals through a relay tunnel, and only when the list appeared, on pull to refresh, on returning to the app, or on Back: a Mac that dropped off while the list was on screen stayed Online indefinitely. A terminal's link failing didn't touch the status either.

**Now, three ways, cheapest first:**

1. **Events.** When any terminal's link to a device fails (on screen or kept after Back), the device is listed again at once; the relay server answers `host_offline` when the Mac has gone, and `RelayError.offline` from anywhere sets Offline directly (`RemoteTerminalModel.linkDropped`). The server drops a Mac's tunnels the moment it drops the Mac, so this is as fast as the server.
2. **The presence stream** (new, in the server's code, **not deployed**): while Terminals or Devices is on screen and the app is active, the phone keeps one WebSocket per relay server, `GET /v1/relay/presence`, and the server pushes each watched grant's Mac connecting or dropping. One socket replaces a tunnel per check, so it costs neither the 4-tunnel cap nor the 30-a-minute rate (one open when it starts). Design and limits: [protocol/relay-v1.md](../../protocol/relay-v1.md), "Presence"; Go in `server/internal/relay/presence.go`, Swift in `RelayPresence` (WitermCore). It isn't listed among `/v1/info`'s capabilities; the phone tries it and treats 404 as "not here".
3. **Polling** when there's no presence stream (today's deployed server, or while the stream is down): every device is listed again every 15 seconds while a list is on screen (4 tunnel opens a minute per device; listings wait for a free tunnel), and at once when the app becomes active or the network comes back (`NetworkStatus`' `NWPathMonitor`).

Devices' rows now say Online or Offline too, from the same state.

**Measured** on the simulator with the fixture Mac dropping off the relay (`-witerm.debug.fixtureOfflineAfter`), from the drop to the test seeing Offline in Studio's header (`DeviceStatusTests`, polling every 50 ms):

| | Before | After, with presence | After, polling (`-witerm.debug.fixtureNoPresence`) |
|---|---|---|---|
| Terminals on screen, nothing open | never (over 40 s) | 0.24 s | 4.2 s (at most 15 s) |
| A terminal kept connected after Back | never (over 40 s); its Connected badge went, the device stayed Online | 0.17 s | 0.24 s (its link failing lists the device at once) |

On a real relay server, "the moment the server knows" is at once for a Mac that disconnects cleanly (its service stops, the Mac sleeps with Wi-Fi off cleanly) and up to about 20 seconds for one that vanishes (the server's 15-second pings with a 5-second deadline). Not run: the presence stream against a deployed server (it isn't deployed); the Go integration test runs it end to end against PostgreSQL (`TestPresenceStreamIntegration`: Online in the snapshot, Offline under 2 s after the Mac's host connection closes, another device sees nothing).

### 5. Native system components

The owner: the "Device is offline" box (the paired terminal's custom connection card) should be native, and so should similar custom components elsewhere. The audit, what replaced each component, what stays custom and why, and the Mac's candidates (not changed) are in [native UI audit (iOS)](native-ui-audit-ios.md). In short: the terminal's connection states are now `ContentUnavailableView` over the system material (with the system `ProgressView` while connecting); `IssueBanner` is a `GroupBox` with a `Label`; `StatusBadge` is a plain `Label` in the status color; the offline device's row, the camera-unavailable note, the invitation field, the device code and the SSH host-key card use system rows, `ContentUnavailableView`, `.roundedBorder` and `GroupBox`; the Welcome Tour's symbols lose their drawn tiles; notices over a terminal sit on the system `.bar` material. The [Design Guidelines](README.md#design-system) now say to prefer the system component and to state a reason for a custom one. Captures: `.build/screenshots/round18-ios/native-before/` and `native-after/` (`NativeUIScreenshotTests`).

## Round 19: iOS

The owner's three decisions of 2026-11-04, worked on the iPhone 18 Pro simulator through the DEBUG fixture Mac (`FixtureMac`) and the disposable OpenSSH fixture. Captures: `.build/screenshots/round19-ios/` (`before/` on the code before the change, with the new fixture seams; `after/`).

### 1. Catching up…

**Cause.** Typing again (the keyboard button or a tap), hiding the keyboard, and Back while typing each replace the terminal's link with a new one, and a new link gets a new renderer, which starts empty. A resume in place (Round 17) keeps the renderer but resets it. Either way, the Mac's service first sends the terminal's earlier output, ending in a screenful of line feeds that scroll it above the screen, and only then tmux's redraw ([protocol/local-agent-v1.md](../../protocol/local-agent-v1.md), History). Until the redraw arrives, the screen is blank but for the cursor: what the owner saw in the Round 17 joint run (`phone-09d-typing-again.png`). Round 17's still picture covered only the resume in place, for at most 1.5 s, and went as soon as any output paused, so the earlier output alone (with no redraw yet) could already take it away.

**Change.**

- **The old screen stays.** A new renderer for the same terminal (typing or watching again, including the watching link after Back) starts under a still picture of the old one's text (`TerminalSurface.cover(withPictureOf:)`), below the floating buttons, which stay usable. The resume in place keeps its picture of the whole screen. Either picture now stays until the screen has the Mac's redraw, and then until output pauses for 0.15 s (at most 1.5 s more). It's cheap: one snapshot view, made from what's already on screen, and no second renderer.
- **"Caught up"** means the screen (not the scrollback) has any visible character again (`LinkCoordinator.screenHasText`), checked on each output while waiting. A screen that's also blank on the Mac (a cleared full-screen program) counts as caught up once the Mac has sent nothing for 3 s.
- **The note.** If the redraw hasn't arrived 0.4 s after the new link is in place, "Catching up…" shows: a system `ProgressView` and the text on the system `.bar` material, across the top of the terminal like Round 18's notices, but over the terminal rather than above it, so it never changes the terminal's height (that would resize the Mac's grid). It fades in and out (0.2 s, a 0.15 s fade with Reduce Motion), takes no touches, and goes as soon as the screen has the redraw. VoiceOver says "Catching up…" once, and only if it's still there 0.6 s after it appeared, so a note that only flashes isn't spoken.
- **First opens** don't show it: there's no old screen, and "Opening terminal…" already covers the wait.

**Why 0.4 s.** On a good connection the redraw follows the attach reply within a round trip or two; on the fixture, the measured wait was 9 to 63 ms. A progress note that appeared sooner would mostly flash, which reads as a glitch, and anything under about half a second already feels like part of the tap. 0.4 s is above the normal case and well under the 1 s at which a wait stops feeling like a direct response to the tap. It's one constant, `LinkCoordinator.catchUpThreshold`, to tune with numbers from the real relay.

| Typing again with a slow redraw (fixture, redraw 1.5 s late) | Before | After |
|---|---|---|
| Hiding the keyboard, 0.9 s later | Blank, only the cursor (`before/r19-catch-1b-watching-0.9s.png`) | The old screen under "Catching up…" (`after/r19-catch-1-watching.png`); the note went 1.24 s after the tap returned; the renderer waited 1,575 ms |
| Typing again, the owner's case | Blank until the redraw | The old screen under "Catching up…" (`after/r19-catch-2-typing-again.png`); waited 1,712 ms; the note went 0.78 s after the tap returned |
| Fast redraw (the fixture as it is), watch, type, watch, type | No note | No note; the renderer waited 9–63 ms |

Tests that fail first: `PairedCatchUpTests.testASlowRedrawSaysCatchingUpOverTheOldScreen` (no note, no picture before). `testAFastResumeNeverSaysCatchingUp` guards the other side: it never saw a note on the old code either (it failed there only on the new probe fields). Unit tests: `CatchUpTests` (8), with the threshold, the picture staying until the redraw, a fast redraw never showing the note, the blank-on-the-Mac fallback, no note on a first open, and earlier output scrolled off the screen counting as blank.

**Fixture (DEBUG):** `-witerm.debug.fixtureRedrawDelay <seconds>` sends each attach's earlier output at once, ending in a screenful of line feeds as the service does, and the redraw (on attach and on resize) that much later.

### 2. Sized for *device*

**When.** Only while this device watches a grid that isn't its own size (`TerminalSurface.watchesOtherGrid`: the Mac's grid differs from the whole view's fit, `watchingFit`), and the device that set it is known. The Mac gives the grid to the writer who typed last ([protocol/local-agent-v1.md](../../protocol/local-agent-v1.md), Grid owner), so that's the one other writer the Mac lists (`writers`, already in the terminal list; the Mac itself by its paired name). The phone keeps the last non-empty list for the open terminal, since the grid stays as the last of them set it after they stop (`RemoteTerminalModel.gridSetters`). Nothing is added to the protocol.

**Where.** In the title's status line, the plain-facts line under the terminal's name (also the iPad header's status). It's quiet (caption, secondary), always where the person looks to see who types, and costs the terminal nothing.

- While the one other device types, the grid is theirs by the Mac's rule, so one fact says both and the name isn't repeated in a line that would otherwise cut it off ("Typing on Alex’s iPad · Sized for…" in the first capture): **Typing on Alex’s iPad, at its size**.
- After they stop: **Studio · Sized for Alex’s iPad**.
- When someone else types now but the grid is still another's: **Typing on Studio · Sized for Alex’s iPad**. With several writers it's one of them, so **Sized for Another Device**.
- It goes when this device types (its own size applies) and stays gone when it watches again at its own size (Round 17's fit). An older Mac that doesn't list writers shows nothing.

| | Before | After |
|---|---|---|
| Watching Terminal 1 while Alex’s iPad types at 80 × 24 | `Typing on Alex’s iPad` | `Typing on Alex’s iPad, at its size` |
| The iPad stopped; still its grid | `Studio` | `Studio · Sized for Alex’s iPad` |
| This phone types, then watches at its own size (45 × 39 with the watching notice shown) | `Studio` | `Studio` |
| Watching "build" while the Mac types there at 80 × 24 | `Typing on Studio` | `Typing on Studio, at its size` |

Test that fails first: `PairedCatchUpTests.testWatchingAnotherDevicesGridSaysWhoseSizeItIs`. Unit tests in `CatchUpTests`: the wording (one writer, the Mac, several, none, an older Mac) and when the grid counts as another's (never while typing).

**Fixture (DEBUG):** `-witerm.debug.fixtureOtherTyper <seconds>`: "Alex’s iPad" types in Terminal 1 at 80 × 24 for that long after the fixture starts, so the phone opens watching, then may type.

### 3. The simulator's keyboard

Not switched. The approved preference (`com.apple.iphonesimulator`, the device's `DevicePreferences` entry) already said `ConnectHardwareKeyboard = 0`, and Xcode 27.2 has no Simulator.app to apply it; what keeps the software keyboard down is state inside the simulated device. Details and the owner's options are in [handoff.md](../handoff.md), "The simulator's keyboard"; the five UI tests are in [verification.md](../verification.md), Round 19. Found on the way: in landscape the key row's actions menu opens upward, so its items run bottom to top and Port Forwarding and Disconnect start scrolled out of view above Find. The menu works (it scrolls); the test now scrolls it.

## Round 20: connected devices

The owner's decision of 2026-11-04, for a paired-Mac terminal on iOS: "Stop displaying who is typing. Instead, show the number of connected devices, with an option in the top-right corner to view all connected devices." Worked on the iPhone 18 Pro simulator through the DEBUG fixture Mac (`FixtureMac`). Captures: `.build/screenshots/round20-devices/` (`before/` on `main`'s app code with the new tests, `after/`).

### The title

| | Before (Rounds 16 and 19) | After |
|---|---|---|
| Watching Terminal 1 while Alex’s iPad types, Studio's window and Sam’s iPhone watch | `Typing on Alex’s iPad, at its size` | `4 devices connected · Studio` |
| The iPad stopped, its grid still in use | `Studio · Sized for Alex’s iPad` | `3 devices connected · Studio` (or `Studio` when this phone is alone) |
| Watching "build" while the Mac's window types | `Typing on Studio, at its size` | `2 devices connected · Studio` |
| Alone, typing or watching | `Studio` | `Studio` |
| Can only watch, others connected | `Can only watch · Typing on …` | `Can only watch · 2 devices connected · Studio` |
| Connecting, switching, disconnected, ended | the state's words | unchanged (no count while not connected) |
| iPad header | the facts above, or Connected | `2 devices connected`, or Connected |

- **The count includes this device**, and the Mac counts once when its app window, another window or the `witerm` command is attached. It's the Mac's `attached` list ([protocol/local-agent-v1.md](../../protocol/local-agent-v1.md)) with this device added from what it does now, so it's never off by this device even when the list was made before it attached.
- **Alone, no count.** A count of one says nothing the screen doesn't; the HIG asks for information that helps a decision, and collaboration UI on Apple platforms (Notes, Freeform, SharePlay) shows participants only when there are others. So with only this device connected, the line stays as it was: the Mac's name. Connected Devices is still in the menu and says "No other devices are connected."
- **Order** is state first (what limits this device), then the count, then the Mac's name, so a long Mac name is what gets cut. Plural forms are in the catalog (`%lld devices connected`, English one and other, Chinese one form).
- **Nobody is named in the title or in notices.** Round 19's "Sized for *device*" and "…, at its size" are gone; whose size it is lives in the sheet. "Catching up…" is unchanged.

### Connected Devices

A **Connected Devices** item in the terminal's ⋯ menu (after Find in Terminal, before Disconnect), also in the iPad header's ⋯ and the key row's actions menu, since all three are the same items. It opens a system sheet (`NavigationStack` + `List`, inline title, Done, medium and large detents), never a menu from a menu.

- **Rows:** This iPhone (or This iPad) first, then the Mac by its paired name (its icon in the Mac's identity hue, the one color that belongs to a machine here), then the other devices in the Mac's order. Each row says Typing or Watching, and "Sets the terminal size" on the one whose grid the terminal uses. The footer gives the terminal's size (`Terminal size: 80 × 24`; VoiceOver: "80 columns, 24 rows"), and "No other devices are connected." when this device is alone.
- **Whose size, never guessed.** The Mac marks its grid owner ([local-agent-v1](../../protocol/local-agent-v1.md), Grid owner) only while that writer is attached; once it has gone the grid stays as it was and nobody is marked. The phone shows the mark only from a list made on its current link (a list from before typing or watching again could name the wrong device), and its own row only while it types.
- **Live.** The sheet reads the model, which lists the terminal again every 5 seconds while the sheet is open (10 otherwise); a new link while it's open lists again at once. Measured on the fixture: the iPad leaving disappeared from the open sheet 5.7 to 6.9 s after it stopped (three runs), including the test's own reads.
- **VoiceOver:** each row is one element, its name as the label and "Typing, Sets the terminal size" as the value; identifiers `connectedDevice-this`, `-mac`, `-device-N`.
- **Not offered** when the Mac doesn't say who is attached: an invitation's guest (privacy, as for `writers`) and a Mac from before Round 20. Those show no count either; the title names the Mac.

### The watching notice

Round 16's "Another device is typing, so you’re watching." (and its named form) said who types and, once they stopped, said something no longer true (a Round 19 open item). It's now **"Typing wasn’t available, so you’re watching."**: what happened to this device, in the past tense, so it stays true, with a small bordered **Connected Devices** button that opens the sheet, and Dismiss. It shows when typing was refused (the keyboard button, opening a terminal someone else types in, a reconnect), and now also when a tap on a watched terminal keeps watching because the latest list says someone else types (before, the tap only spoke "Typing on *device*" and gave a warning tap, which with the title no longer naming anyone would have left a sighted person with nothing). A refusal's issue title is the plain "Typing on Another Device". Terminals' rows still say "Typing on *device*" before a terminal is opened (not part of this decision; see the questions in the round's report).

### Data and budgets

The phone needed watchers too, so the Mac's `list` for a paired device now carries `attached` (`{name?, mode, grid_owner?, this_device?}`; names only, never device IDs, keys or pairings; omitted for an invitation's guest and by older services). The relay server is untouched; it forwards ciphertext. Polling, not a new frame on the events stream: a frame would need negotiation (older phones fail on an unknown frame kind; older Macs refuse unknown attach fields, which costs a retry tunnel), its own place in the flow-control window, and broadcasts from the service on every attach and detach, for a number that's fine a few seconds late. The phone lists every 10 s while a terminal is connected (6 tunnel opens a minute of the device's 30, as many joins of the Mac's 120) and every 5 s with the sheet open (12), never closer together however often the keyboard switches, and not in the background or after leaving; listings wait for a free tunnel, so 3 kept terminals never need a fifth. A Mac from before Round 20 is listed only while watching a terminal this device could type in, as before.

Tests that fail first: `PairedConnectedDevicesTests` (4: the count and the live sheet; alone; a refused tap; older Macs and invitations), `PairedCatchUpTests.testWatchingAnotherDevicesGridNamesItOnlyInConnectedDevices` (was Round 19's "Sized for" test) and `PairedTerminalFixtureTests.testTappingWhileSomeoneElseTypesKeepsWatching`. Unit tests: `ConnectedDevicesTests` (7). Mac service: `AgentTests` (who is attached, the Mac once over two windows, the grid owner moving when the phone types, a device that left, a guest learning nothing), `LocalAgentSmoke` (a refused paired writer watching sees the Mac as the grid owner and itself marked).

**Fixture (DEBUG):** `FixtureMac` lists `attached` like the service, this device's links included. `-witerm.debug.fixtureWatchers 1`: Studio's own window and "Sam’s iPhone" watch Terminal 1. `-witerm.debug.fixtureOlderMac 1`: the Macs list `writers` but not `attached`. The fixture's invitation terminal ("Demo") now lists neither, as a real guest's.

**Left in place:** `TerminalSurface.watchesOtherGrid` (Round 19), now unused by the title, since the SSH crew was changing `TerminalSurface` at the same time; it can go later.

## Round 20: iOS SSH

Two reports from the owner on the iPhone 17 Pro, 2026-11-04, worked on the iPhone 18 Pro simulator, now with the real software keyboard (see 3), against the disposable OpenSSH fixture. The owner's own server was never contacted. Captures: `.build/screenshots/round20-ssh/`.

### 1. "After entering `ls`, it got stuck, and I couldn't scroll"

**What was tried.** `SSHTypingStuckTests.testLsThenTypingAndScrollingStillWork` types on the system keyboard's own keys (not XCUITest's typing): `ls` as the first command, in a folder with two entries and one with 240 (more than a screen), `ls --color` in `/etc`, with the keyboard down (output under the floating keyboard button, which moves), and in landscape; after each, it types `echo` and checks the host answered, and swipes to check scrolling. Also with 150 ms of added latency each way (a loopback proxy), a prompt like a Linux distribution's bash (it sets the window title and folder, OSC 0 and 7, every time; `ls` aliased to color), and the first-use background tip shown. In English, all of it worked: output in 0.2–0.5 s, typing reached the host every time, swipes scrolled (for example 69 → 55 rows back), and the app idled after each step. The layout-loop, long-output-pause, catch-up-picture and gesture suspects showed nothing.

**Cause.** The owner's language is Chinese, and a Chinese app on an iPhone gets the **Pinyin** keyboard. With the app in Chinese the simulator gave it too, and then `ls` and Return did exactly what the owner described: while composing, nothing appeared in the terminal, and Return, which Pinyin labels **确认** (Confirm) while composing, only put the letters on the line; nothing ran, and with only the welcome text there was nothing to scroll (`ls-before-2/r20-ls-home-1-output.png`). Pinyin composes letters as marked text until a candidate or Confirm commits them, as in every iOS text field. SwiftTerm 1.19 sends nothing until the commit, which is right, but it also draws nothing meanwhile, so the terminal looked dead.

**Change.** Letters being composed show at the cursor, underlined in the tint and on the terminal's own background, as in any iOS text field and in the Mac's Terminal (`TerminalInputView.composingText`, `placeComposing`). Nothing is sent until the keyboard commits; Confirm puts the letters on the line, and Return runs it; a candidate types its characters. The grid never changes for it. SwiftTerm's `setMarkedText(_:selectedRange:)` and `unmarkText()` are public but not open, so the subclass gives its own class Objective-C methods for those two selectors that call SwiftTerm's and then place the composition (`composingHooks`); nothing else of SwiftTerm changes, and SwiftTerm stays at 1.19.0. It applies to paired terminals too (the same renderer).

**Diagnostics (DEBUG).** `com.witerm` / `terminal-input` logs the shape of each committed input (length, Return, ASCII, whether it commits a composition as typed, the keyboard's language) and when a composition begins and ends, never the text; `com.witerm` / `ssh-connect` logs the order of a connection attempt. With the phone on a Mac: `log stream --predicate 'subsystem == "com.witerm" AND category IN {"terminal-input", "ssh-connect", "terminal-layout", "terminal-gestures"}'`.

**Not reproduced otherwise; still unverified on the phone.** Nothing else wedged: in landscape with the software keyboard up the grid was 85 × 9 (the handoff's estimate; a swipe down there also hides the keyboard, `.interactive`). Whether the owner's phone was in Chinese with Pinyin is a guess from the owner's language, not confirmed. If it recurs on the phone in English, the DEBUG logs above (with `terminal-layout` and `terminal-gestures`) are what to capture.

Tests that fail first: `SSHTypingStuckTests.testLsOnAComposingKeyboardRuns` (before: nothing at the cursor while composing; Confirm committed `ls` as typed, `insertText count=2 commitsAsTyped=true`, and only a second Return ran it; after: `composingShown=1` while composing, committed in 0.65 s, Return ran it in 0.56 s). Unit test: `MobileTerminalInputTests.testComposedLettersShowAtTheCursorAndSendNothingUntilCommitted`, through the keyboard's Objective-C selectors.

### 2. Face ID before connecting

The owner's rule: "Face ID verification must be successfully completed before establishing a connection."

**Before (on `main`).** Protected credentials already asked first (`SSHWorkspaceUI.open` → `savedCredentials` → `SSHUnlock`, then `SSHWorkspaceModel.connect`). Three paths connected without Face ID: credentials saved before protection (Round 12) were read with no prompt (`main`'s own unit test asserted "An unprotected credential must not ask for Face ID"); **Cancel** opened the form to type the password and connect; and **Enter Password**, the button after a failed match, did the same. Separately, a jump chain missing a hop's credential, or with an unusable key, dialed its first hop before failing (`testMissingOrUnusableCredentialFailsBeforeAnyHopIsReached`: `connectionRefused` from the closed jump port, before; `missingCredential` and `unsupportedPrivateKey`, after).

**After.** `SSHProfileStore.credentials(_:unlock:)` reads any saved credential, protected or not, only with an `SSHUnlock` that succeeded (`isUnlocked`); otherwise it throws and reads nothing. `SSHUnlock.unlock(reason:)` evaluates `.deviceOwnerAuthentication`: Face ID first, then the system's own Enter Passcode, as `.userPresence` on the items already allows; nothing types the SSH password instead. Cancel or failure connects nothing and says on the host's screen, or on the iPhone's list (which now offers the issue's next step too), "Not connected: “*host*” needs Face ID to use its saved credentials." (Touch ID, Optic ID, or the passcode or login password where that's what protects them), with **Try Again**. `SSHConnection.connect` checks every hop's credential and key before the network. The order, from the DEBUG `ssh-connect` log of `SSHSavedCredentialTests` (`.build/screenshots/round20-ssh/applog-faceid-after.log`): `unlock asked` → `unlock unlocked` → `network start` → `host key received`; after a cancel, `unlock asked` → `unlock cancelled` and nothing else; Try Again asks again before connecting.

| Path | Face ID first? |
|---|---|
| Tap a host, Reconnect, Try Again, Check Connection… | Yes (all go through `SSHWorkspaceUI.open`) |
| Jump hosts with saved credentials | Yes, once for every hop, before the first hop is dialed |
| New host key: the trust prompt's fresh handshake | Uses the credentials read for the same attempt, after its Face ID |
| Credentials saved before protection | Yes (new); saved again with protection after connecting |
| Returning within 3 minutes of backgrounding | Nothing new connects: the same connection carries on, no prompt. Past 3 minutes the connection is closed, and connecting again asks |
| Port forwarding | Runs on an open connection; never connects on its own |
| Hosts without saved credentials | Unchanged: the form asks for the password |

Shared with the Mac (Touch ID or the login password).

### 3. The simulator's keyboard

Switched by the integrator with the owner's approval (`HardwareKeyboardLastSeen` set to NO inside the simulated device); see [handoff.md](../handoff.md), "The simulator's keyboard". The real software keyboard appeared in every Round 20 SSH run, and the two tests that needed it pass without the stand-in.

## Round 21: iOS follow-ups

Two follow-ups the owner approved on 2026-11-05, worked on the iPhone 18 Pro simulator through the DEBUG fixture Mac (`FixtureMac`) and the disposable OpenSSH fixture. Captures: `.build/screenshots/round21-ios/` (`before/` on `main`'s app code with the new tests, `after/`).

### Terminals' rows count connected devices

Round 20 replaced naming typists in a paired terminal's title with a device count, but Terminals' rows still said "Typing on *device*". They now count the same way the title does.

| Row (fixture) | Before | After |
|---|---|---|
| Terminal 1: Alex’s iPad types, Studio's window and Sam’s iPhone watch | `Typing on Alex’s iPad` | `3 devices connected` |
| build: the Mac types (only the Mac) | `Typing on Studio` | nothing extra |
| build, kept after Back (the Mac and this iPhone) | `Typing on Studio`, Connected | `2 devices connected`, Connected |
| Terminal 1 kept after Back, nobody else | Connected | Connected (no count) |
| logs (watch only) | `Can only watch` | `Can only watch` (and the count when there is one: `Can only watch · 2 devices connected`) |
| Any terminal on a Mac from before Round 20 | `Typing on Studio` (from `writers`) | nothing extra, kept or not |
| Shared with You | `Alex’s MacBook · Until the invitation ends` | unchanged |

- **The same count as the title** (`ConnectedDevices.rowCount`, built on the title's `ConnectedDevices.devices`): the Mac once, each other paired device once, and this device only while it's connected here, on screen or kept after Back (`isConnected`, what the Connected badge shows), whatever the list said. So a list made just before this device left doesn't count it, and it's never counted twice. Fewer than two: no count, as in the title.
- **Older Macs and invitations:** no `attached`, no count. Nothing is guessed from `writers` any more; `TypingElsewhere`, which only the rows still used, is gone.
- **Order:** what limits this device first (Can only watch), then the count, as in the title. The Connected badge and the Online/Offline/Checking… header are unchanged.
- **Kept current:** the 10-second listing that keeps the title's count up to date now also updates the row's list (`refreshDevices`), so a row beside the terminal (iPad) or after Back agrees with the title. On the home screen with nothing open, rows update when the list is loaded: on launch, pull to refresh, Back.
- **VoiceOver:** each row is one element. The label is the terminal's name, and the value is the Mac, then "connected" when it's connected here, then the detail: "Studio, connected, 2 devices connected". "Connected" comes before the count so it never directly follows "devices connected". A shared row still reads its detail, then "connected".
- **Strings:** none added or changed (`%lld devices connected` and `, connected` already exist). "Typing on %@" stays: the Mac still uses it (Continue sheet, window subtitle). `docs/design/round21-strings-ios.json` is empty.

Tests that fail first: `PairedConnectedDevicesTests.testTerminalsRowsCountConnectedDevicesAndNeverNameWhoTypes` and `testTerminalsRowsShowNoCountAloneOrFromAnOlderMac` (before: "Studio, Typing on Alex’s iPad", "Studio, Typing on Studio, connected"; after: "Studio, 3 devices connected", "Studio, connected, 2 devices connected", "Studio, connected", "Studio"). Unit test: `ConnectedDevicesTests.testRowsCountAsTheTitleAndThisDeviceOnlyWhileConnected`. `InformationArchitectureTests` now expects "build" to read "Studio".

### SSH: going Home and back keeps the connection

`SSHWorkspaceTests.testDirectSSHTrustTerminalKeyboardAndSFTP` still expected going Home to disconnect SSH immediately (Reconnect, then the password again). That was stale: since Round 17 SSH stays connected for 3 minutes in the background, and since Round 20, returning within that window continues the same connection with no Face ID prompt. The step now types a letter on the shell's line, goes Home, checks the app really left the foreground, and comes back. It checks that the terminal is still there, with no Reconnect, no password form and no trust prompt, that the letter is still on the line (a new shell wouldn't have it), and that the letter can be erased. The Reconnect check the old step carried (a new shell on the same verified pin, with no trust prompt) now follows an explicit Disconnect from the ⋯ menu. The test doesn't wait 3 minutes. Coming back after 10, 60 and 170 s with the same `$$` is covered by `SSHTypingChromeTests.testReturningWithinThreeMinutesKeepsTheSameShell`. Being disconnected past 3 minutes has no SSH UI test: it's `SSHWorkspaceModel.enterForeground` and `closeAfterBackgroundWindow`, and paired terminals have the opt-in `PairedTerminalFixtureTests.testReturningAfterThreeMinutesReconnects` (`WITERM_BG_LONG=1`). No other step was stale: the whole test passes against the fixture, its own cleanup included.

## Round 22: iOS terminal chrome

Four findings from the owner on the iPhone 17 Pro (2026-11-05, Rounds 18–21 build), in a paired-Mac terminal (the coordinator's follow-up), checked on SSH too. Worked on the iPhone 18 Pro simulator with the real software keyboard, through the DEBUG fixture Mac (`FixtureMac`) and the disposable OpenSSH fixture. Evidence: `.build/screenshots/round22-ios/` (`before-paired/`, `before-ssh/`, `after-paired/`, `after-ssh/`, and `video/`: screen recordings of hiding the keyboard before and after, with stills in `before-frames/` and `after-frames/`). "Before" is `main`'s app code (11a0cd3) with the new UI tests.

### 1. One tap didn't bring up the keyboard

**Causes, both on a watched paired terminal.**

- **The Mac's own window counted as "someone else types".** The owner's Terminal 1 is open in the Mac app, whose window is attached as a writer. Since Round 17 a tap on a watched terminal kept watching whenever the latest list said anyone else typed, and since Round 20 that included the Mac (`othersType` counted every typing entry but this device's). But the Mac's own clients always let a paired device type alongside them ([local-agent-v1](../../protocol/local-agent-v1.md), Typing; `AgentBroker.coTypes`), so the Mac would have said yes: the keyboard button worked, and the tap only said "Typing wasn’t available, so you’re watching." `othersType` now counts only other paired devices that type (whose co-typing this device can't see). The fixture had the same mistake (it refused typing wherever the Mac typed), which is why no test caught it; it now lets this device type alongside the Mac, as the service does.
- **A tap right after hiding the keyboard was dropped.** Hiding the keyboard switches to watching 0.4 s later (detach ACK, a new link, Round 19's still picture). While that ran, the terminal had no tap-to-type action, and a tap on the old renderer waited out the double tap's interval, by when the renderer had been replaced and the tap was cancelled. Now a tap (or the keyboard button) during the switch is kept and types once watching is ready (`RemoteTerminalModel.requestTyping`), and the renderer being replaced doesn't wait for a double tap. A tap in the first 0.4 s takes the keyboard back on the typing link, as before.
- **Stale lists:** checked in code, not seen. The Mac marks this device's own entry `this_device`, and it never counts, so a list made while this device typed can't make it "someone else". A list up to 10 s old can still name another paired device that has since stopped typing; the tap then says typing wasn't available until the next list.

**Feedback while the Mac is asked.** A tap or the keyboard button turns the keyboard button into the system button's own activity indicator (VoiceOver: "Showing Keyboard…") until the keyboard rises, instead of the button disappearing with only the title's caption changing.

| Paired, fixture | Before (`main`) | After |
|---|---|---|
| "build" (the Mac types there): open, hide the keyboard, one tap | Opened watching with "Typing wasn’t available"; the tap said it again and asked nothing (links 1 → 1) | Opens typing alongside the Mac; one tap types (spinner 0.69 s after the tap started, typing at 3.2 s with the fixture at 0.6 s a step) |
| Terminal 1, one tap while watching | Typing after 1.73 s (fixture at 0.15 s a step), nothing shown meanwhile | Spinner at 0.71 s (XCTest's tap itself returns at 0.50 s), typing at 3.16 s at 0.6 s a step |
| One tap during the switch to watching, 0.6 s a step | (not reachable on `main`, which ignores the slower fixture) | Types after 2.70 s: the switch finishes, then typing |

**SSH:** one tap brings the keyboard up after the double tap's interval (focused 0.86–1.12 s after XCTest starts the tap on `main`, 1.01–1.05 s after; the tap call itself takes 0.48–0.78 s). Not waiting for the double tap was tried and dropped: the keyboard then rose on the first tap of a double tap, and the grid's resize for it cleared the word the second tap selected. A double tap selects on a paired terminal; on SSH, XCTest's double tap selected nothing on `main` either (recorded, not asserted).

**Diagnostics (DEBUG, for the owner's phone):** `com.witerm` / `terminal-layout` logs `tapToType interactive=… mode=… hiding=… othersType=… devices=[thisDevice,mac+typing,…] writers=N` for each tap on a watched terminal (kinds and modes only, never names), and `terminal-gestures` logs whether the tap recognizer began.

### 2. The bottom buttons after returning to the bottom

**Reproduced as a missing keyboard button with the keyboard down.** Flinging back, Jump to Latest, new output, typing, rotation, keyboard up and down: Jump to Latest showed while away (above the key row) and went at the bottom in every case, on both kinds of terminal (`TerminalFloatingButtonsTests.testTheRightButtonsShowAtTheBottom`, `SSHFloatingButtonsTests.testTheRightButtonsShowOnOneColumn`). What was missing was the keyboard button. A paired terminal passed it an action only while watching, so after the keyboard went down, through the 0.4 s wait and the switch to watching, neither Hide Keyboard nor the keyboard button showed. In the recordings on `main`, the bottom right was empty for **0.74 s** after Hide Keyboard (paired) and **0.43 s** (SSH, where the button was placed for the old text area until the late relayout below); after, it's drawn in every frame.

**The rule now** (`TerminalSurface.keyboardButtonShown`): keyboard up, the key row's Hide Keyboard; keyboard down, the keyboard button whenever the keyboard can come up (the terminal types, watching may ask, or the Mac is being asked). On a typing terminal it focuses it; on a watching one it asks the Mac.

**If the owner still sees a button missing:** DEBUG builds log each show and hide of either floating button with the state that decided it (`buttons latest|keyboardButton shown|hidden focused=… acceptsInput=… action=… pending=… mode=… pos=… canScroll=… overlap=… latest=frame keyboard=frame`, category `terminal-layout`).

### 3. Jump to Latest and Hide Keyboard weren't on one column

| | Before | After |
|---|---|---|
| Portrait, keyboard up: centers of Jump to Latest / Hide Keyboard | 364 / 374 pt (trailing insets 16 and 6 pt) | 364 / 364 |
| Portrait, keyboard down: keyboard button | 364 | 364 |
| Landscape, keyboard up: Jump to Latest / Hide Keyboard | 774 / 726 (the actions key came after Hide Keyboard) | 774 / 774 |
| Landscape, keyboard down: keyboard button | 774 | 774 |

Hide Keyboard now ends the key row on the floating buttons' column, `FloatingTerminalButton.trailing` (16 pt) from the edge or the safe area, with the actions key before it; its symbol is the floating buttons' size (it was the keys' smaller callout). All three are 44 pt system glass. To keep Esc, Ctrl, Tab and the four arrows on a 402 pt iPhone beside it, the keys are 4 pt apart (5 before) and the scrolling keys' last inset is 2 pt (6).

**Open:** in landscape, the actions menu now opens from a key 60 pt further left and shows Text and Colors at its top; `SSHTypingChromeTests.testLandscapeTypingGivesTheTerminalTheBarsRows` no longer reaches SFTP Files by scrolling it (its drags close the menu). Whether every item is reachable by hand wasn't confirmed; check on the phone.

### 4. Hiding the keyboard flickered

Measured from screen recordings (`simctl io recordVideo`, every changed frame, analyzed for where text is on screen and whether the keyboard button's place is drawn; no terminal content kept):

| Hide Keyboard | Before | After |
|---|---|---|
| While the keyboard slides away | The text stayed at the keyboard-up size: a black band grew under it | The text is full height under the keyboard, which slides away over it |
| After the keyboard has gone | The lower 45% blank for 0.24 s (paired) / 0.17 s (SSH), then every row jumped at once | Nothing more |
| The paired switch to watching, about 1 s later | Old and new renderers cross-faded 7.7 pt apart: 5 frames of doubled, dimmed text | No visible change |
| The title and keyboard button during that switch | "Hiding Keyboard…" with a gray symbol, the device count gone; no keyboard button | Unchanged; the button stays |

Causes and changes:

- **The grid waited for the keyboard to be gone** (`keyboardDidHide`, about 0.41 s after the tap). Now, when UIKit says the keyboard will leave (its end frame below the screen) and the terminal is letting it go, the text takes the whole height at once, without animation, under the keyboard (`keyboardLeaving`). UIKit says so from inside the terminal's `resignFirstResponder`, while it still has the keyboard, so the terminal marks that moment (`isResigningFocus`). Probe: the grid changed 2 ms after the will-hide, before the keyboard was gone; on `main` 413–422 ms after it, on both kinds.
- **Typing and watching grids put their part row on different sides.** Round 18 put a watched grid's leftover at the top (the last line on the bottom edge); a typing grid kept it at the bottom. The typing grid now does the same, so the switch lands every row where it was and Round 19's still picture fades over identical text.
- **The switch's status.** While the keyboard's switch to watching runs, the title, its symbol and count, the iPad header and the switch haptic stay as they were (`RemoteTerminalModel.hidingKeyboard`); Back stays disabled for that moment, as before.

Left as it was: content shifts once when the grid grows (SwiftTerm brings lines back from scrollback), and on a paired terminal the Mac's redraw at the new size follows a moment later (tmux draws from the top). In landscape, where the bar steps aside for typing, its return after the keyboard has gone is a second change; not measured this round.

Tests that fail first on `main`'s app code: `TerminalFloatingButtonsTests` (paired) `testOneTapShowsTheKeyboardWhileOnlyTheMacTypes`, `testOneTapShowsASpinnerAtOnceThenTheKeyboard`, `testFloatingButtonsAndHideKeyboardShareOneColumn` and `testHidingTheKeyboardIsOneTransition`; `SSHFloatingButtonsTests` `testTheRightButtonsShowOnOneColumn` and `testHidingTheKeyboardIsOneTransition`. `testOneTapRightAfterHidingTheKeyboardTypes` and `testTheRightButtonsShowAtTheBottom` passed on `main` only because `main` ignores the slower fixture, so its switch was over before XCTest's tap returned; the recordings show the missing button there. Unit tests: `KeptPairedTerminalTests.testKeyboardButtonShowsWhenTheKeyboardIsDownWhileTyping` and `testTypingAndWatchingGridsEndOnTheBottomEdge`, `MobileTerminalInputTests.testHideKeyboardEndsTheRowOnTheFloatingButtonsColumn`.

**Fixture (DEBUG):** `-witerm.debug.fixtureLatency <seconds>` sets the fixture Mac's time per step (0.15 s by default). The fixture's Mac types alongside this device; Alex’s iPad (`-witerm.debug.fixtureOtherTyper`) doesn't, and is now the "someone else types" case in `PairedTerminalFixtureTests.testTappingWhileSomeoneElseTypesKeepsWatching` and `PairedConnectedDevicesTests.testATapWhileAnotherDeviceTypesSaysWatchingWithoutNamingAnyone` (was "build"). The joint `MacContinuityFlowTests` gains the owner's case on the real Mac: hide the keyboard while the Mac's window types, then one tap types (built, not run).

**Verification:** see [verification.md](../verification.md), Round 22: iOS.
