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

