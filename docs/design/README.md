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

One sidebar with two sections, everything a person can open; the detail pane shows the selection. Rows say what each terminal is doing: the title and folder the shell reports, or else its last line, as last seen while the terminal was shown here.

- **This Mac.** Local sessions, including ones started with `witerm`. Selecting one attaches with control. The context menu offers View Only, Continue on Another Device…, Stop Sharing (for shared sessions), Rename…, and End Session. Shared sessions show an antenna, private ones a lock, and a session open on another device shows `laptopcomputer.and.iphone` (with a count above one) and names the devices in its help and VoiceOver value. An open terminal fills the pane, with no header or status bar: the window title names the session, and the subtitle appears only when there's state worth a glance (View Only; which devices can type or are viewing; Private; Remote Typing Paused; Shared, Shared · Connecting…, or Shared · Remote access off). The toolbar holds Pause Remote Typing (only while another device can type, or Allow Remote Typing while paused), Continue on Another Device…, and More (Rename…, Keep Private, Pause Remote Typing, Stop Sharing, Leave, End Session). VoiceOver announces a device joining or leaving. An empty list points to `witerm new`.
- **SSH Hosts.** The detail pane shows Connect, Edit, and More (Host Keys, Delete), plus the route when it has jump hosts. Connected, it becomes the terminal: `user@host:port` as the window subtitle, a 2 pt line in the host's hue above the terminal, and SFTP Files, Port Forwarding, and Disconnect in the toolbar. Connected hosts show a filled icon.
- **Keyboard focus.** A terminal you open takes the keyboard at once, with no click: ⌘N, ⌘1–⌘9, ⇧⌘] and ⇧⌘[, a click on a sidebar row, Connect, Return on a sidebar row (which also connects a host or a session that isn't open), and closing a sheet over it. Arrowing through the sidebar only browses: focus stays in the list until Return.

Only while remote access is on, a one-line footer says whether this Mac is reachable (Remote access on · Online, Connecting… until the server accepts this Mac, or Local terminal off when the service isn't running), from what the background service reports rather than the setting alone. Its tooltip and VoiceOver label name the server, and it opens Settings → Devices, which shows the same live state, as does the Continue sheet's Open step. With remote access off there's no footer; setup starts from Continue on Another Device. Settings has General, Terminal, Snippets, Devices, and Command Line, every tab at one 640 × 600 size so switching never resizes the window. **Devices** holds the continuation server (the picker, its status, Allow Remote Access, Manage Servers…), paired devices with an Edit sheet each (what it can open, typing, its code, Revoke), and invitations in effect; it's an admin task, so it isn't in the sidebar beside the terminals. Menus: File → New Terminal Session (⌘N: a session named Terminal N opens at once, ready to type; the toolbar's + does the same, and holding it also offers New SSH Connection), New SSH Connection (⇧⌘N), Import SSH Hosts…, and Continue on Another Device… (⌥⌘P; Pair a Device… when no session is selected); Edit → Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G), Use Selection for Find (⌘E); View → Refresh (⌘R); Terminal → open terminals by name (⌘1–⌘9), Show Next and Previous Terminal (⇧⌘] and ⇧⌘[), Rename Session… (⇧⌘R), Pause or Allow Remote Typing (⇧⌘P), End Session, Insert Snippet (⌥⌘1–⌥⌘9); Help → Welcome Tour. The toolbar has no Refresh: the list updates on its own, and ⌘R stays in View. Sidebar search also matches local session names.

### iOS and iPadOS

The app opens on Terminals. On first launch the **Welcome Tour** comes first (see Flows). With nothing set up, Terminals shows three ways in: **Connect to an SSH Host**, **Continue from Another Device**, and **Import SSH Hosts**. SSH needs no server, and continuing needs no server setup first, because the invitation names its server.

Tabs follow intent, not transport: people think "my terminals" and "my devices", not "SSH" versus "relay".

- **Terminals.** The home. **Open** lists live SSH terminals and ones that disconnected while the app was open, each as a card in the host's hue with its address and folder, its last line, what's running, and when output last arrived; a disconnected card says Disconnected, and tapping it reconnects. **Devices** follows: paired devices (a device sharing one terminal opens it directly; otherwise its terminals, then the terminal; a device this one can only watch says Can only watch) and saved SSH hosts with favorites first, then recent-first ordering. Search and the Favorites Only filter appear once there are eight or more hosts. With nothing set up, the home shows three ways in, each with what it needs. On a regular-width iPad the list stays beside the terminal and the tab bar stays available; compact layouts use a Terminals back button. When a device is unpaired while open here, its terminal closes at once and a No Longer Paired banner on Terminals says why until dismissed.
- **Devices.** Managing what terminals run on. **Continue from Another Device** comes first. **Paired Devices**, grouped by server only when several servers have devices, each saying what this device may do there (Can watch and type, or Can only watch) and with Device Details (the device, its relay server, Access, and its code). A server with a problem says why in its own section. **SSH Hosts**: every saved host with its actions (Edit Host, Host Keys, Delete Host), plus Add Host and Import SSH Hosts…. Tapping a device opens its terminal in Terminals.
- **Settings.** A short index in three groups. **Appearance**: Text and Colors (text size, color scheme, contrast, with its own reset) and Bell and VoiceOver. **Keyboard**: Keyboard Row and Snippets. **Connections**: Relay Servers, one row with the worst server status; its page lists one row per server, and each server's page keeps check, edit, and Remove set apart. **Help**: Welcome Tour. Each row shows its current value; there are no explanatory footers.

The tab bar hides while a terminal is open on compact layouts. With a hardware keyboard, the same menu commands work (except New Terminal Session), and holding ⌘ lists them.

### Flows

- **Continue on Another Device.** A Mac sheet with one question and one primary action per step: **Server** (only while something blocks: no server, the local service off, a failed check, no continuation, remote access off), **Device** (a paired device, Pair a New Device, or Someone Else's Device for a one-time invitation), **Approve** (compare the code, then what it can open, defaulting to the session you started from, and Can Type), and **Open**, which shows real status until the device connects. With nothing paired yet, Device goes straight to the code for a new device, and Back offers Someone Else's Device. The strip names the steps on your path; done steps are checked and skipped. Approve has no Return shortcut. The code screen names its server, with Change…. Without a session, the same sheet is Pair a Device.
- **Welcome Tour (Mac).** On first launch (while `witerm.onboarding.completedVersion` is below 1) a 440 × 320 sheet shows four pages, each a symbol, a title of five words or fewer, and one line: sessions keep running after you quit; the background service, switched on right on the page when it's off; Continue on Another Device (⌥⌘P); and `witerm new`. Return or → moves on, ← goes back, Esc or Skip closes it, and Get Started on the last page opens a new session with the keyboard in it when there's none yet. Finishing or skipping stores version 1. Help → Welcome Tour opens it again.
- **Continue from Another Device.** On iOS it opens to the camera, with Paste and Type Invitation…. Without a camera, or without permission, a short note replaces the camera frame, so Paste stays on the first screen. Typing puts the camera away so the field and Continue stay above the keyboard, and Return continues. At accessibility text sizes the actions come first. After a typed or pasted invitation, the way back says Use Another Invitation rather than Scan Again. It reads pairing codes and one-session invitations, shows the other device's code and server on one screen (a scanned code for a saved server skips it), adds a new server only on the person's tap, shows this device's code while waiting, and opens the terminal as soon as it's approved. A one-terminal invitation shows its Access (Can watch and type, or Can only watch); one that can type says Request Access and waits for approval, one that can only watch says Watch and opens at once. One server choice, `ServerList.selected`, is used by every Mac pairing screen.
- **Server addresses.** A bare host gets `https://` (plain HTTP only on this device), and the field says what it will connect to. SSH logins and port 22 offer Add as SSH Host…; paths, credentials and plain HTTP offer a one-click fix; a pasted invitation offers Use Invitation. Check failures name the host and tell a non-Witerm answer and a server that isn't ready apart.
- **Input destination.** Every live terminal names where typing goes: `user@host:port` for SSH, the Mac's name for paired terminals, This Mac for local ones. A paired terminal always shows your state in words and a symbol: Typing or Watching, a switch in progress (Switching to Typing… or Switching to Watching…, input off until confirmed), or Disconnected or Terminal Ended for a kept last frame. On iPhone the navigation bar is the header for both SSH and paired terminals: the name, a hue edge under it, and only the keyboard button and an actions menu beside it. Under the name, SSH shows `user@host:port`; a paired terminal shows the state, then the device (Typing · *device*), so a long device name never hides the state. An SSH terminal can always type, so its header says Connected. When a reconnect finds another device typing, a note says so (Another device is typing, so you're watching).
- **After connecting (iPhone).** A terminal that can type brings up the keyboard as soon as it connects, so the first tap is a key. The keyboard button's symbol says whether it will show or hide the keyboard. The actions menu (`ellipsis.circle`) starts with smaller and larger text, then Find, then the rest, with Disconnect or Leave last. On a paired terminal, Stop Typing or Start Typing names the switch from the current state, and the title changes at once (VoiceOver announces Typing or Watching when it's done); a terminal this device can only watch shows Start Typing dimmed, with Can only watch under it. Leave goes back to the device's terminals, where the one just left is still listed, because it keeps running. With other terminals open, a chevron beside the title switches to one of them (for a paired device, through the same detach-then-attach as any switch). Back buttons are symbols with spoken names.
- **Saving vs. connecting.** One address field takes `user@host:port` and shows what it understood as User, Host, and Port chips. Key sign-in offers New Key (made on the device, with its public key to copy) or Existing Key (an imported file) as two cards; pasting stays available. New hosts offer Connect or Save for Later at the bottom of the form, within reach of a thumb; editing uses Save and never connects. Name and jump hosts sit under More Options. Errors appear beside their field, and focus moves to the first one. Changing the endpoint clears its credentials, with an explanation.
- **Connection lifetime.** The first time an SSH terminal is on screen, iOS says once, in one line, that SSH stops in the background and suggests tmux; afterwards it keeps the host on screen with the reason and Reconnect. Reconnecting opens a new shell and never replays input. Local Mac sessions keep running after a disconnect; End Session lives under More and keeps its confirmation.
- **Welcome Tour (iOS).** Three pages on first launch: Connect over SSH, Continue from Another Device, and Keys and Gestures (with a miniature of the key row). Each has a symbol, a title, and one line; Skip is always on screen, and the last button is Get Started, which lands on Terminals. Settings → Help → Welcome Tour reopens it. The finished version is stored as `witerm.onboarding.completedVersion` (currently 1); UI tests pass `-witerm.onboarding.completedVersion 1` to skip it.
- **Mobile keys.** A sideways-scrolling row of Esc, Ctrl, Tab, and the arrows (which fit an iPhone's width), then Ctrl+C, Paste, Snippets (once a snippet is saved), and symbols, with 44 pt targets and labels. Ctrl announces its state and resets after one key. Multiline paste is confirmed first and discarded if the connection drops. A terminal you're watching can't send these. Reading selection stays separate from IME selection.
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
| `TerminalHeader` | Destination, input state, and actions for iPad and iOS terminals. The Mac uses the window title, its subtitle, and the toolbar instead, so the terminal gets the whole pane. |
| `TerminalActivityCard` | A live or recently disconnected terminal on a list: hue edge, address and folder, last line, what's running, and age. Reads `TerminalActivity`, which comes from the terminal's own renderer, updates at most once a second, and lives only in memory. |
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

One word per idea, the same on both platforms and in both languages. A label names what happens or what the person can do, never the mechanism. When a short label can't carry it, add help (a Mac tooltip, an iOS VoiceOver hint or menu subtitle) instead of more visible text. A user should never need the docs to know what a control does or what state they're in.

**Things**

| Term | Meaning | Not |
|---|---|---|
| terminal (终端) | A shell Witerm keeps running on a Mac, with its programs. It keeps running when nobody has it open. | session (only the CLI and protocol docs say session) |
| SSH host (SSH 主机) | A machine you sign in to with SSH. | server |
| relay server (中继服务器) | The Witerm server your devices pair and connect through. | continuation server, server alone where an SSH host could be meant |
| paired device (已配对设备) | Another of your devices that may open this Mac's terminals. The one at the other end of a pairing is the other device. | — |
| code (验证码) | A device's fingerprint, compared by eye. | fingerprint |

**Your own view of a terminal.** Two states, named by what you can do: **Typing** (可输入) and **Watching** (仅观看), where nothing you press is sent. **Open** opens a terminal so you can type; **Watch** opens it without typing. While it's open, **Stop Typing** and **Start Typing** switch. Only one place types at a time; when it's elsewhere, say where (Typing on *device*). **Connect**, **Reconnect** and **Disconnect** are only for SSH hosts and network connections, never for opening a terminal on a Mac.

**What another device may do.** **Can watch and type** (可观看和输入) or **Can only watch** (仅可观看); which terminals: **All terminals**, **Only “*name*”**, or **Terminals you choose**. Never "View Only", "can read", "Can Open", or "Can Type" on its own. Ending a pairing is **Unpair…** (取消配对), and its confirmation says what the device loses and that pairing again restores it.

**Verbs.** **Leave**: stop showing a terminal here; it keeps running. **End Terminal…**: stop the shell and its programs (confirmed). **Disconnect**: close an SSH connection, and with it the remote shell. One icon per idea: Leave the door arrow, Disconnect the circled cross, sharing the antenna, pairing the link, watching the eye, typing the keyboard. Continuing between devices uses `laptopcomputer.and.iphone`; `qrcode.viewfinder` appears only on a control that only scans.

**Devices.** Name devices by role (this device, the other device), never by platform, except the device the app runs on (This Mac).

**State and feedback.**

- Any state that limits what the person can do (watching, typing elsewhere, remote typing paused, remote access off, offline, disconnected) is visible while it lasts, where they're looking, with words and a symbol.
- Menus and buttons that switch a state show the current one: a checkmark or a toggled title, never two items that look the same before and after.
- Every action changes something visible at once. If nothing on screen would change, confirm briefly; if it takes longer than a moment, show progress that can be cancelled.
- Fix confusing words with better words, not more of them.

## Screenshots

[Mac, empty, dark](screenshots/01-empty-dark.png) · [iOS pairing](screenshots/02-pairing-ios.png) · [iOS task choice](screenshots/03-task-choice-ios.png)
