# iOS Information Architecture (Round 16)

The structure of the iPhone and iPad app after Round 16, decided by the HCI lead on 2026-11-04 from the owner's eight requests. Phase A (lists, Devices, Settings, swipe actions, Text and Colors) and Phase B (the terminal's keyboard button and the end of separate typing and watching modes) are recorded in [HCI improvements](hci-improvements.md), "Round 16: iOS structure". Vocabulary is in the [Design Guidelines](README.md).

**Rule for this round:** every function has exactly one place. A keyboard shortcut (⌘N, ⌘1–⌘9) is an accelerator for a function, not a second place. An empty state may point to a function's place in words, but it doesn't repeat the control.

## 1. Inventory before Round 16

Captured from `main` at 52c20f1 on the iPhone 18 Pro simulator (English, light), in `.build/screenshots/round16-ios/before/` (not committed), with the opt-in `AuditScreenshotTests`.

| Screen | Contents | Entry points |
|---|---|---|
| **Terminals** (tab 1) | No Longer Paired banners; first-use rows (Add SSH Host…, Add Device, Import SSH Hosts…); **Open** section (live and just-disconnected SSH hosts as activity cards); an untitled section with paired devices (one row each, chevron) and saved SSH hosts; Favorites Only and Search Hosts once there are 8 hosts | Tab bar |
| Terminals ▸ a device | The device's terminals (Watch by swipe, long press or VoiceOver action), Try Again, No Terminals | A device row in Terminals; **Show Terminals** on the device's page in Devices |
| Terminals nav bar | **+** (Add SSH Host…) on iPhone and in the iPad sidebar | — |
| **Devices** (tab 2) | **Add Device**; Unpaired note; **Paired Devices**, one section per relay server when there are several; **SSH Hosts** (every saved host with its ••• menu and swipes, Add SSH Host…, Import SSH Hosts…); Search Hosts | Tab bar |
| Devices ▸ a device | Show Terminals; Access, Relay Server, Device Code; Unpair… | A device row |
| **Settings** (tab 3) | **Appearance**: Text and Colors ▸, Bell and VoiceOver ▸. **Keyboard**: Keyboard Row ▸, Snippets ▸. **Connections**: Relay Servers ▸. **Help**: Welcome Tour | Tab bar |
| Settings ▸ Text and Colors | Font Size, preview, Color Scheme, scheme preview, Increase Terminal Contrast, Restore Display Defaults | Settings |
| Settings ▸ Bell and VoiceOver | Terminal Bell, Announce New Output | Settings |
| Settings ▸ Keyboard Row / Snippets | Key choice and order; snippet list and editor | Settings; the terminal's **Terminal Display** sheet |
| Settings ▸ Relay Servers ▸ a server | Address, status, Check Connection, Edit Address, Remove Relay Server… | Settings |
| Terminal (SSH or paired) | Nav bar: back, name and status, **keyboard button**, ••• (Smaller Text, Larger Text, Find, Terminal Display, SFTP Files, Port Forwarding or Stop/Start Typing, Leave or Disconnect); key row | A terminal row |
| Terminal Display sheet | Text and Colors, Keyboard Row, Snippets, Bell, VoiceOver | The terminal's ••• menu |
| Add Device sheet | Camera, Paste, Type Invitation… | Terminals first use; Devices |
| Add SSH Host… sheet | The host form | Terminals first use; Terminals **+**; Devices ▸ SSH Hosts; ⌘N; "Add as SSH Host…" in the relay server address sheet |
| Import SSH Hosts… sheet | Config file import | Terminals first use; Devices ▸ SSH Hosts |

## 2. Structure after Round 16

Three tabs, unchanged in name and order: **Terminals**, **Devices**, **Settings**. No new tab.

### Terminals: one list, three kinds of section

The owner delegated the section design to the lead; this is binding. Paired terminals are existing sessions you open; SSH hosts are saved destinations you connect to. Their actions differ (an SSH host has Favorite and Delete Host; a Mac's terminal has no delete, because ending it is the Mac's decision) and so does how you got access (pairing versus invitation). So they never share a section, and nothing needs a tap into a device to be seen.

