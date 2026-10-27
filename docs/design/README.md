# Design Guidelines

Witerm is a calm, professional tool built from native iOS 27 and macOS controls. The terminal is the work; everything else is a way to reach it. The interface shows only real things: real servers, devices, grants, and sessions, never sample data.

Follow Apple's guidance on [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass), [materials](https://developer.apple.com/design/human-interface-guidelines/materials), [motion](https://developer.apple.com/design/human-interface-guidelines/motion), and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). Glass belongs to controls. Content sits on solid surfaces.

## Brand

The mark is a W stroke with a cursor at its lower right, on a graphite tile. The cursor cycles through the machine hues (rose, amber, mint, sky, violet), because color in Witerm belongs to machines. The tinted iOS icon uses a single-color cursor. Small sizes keep one clear silhouette, with no gradient text or embedded name.

`swift scripts/GenerateBrandAssets.swift` regenerates every asset:

- the vector mark (`design/brand/witerm-mark.svg`)
- the interface PDF (`BrandMark.imageset`)
- the iOS icons (default, dark, tinted)
- the macOS icons (16–1024 px)

Color tokens live in the asset catalog, not in the script.

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

### Host Spectrum

The interface is neutral graphite. `IdentityHue` gives each SSH host and each paired device one of ten hues. That hue marks the machine everywhere it appears:

- its rows and icon tiles
- its Connect button
- its route diagram
- the top edge of its open terminal

So you can always see which machine receives your typing. The local Mac stays uncolored.

- **Assignment.** A machine gets the least-used hue when it first appears and keeps it. Deleting a host frees its hue.
- **Contrast.** Each hue has light and dark variants that keep 4.5:1 on Surface, on their own 12% tint, and under ActionLabel.
- **Mac exception.** The Mac sidebar keeps the system accent for selection, and the Mac target sets no global accent, so AppKit controls stay native.

## Navigation

**Mac**: one sidebar with three sections. The detail pane shows the selected item.

- **This Mac**: local sessions, including those started with `witerm`. Selecting one attaches with control; the context menu offers View Only, Share or Stop Sharing, and End Session. Shared sessions show an antenna. The terminal header has Share, and a bar under it says whether paired devices can reach the session and who is connected.
- **SSH Hosts**: saved hosts. The detail pane shows the route, Connect, Edit, and More (Host Keys, Delete), and becomes the terminal once connected. Connected hosts show a filled icon.
- **Paired Devices**: Allow Remote Access and pairing, with one row per saved server.

An empty This Mac points to `witerm new`. Settings has General, Terminal, and Command Line (install the command, copy examples). A footer opens Settings (⌘,) and summarizes server health (for example "3 Servers · All Reachable"). File → New Terminal Session (⌘N) and New SSH Connection (⇧⌘N), and View → Refresh (⌘R), are in the menus.

**iOS and iPadOS**: three tabs.

- **Devices**: server setup at first. Once a server is verified, it lists paired devices grouped by server, then sessions, then the terminal. A server with a problem says why in its own section.
- **SSH**: saved hosts and their sessions.
- **Settings**: one section per server (status, check, edit, Device Pairing, remove), plus Terminal Display.

The tab bar hides while a terminal is open.

**Several servers.** Up to 8 servers are saved and used at once. A second spelling of the same server is rejected.

- Identities and grants belong to one server, so pairing through one never authorizes another.
- Removing a server hides its devices but doesn't revoke them. On the Mac, it also turns off remote access through that server.

## Interaction principles

- **One clear next action.** Before setup, that's "Add Server". Never show actions that can't work yet.
- **Honest status.** Distinguish not set up, checking, reachable, and failed, and show when a check succeeded. Servers are rechecked at launch and on return to the foreground. A recheck never tears down an open terminal.
- **User control.** Everything that waits can be cancelled, and stale results never overwrite newer ones.
- **Specific recovery.** Validate addresses before saving. Tell offline, timeout, DNS, certificate, version, and server errors apart, each with a next step.
- **Native conventions.** Standard sidebars, tabs, sheets, menus, keyboard shortcuts, and copy behavior. Return submits, Escape cancels, and ⌘Return runs the Mac's primary action.

## Components

Shared components are in `apps/apple/Sources/Design/Components.swift`. Use them instead of local copies.

| Component | Use |
|---|---|
| `PrimaryButton` | The one prominent action in a view. Glass on iOS/macOS 26+, bordered with Reduce Transparency or on older systems. |
| `witermCard()` | Solid content surface: 20 pt corners and padding, Surface fill. |
| `IssueBanner` | A recoverable problem with recovery text and actions. Never color alone. |
| `ActivityRow` | Real, cancellable work in progress. No invented percentages. |
| `StatusBadge` | Symbol plus text in a neutral, positive, or warning tone. |
| `TerminalHeader` | Status and actions for every terminal. The Mac omits the title (the window already shows it). |
| `PageHeader`, `IconTile` | Pane titles; decorative icons hidden from VoiceOver. |

**Sizing.** `WitermMetrics` defines one scale: 16 pt card padding, 20 pt page padding, 20 pt corner radius, and a 32 pt icon tile. `witermControl()` gives large capsule controls on iOS and regular ones on the Mac. Titles use `title2`, card titles `headline`.

## Motion

| Moment | Motion | With Reduce Motion |
|---|---|---|
| First appearance | 12 pt offset and fade (spring 0.6 / 0.92) | 150 ms fade |
| State change | 5 pt offset and fade (spring 0.38 / 0.88) | 150 ms fade |
| Waiting | Native indeterminate progress tied to the real request | Static icon and text |
| Success or failure | Text, symbol, and haptics on iOS | Nothing extra |

No invented percentages, minimum loading times, or idle glow effects. With Reduce Transparency, use standard button styles and solid content.

## Accessibility

- Support Dynamic Type, VoiceOver, light and dark mode, Reduce Motion, and Reduce Transparency.
- Free-standing iOS controls get 44 pt touch targets (`touchTarget()`). Form and List rows already do. Mac controls keep their native size.
- At accessibility text sizes, setup becomes a single scrolling column and primary actions move into the content.
- Status always pairs a symbol with text. Decorative icons are hidden from VoiceOver.
- Connection start, success, failure, and cancellation are announced.

## Wording

Remote machines are **devices**, and the machine on the other end of a pairing is **the other device**. Only the machine the app runs on gets a platform name ("This Mac"). Windows and Linux machines are reached through SSH, so copy must not suggest they can be paired.

## Screenshots

[iOS dark start screen](screenshots/01-empty-dark.png) · [iOS pairing](screenshots/02-pairing-ios.png)

Testing notes are in [Verification status](../verification.md).
