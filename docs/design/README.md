# Design Guidelines

Witerm is a calm, professional tool built from native iOS 27 and macOS controls. The terminal is the work; everything else is a way to reach it. The interface shows only real things (servers, devices, grants, sessions), never sample data.

Follow Apple's guidance on [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass), [materials](https://developer.apple.com/design/human-interface-guidelines/materials), [motion](https://developer.apple.com/design/human-interface-guidelines/motion), and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). Glass belongs to controls; content sits on solid surfaces.

The [HCI improvements](hci-improvements.md) page records each round of interaction changes and where they live in code.

## Brand

The mark is a W stroke with a cursor at its lower right, on a graphite tile. The cursor cycles through the machine hues (rose, amber, mint, sky, violet), because in Witerm color belongs to machines. The tinted iOS icon uses a single-color cursor. Small sizes keep one clear silhouette, with no gradient text or embedded name.

`swift scripts/GenerateBrandAssets.swift` regenerates the vector mark (`design/brand/witerm-mark.svg`), the interface PDF (`BrandMark.imageset`), the iOS icons (default, dark, tinted), and the macOS icons (16–1024 px). Color tokens live in the asset catalog, not the script.

## Color

| Token | Light | Dark | Use |
|---|---|---|---|
| AccentColor | `#17181C` | `#ECEEF2` | Primary actions, iOS tint |
| ActionLabel | `#FFFFFF` | `#0F1013` | Text on the accent and on machine hues |
| Ink | `#111215` | `#ECEEF2` | Primary content |
| SecondaryInk | `#5A5F6A` | `#8F95A0` | Explanations and status |
| Canvas | `#F4F5F7` | `#0F1013` | Background |
| Surface | `#FFFFFF` | `#17181C` | Cards |
| Positive | `#1A7F4B` | `#5BD68A` | Health not tied to a machine (reachable server, attached session, switches) |
| Warning | `#A04D00` | `#FFB340` | Recoverable errors |

Every pairing reaches at least 4.5:1 on Canvas and Surface.

### Host spectrum

The interface is neutral graphite. `IdentityHue` gives each SSH host and paired device one of ten hues, used everywhere that machine appears: its rows and icon tiles, its Connect button, its route diagram, and the top edge of its open terminal. You can always see which machine receives your typing. The local Mac stays uncolored.

- **Assignment.** A machine gets the least-used hue when it first appears and keeps it. Deleting a host frees its hue.
- **Contrast.** Each hue has light and dark variants that keep 4.5:1 on Surface, on their own 12% tint, and under ActionLabel.
- **Mac exception.** The Mac sidebar keeps the system accent for selection, and the Mac target sets no global accent, so AppKit controls stay native.
- **Color is never the only signal.** Connection state always uses words and symbols too.

## Navigation

### Mac

One sidebar with three sections; the detail pane shows the selection.

- **This Mac.** Local sessions, including ones started with `witerm`. Selecting one attaches with control. The context menu offers View Only, Share or Stop Sharing, Continue on iPhone, Rename…, and End Session. Shared sessions show an antenna. Under the terminal header, a bar says whether paired devices can reach the session and who's connected. An empty list points to `witerm new`.
- **SSH Hosts.** The detail pane shows the route, Connect, Edit, and More (Host Keys, Delete), and becomes the terminal once connected. Connected hosts show a filled icon.
- **Paired Devices.** Allow Remote Access and pairing, one row per saved server.

A footer opens Settings (⌘,) and summarizes server health ("3 Servers · All Reachable"). Settings has General, Terminal, Snippets, and Command Line. Menus: File → New Terminal Session (⌘N), New SSH Connection (⇧⌘N), and Import SSH Hosts…; Edit → Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G), Use Selection for Find (⌘E); View → Refresh (⌘R); Terminal → open terminals by name (⌘1–⌘9), Show Next and Previous Terminal (⇧⌘] and ⇧⌘[), Insert Snippet (⌥⌘1–⌥⌘9). Sidebar search also matches local session names.

### iOS and iPadOS

On first use, people choose **Connect to an SSH Host** or **Continue from My Mac**. The SSH path needs no server setup. Existing servers or saved hosts skip this choice, and later launches reopen the last tab.

- **Devices.** Server setup at first. Once a server is verified: paired devices grouped by server, then sessions, then the terminal. A server with a problem says why in its own section. Device rows lead with name and permission; the full fingerprint is in Device Details.
- **SSH.** Saved hosts with favorites first, then recent-first ordering. Search and the Favorites Only filter appear once there are eight or more hosts. On a regular-width iPad the host list stays beside the terminal and the tab bar stays available; compact layouts use a Hosts back button.
- **Settings.** A short index. **Servers and Pairing**: one row per server with its status; the row opens the server's page (check, Device Pairing, edit, and Remove set apart). **Terminal**: Display (text size, color scheme, contrast, with its own reset), Keyboard Row, Snippets, and Bell and VoiceOver, each showing its current value.

The tab bar hides while a terminal is open on compact layouts. With a hardware keyboard, the same menu commands work (except New Terminal Session), and holding ⌘ lists them.

### Flows