1. **One section per paired device** (a Mac today), in the order devices were first listed, per relay server. The header is the device's name (plus the relay server when there are several) and its status: **Online**, **Offline**, **Checking…**, or a problem. Rows are that device's terminals: the name, and under it who else types there (Typing on *device*) or Can only watch. Tapping a row opens the terminal. An online device with no terminals says "On the other device, choose Open On ▸ *this device*."; an offline one says, in one line, "Offline. Its terminals appear here when it’s back online." instead of an empty list. Opening, a refused open (with Watch while someone else types) and Try Again appear inside that device's section, so the reason sits next to the terminal.
2. **Shared with You**, only when it has rows: terminals reached through a one-terminal invitation (no pairing). Each row says whose terminal it is and that access ends with the invitation (*device* · Until the invitation ends). The phone records which grants came from an invitation when it joins one (`SharedTerminals`, the grant ID and its end time, in this device's defaults; no secrets).
3. **SSH Hosts**: connected and just-disconnected hosts first as live cards (Connected, or Disconnected and tap to reconnect), then saved hosts, favorites first and then most recent, as before. **Add SSH Host…** and **Import SSH Hosts…** are the section's last rows, and their only place on iOS. With no hosts, the two rows carry what they need ("Needs an address and a login", "From an SSH config file"); with no paired devices either, the section footer points to Devices in words.

Empty sections are hidden, except SSH Hosts, which always holds its two actions. **Search Terminals** appears once the list has 8 or more terminals and hosts, and covers every section (terminal names, device names, host names and addresses). Favorites Only stays inside SSH Hosts. ⌘1–⌘9 and ⇧⌘] / ⇧⌘[ follow the list's order: paired sections, Shared with You, then connected SSH hosts. Pull to refresh checks the relay servers and lists every device's terminals again.

On iPhone the terminal replaces the list, and leaving returns to it (after the detach ACK; the terminal is still listed, because it keeps running). On a regular-width iPad the list stays beside the terminal. The old per-device terminal screen is gone: nothing routes to it.

### Devices: devices and their relay servers

1. **Add Device**, first.
2. **Paired Devices**: one row per device and relay server (widest access), the server named on the row when there are several. A row opens the device's page: Access, Relay Server, Device Code, **Unpair…**. Shared-with-you grants are not devices and aren't listed. Loading and a server's problem show inside this section.
3. **Relay Servers**: one row per server with its status; each opens its page (Address, status, Check Connection, Edit Address, Remove Relay Server…). **Add Relay Server** is the section's last row.

SSH hosts left Devices: they are destinations in Terminals, not devices you pair.

### Settings: frequent first, then Advanced

| Category | Rows | Why here |
|---|---|---|
| **Terminal** | **Text and Colors**, a collapsible group (collapsed it shows "14 pt · System"; expanded: Font Size with its preview, Color Scheme with its preview, Restore Display Defaults). **Snippets** ▸ | Text size and colors are the most changed preferences, and the owner asked for them together in one collapsible group. Snippets are edited as people's work changes. |
| **Help** | Welcome Tour | Reopening the tour is rare but must be easy to find; it's not a preference, so it isn't Advanced. |
| **Advanced** ▸ | **Display**: Increase Terminal Contrast. **Keyboard**: Keyboard Row ▸. **Bell**: Terminal Bell. **VoiceOver**: Announce New Output | Each is set once, if ever. Increase Terminal Contrast already turns on with the system's Increase Contrast; Announce New Output only matters while VoiceOver runs; the key row's defaults fit most people; the bell is a one-time choice. They keep their own headers so they stay findable, and none is hidden behind a gesture. |

Relay servers moved to Devices (they're what devices pair through). Settings has no Connections category any more.

### Swipe actions

Swipes mirror the row's menu, never add actions of their own, and are also in the row's context menu (long press) and VoiceOver's actions rotor (SwiftUI exposes list swipe actions as custom actions). A full swipe only performs an action that can be undone.

| List | Leading | Trailing | Full swipe | Confirmation / undo |
|---|---|---|---|---|
| Terminals ▸ SSH host | Favorite / Unfavorite | Delete Host (or Disconnect while connected) | Yes | Delete Host: Undo bar for 10 s, restores credentials, color, favorite, order. Disconnect: none needed (reconnect is a tap) |
| Terminals ▸ a device's terminal | — | Watch (only when you could type; Phase A only) | No | None: opens without typing |
| Terminals ▸ Shared with You | — | — | — | — |
| Devices ▸ paired device | — | **Unpair…** | **No** | Always the confirmation ("Unpair from “*device*”?"), never one swipe; absent while offline (the context menu shows it dimmed) |
| Devices ▸ relay server | — | **Remove…** | No | Confirmation ("Remove Relay Server?"); its devices stay paired |
| Settings ▸ Snippets | — | Delete (system) | Yes (system list editing) | As before |

### Duplicates removed

| Function | Before | After (its one place) |
|---|---|---|
| Add SSH Host… | Terminals first-use row, Terminals **+** (iPhone bar and iPad sidebar), Devices ▸ SSH Hosts | Terminals ▸ SSH Hosts, last rows. ⌘N stays as its shortcut; "Add as SSH Host…" stays as a recovery inside the relay server address sheet, where an SSH login was typed by mistake. The iPhone bar's **+** sits in the terminal screen's toolbar code, which another crew owned in Phase A, so it goes in Phase B. |
| Import SSH Hosts… | Terminals first-use row, Devices ▸ SSH Hosts | Terminals ▸ SSH Hosts |
| Favorite, Edit Host, Host Keys, Delete Host, Disconnect | Host rows in Terminals and in Devices | Host rows in Terminals (••• menu, swipes, long press) |
| Add Device | Terminals first-use row, Devices | Devices. Terminals says in words where it is when no device is paired. |
| A device's terminals | Terminals ▸ device row ▸ terminal list; Devices ▸ device ▸ Show Terminals | The device's section in Terminals. Show Terminals is gone. |
| Relay servers | Settings ▸ Connections ▸ Relay Servers | Devices ▸ Relay Servers |
| Keyboard Row, Snippets | Settings, and the terminal's Terminal Display sheet | Settings (Snippets in Terminal, Keyboard Row in Advanced) |
| Bell, Announce New Output | Settings ▸ Bell and VoiceOver, and the Terminal Display sheet | Settings ▸ Advanced |
| Text size and colors | Settings ▸ Text and Colors; the Terminal Display sheet; Smaller Text and Larger Text in the terminal menu | Settings ▸ Terminal ▸ Text and Colors for the preference. In a terminal, one collapsible **Text and Colors** submenu (Smaller Text, Larger Text, Color Scheme) replaces both the two loose items and the sheet (Phase B). This is the one deliberate exception: an in-context adjuster of the same stored preference, like pinch, as Safari's page menu does. |
| Watch (open without typing) | Swipe, long press and VoiceOver action on a device's terminal; Watch in the reconnect card | Phase B: gone. A terminal is watched whenever the keyboard is hidden. |

## 3. The terminal screen (Phase B)

### Keyboard button (request 6)

- One button at the bottom right, for SSH and paired terminals alike: 44 × 44 pt, glass (gray with Reduce Transparency), 16 pt from the trailing edge (or the safe area, if larger), inside the bottom safe area so it clears the home indicator and stays under the thumb in both orientations.
- It shows only while the keyboard is hidden, in a strip of its own (8 + 44 + 8 pt) under the terminal text, so it never covers the cursor line; **Jump to Latest** stays at the text area's bottom right, above the strip.
- While the keyboard is up, the key row's last key is **Hide Keyboard** (as in Round 13), which is where the same thumb already is.
- It leaves the navigation bar, which keeps only the title, the switcher chevron and the ••• menu.
- VoiceOver: "Show Keyboard", with the hint "Starts typing in this terminal." for a paired terminal. It comes after the terminal in reading order.

### Typing without modes (request 7)

There is no Typing or Watching mode to switch. The keyboard is the state:

| You do | SSH terminal | Paired terminal you may type in | Paired terminal that can only watch |
|---|---|---|---|
| Open it | Keyboard up, typing | Keyboard up, typing (an explicit tap on the terminal), unless someone else is typing: then it opens with the keyboard down and the status says Typing on *device* | Keyboard down; no keyboard button; the status says Can only watch |
| Tap the keyboard button | Keyboard up | Asks the Mac for typing, after the detach ACK of the watching connection; the keyboard rises once the Mac accepts. Refused: the keyboard stays down and the status says Typing on *device*. Never takes typing from anyone silently, never resends input | — |
| Hide the keyboard (Hide Keyboard key, swipe down on the keyboard, or leaving) | Keyboard down; the shell is unchanged | Stops typing: the Mac's grid becomes authoritative again and this device no longer resizes it (detach ACK, then attach to watch) | — |
| Tap the terminal | Keyboard up, as before (an SSH terminal takes typing from no one) | While watching: selection and scrolling only | Selection and scrolling only |

On a paired terminal a tap never starts typing: taps select, scroll and read with VoiceOver, and an accidental tap must not take a terminal from someone else, so the keyboard button is the one way in. An SSH terminal keeps tap-to-type (Round 15's touch model is unchanged).

The status line under the name says only plain facts: the device (paired) or `user@host:port` (SSH); Typing on *device* when someone else types; Can only watch; Disconnected; Terminal Ended. The Start Typing and Stop Typing menu items, the Typing and Watching labels, and the "Switching to Typing…" and "Switching to Watching…" progress words go from the iPhone and iPad UI. While the keyboard is asked for, the button shows progress. ⇧⌘T (Start or Stop Typing) leaves the iPhone and iPad command list; with a hardware keyboard the keyboard button does the same.

The grant **Can only watch** stays: it's a permission, not a mode.

### The Mac app

Unchanged. A Mac window has no software keyboard, so "keyboard hidden" has no Mac meaning, and its Typing and Watching states (Stop Typing, ⇧⌘T, Watch) remain how a window lets go of a terminal. The words a Mac shows about a phone (Typing on *device*, Watching on *device*) still describe the phone correctly: a phone with its keyboard down is watching.

## 4. Open questions for the owner

1. **Ending an invitation early from the phone.** Shared with You has no Remove action; access ends when the invitation does or when the Mac ends it. Should the phone be able to leave an invitation early (it would be irreversible, with a confirmation)?
2. **Announce New Output while VoiceOver runs.** It's in Advanced. Should it show in the main list automatically while VoiceOver is on?
3. **Tap to type on a paired terminal.** The lead kept tapping a paired terminal from starting to type, so an accidental tap never takes it from someone. Should a tap start typing when nobody else is typing there?
