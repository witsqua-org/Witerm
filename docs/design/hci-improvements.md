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

Device continuation, from the review of 2026-10-28 ([issue #3](https://github.com/FoLAWy-py/Witerm/issues/3)).

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