- **Continue on iPhone.** One checklist sheet from a local session: choose a server, check pairing, allow remote access, and share this session. Readiness comes from the selected server's grants and live relay status. The sheet can also release this Mac's control. On iOS, pairing takes a QR scan or a pasted invitation, both through the same server and fingerprint review; without a usable camera, it offers paste.
- **Input destination.** Every live terminal names where typing goes: `user@host:port` for SSH, the Mac's name for paired sessions, This Mac for local ones. The header shows the input state: enabled, view only, handoff pending (input disabled until confirmed), or Disconnected for a kept last frame.
- **Saving vs. connecting.** One address field takes `user@host:port` and shows what it understood. New hosts offer Connect or Save for Later at the bottom of the form, within reach of a thumb; editing uses Save and never connects. Name and jump hosts sit under More Options. Errors appear beside their field, and focus moves to the first one. Changing the endpoint clears its credentials, with an explanation.
- **Connection lifetime.** The first time an SSH terminal is on screen, iOS says once that SSH closes in the background and suggests tmux; afterwards it keeps the host on screen with the reason and Reconnect. Reconnecting opens a new shell and never replays input. Local Mac sessions keep running after a disconnect; End Session lives under More and keeps its confirmation.
- **Mobile keys.** A sideways-scrolling row of Esc, Ctrl, Tab, Ctrl+C, Paste, and arrows with 44 pt targets and labels. Ctrl announces its state and resets after one key. Multiline paste is confirmed first and discarded if the connection drops. View-only terminals can't send these. Reading selection stays separate from IME selection.
- **Deleting a host.** Immediate, with an Undo bar for 10 seconds instead of a confirmation. Undo restores the host's credentials, color, favorite, and order. Ending a Mac session, revoking a device, and deleting remote files keep their confirmations, because those can't be undone.
- **Offline.** SSH and paired-device views show **No Network Connection** as soon as the device loses its network. When it returns, servers are rechecked; terminals still wait for an explicit Reconnect.
- **Several servers.** Up to 8, used at once; a second spelling of the same server is rejected. Identities and grants belong to one server. Removing a server hides its devices without revoking them, and on the Mac turns off remote access through it.

## Interaction principles

- **One clear next action.** Before setup that's "Add Server". Never show actions that can't work yet.
- **Honest status.** Tell apart not set up, checking, reachable, and failed, and show when a check last succeeded. Servers are rechecked at launch and on return to the foreground, without tearing down an open terminal.
- **User control.** Anything that waits can be cancelled, and stale results never overwrite newer ones.
- **Specific recovery.** Validate addresses before saving. Distinguish offline, timeout, DNS, certificate, version, and server errors, each with a next step. SSH does the same for DNS, refused, timeout, unreachable, jump, sign-in, and algorithm failures; a rejected credential opens the form rather than retrying it.
- **Undo over confirmation** where everything can be restored; confirm only what can't be.
- **Native conventions.** Standard sidebars, tabs, sheets, menus, shortcuts, and copy behavior. Return submits, Escape cancels, ⌘Return runs the Mac's primary action.

## Components

Shared components are in `apps/apple/Sources/Design/Components.swift`. Use them instead of local copies.

| Component | Use |
|---|---|
| `PrimaryButton` | The one prominent action in a view. Glass on iOS/macOS 26+; bordered with Reduce Transparency or on older systems. |
| `witermCard()` | Solid content surface: 20 pt corners and padding, Surface fill. |
| `IssueBanner` | A recoverable problem with recovery text and actions. Never color alone. |
| `OfflineBanner` | No network path, above remote work only. Takes no space when online. |
| `ActivityRow` | Real, cancellable work in progress. No invented percentages. |
| `StatusBadge` | Symbol plus text in a neutral, positive, or warning tone. |
| `TerminalHeader` | Destination, input state, and actions for every terminal. The Mac omits the title (the window shows it). |
| `PageHeader`, `IconTile` | Pane titles; decorative icons hidden from VoiceOver. |

**Sizing.** `WitermMetrics` defines one scale: 16 pt card padding, 20 pt page padding, 20 pt corner radius, 32 pt icon tile. `witermControl()` gives large capsule controls on iOS and regular ones on the Mac. Titles use `title2`, card titles `headline`.

## Motion

| Moment | Motion | With Reduce Motion |
|---|---|---|
| First appearance | 12 pt offset and fade (spring 0.6 / 0.92) | 150 ms fade |
| State change | 5 pt offset and fade (spring 0.38 / 0.88) | 150 ms fade |
| Waiting | Native indeterminate progress tied to the real request | Static icon and text |
| Success or failure | Text, symbol, and haptics on iOS (server checks, pairing, SSH connect) | Nothing extra |
| Undo bar | Rises from the bottom edge (spring 0.38 / 0.88) | 150 ms fade |

No invented percentages, minimum loading times, or idle glow. With Reduce Transparency, use standard button styles and solid content.

## Accessibility

- Support Dynamic Type, VoiceOver, light and dark mode, Reduce Motion, and Reduce Transparency.
- Free-standing iOS controls get 44 pt touch targets (`touchTarget()`); Form and List rows already do. Mac controls keep their native size.
- At accessibility text sizes, setup becomes a single scrolling column and primary actions move into the content.
- Status always pairs a symbol with text. Decorative icons are hidden from VoiceOver.
- Connection start, success, failure, and cancellation are announced.

## Wording

Verbs have fixed meanings. **Leave**: stop watching a Mac session; it keeps running. **End Session**: stop the shell and its programs. **Disconnect**: close an SSH connection (the remote shell ends with it). **Share** and **Stop Sharing**: whether paired devices can reach a session. **Release Control**: hand typing to another device. One icon per idea: Leave uses the door arrow, Disconnect the circled cross, sharing the antenna, pairing the link.

Remote machines are **devices**; the one at the other end of a pairing is **the other device**. Only the machine the app runs on gets a platform name ("This Mac"). Windows and Linux machines are reached through SSH, so copy must not suggest they can be paired.

## Screenshots

[Mac, empty, dark](screenshots/01-empty-dark.png) · [iOS pairing](screenshots/02-pairing-ios.png) · [iOS task choice](screenshots/03-task-choice-ios.png)
