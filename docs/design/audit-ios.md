# iOS UI/UX Audit (Phase 1)

A production-grade review of the iPhone app (and the iPad layout, from code) on 2026-11-03, against the [Design Guidelines](README.md), the [HCI log](hci-improvements.md) through Round 9, Apple's Human Interface Guidelines, and WCAG 2.2 AA. This phase changes no app code. It records what to fix, the visual system as it is actually used, proposed tokens, and measured task walkthroughs.

**Build and device.** `main` at 1291bce, Debug, iPhone 18 Pro simulator (iOS 27.2, <simulator>), English and Simplified Chinese, light and dark, default text size and AX5 (`UICTContentSizeCategoryAccessibilityXXXL`). No iPad simulator exists on this Mac and none was created; iPad findings come from code and are marked *(code)*. Paired-terminal screens come from code and the Round 10 joint-run screenshots, because the simulator is not paired with a Mac in this phase.

**Evidence.** Screenshots are under `.build/screenshots/` (not committed). Paths in the tables are relative to that folder:

- `audit-ios/<variant>/NN-screen.png`: from the opt-in [`AuditScreenshotTests`](../../apps/apple/UITests/AuditScreenshotTests.swift), variants `en-light`, `en-dark`, `en-ax5`, `zh-light`, `zh-ax5-dark`, plus `ssh-live` against the disposable OpenSSH fixture.
- `round10-joint/phone-*.png`: the paired-terminal joint run.

How to reproduce is in [QA notes](#qa-notes).

**Roles.** Each finding names the role that found it: **VD** visual and layout designer, **PS** iOS platform specialist (HIG), **AX** accessibility specialist, **IX** interaction designer, **UW** UX writer, **UR** UX researcher, **QA**.

**Priorities.** **P0** broken, misleading, or inaccessible. **P1** clearly below production quality. **P2** inconsistency or polish. **P3** nice to have. Effort: **S** under half a day, **M** one to two days, **L** more.

**Summary.** 52 findings: 4 P0, 15 P1, 22 P2, 11 P3. The post-connect experience is close to its minimum tap counts; what keeps the app below production quality is consistency (two background colors, cards vs lists, four dismiss words, buttons that look like labels), accessibility at the edges (three contrast/Voice Control failures, AX5 breakage in five screens, a terminal that scales to 16 columns), Chinese state words that read as permissions, and an iPad layout that is structurally wrong in code. The ten to do first: F-01, F-02, F-03, F-04, F-05, F-07, F-49, F-52, F-47, F-06.

## 1. Findings

Ordered by priority, then by harm. *(code)* means read from code, not seen on a device.

| ID | Role | Surface | Issue | HIG / heuristic | Evidence | Proposed fix | Effort |
|---|---|---|---|---|---|---|---|
| **F-01** | UR, IX | Devices → Paired Devices; Terminals → Devices | **P0.** One row per *grant*, not per device. A device paired twice through the same relay server (re-pairing) appears twice with the same name and hue, and unpairing either row ends both (`RemoteTerminalModel.pairings(endedBy:)` ends every grant on that server with the same `host.id`), so the "other" row vanishes too: the person can't predict what Unpair removes. Paired through two relay servers, it appears once per server in Devices and twice in Terminals, and Unpair on one leaves the other. | Match between system and the real world; consistency (one object, one row) | *(code)* `DevicesView.swift:152`, `TerminalsHome.swift:36`, `RemoteTerminalModel.swift:562`; joint run had one pairing (`round10-joint/phone-01-devices.png`) | Merge grants by `(server, host.id)` into one row. Show the widest access (control beats view) and the newest grant's code; Device Details lists the relay server(s). Unpair already ends all of them; its confirmation should say so when there are several ("…on 2 relay servers"). Within one server, keep the newest grant and treat older ones as superseded. | M |
| **F-02** | AX | Paste button, Add Device (dark) | **P0.** In dark mode the system `PasteButton` takes the app tint (#ECEEF2) but keeps its white label: the measured fill is #A3A5A7 under white text, about **2.5:1** (captured with an empty pasteboard, the state on first open; the enabled state needs the same check). The main way in on a device without a camera is barely legible. | WCAG 1.4.3 (4.5:1); HIG Color | `audit-ios/en-dark/14-add-device.png` (light is fine: `en-light/14-add-device.png`) | Give the `PasteButton` an explicit tint that keeps 4.5:1 under white in both appearances (e.g. graphite #2C2F35 in dark, Ink in light), or leave it the system default. Add a snapshot contrast check like `scripts/check-terminal-contrast.py` for buttons. | S |
| **F-03** | AX | `StatusBadge`, positive tone (light) | **P0.** Positive #1A7F4B on its own 12% tint over Surface is **4.28:1** for 12 pt caption text. Used by "Connected" / "Connected · *program*" on every open terminal card. README claims every pairing reaches 4.5:1. | WCAG 1.4.3 | computed from `Assets.xcassets` (see [Color](#color)); `ssh-live/11-terminals-open-card.png` | Darken light Positive to about #157043, or draw positive badges on a neutral `statusFill`. Add the badge-on-tint pairs to the contrast table in README. | S |
| **F-04** | AX | Key row above the keyboard | **P0 (Voice Control).** Visible faces differ from spoken names: "Ctrl" is *Control for Next Key*, "Ctrl+C" is *Interrupt (Control-C)*, "PgUp"/"PgDn" are *Page Up/Down*. A Voice Control user who says "Tap Ctrl" gets nothing. | WCAG 2.5.3 Label in Name (A); HIG Voice Control | `audit-ios/en-light/09-settings-keyboard-row.png` (faces beside names); `MobileTerminalAccessory.swift:64` | Set `accessibilityUserInputLabels = [face, label, short name]` on each key (`["Ctrl", "Control"]`, `["Ctrl C", "Interrupt"]`). Keep the descriptive label for VoiceOver. | S |
| **F-05** | VD, PS | Every list, form, and sheet | **P1.** The app tint is AccentColor (#17181C / #ECEEF2), the same as Ink, so text buttons in rows (Edit Address, Check Connection, Check Again, Add Host, Add Server, Type Invitation…, Use Another Invitation, Save for Later, Paste a Key Instead) look exactly like static labels. Only position tells them apart. | HIG Buttons ("make buttons look tappable"); Nielsen #6 recognition | `en-light/12-relay-server-page.png`, `24-devices-one-host.png`, `14-add-device.png`, `17-add-device-check.png`, `18-ssh-form-empty.png` | Keep the neutral tint (brand rule) but give in-content actions a consistent cue: a leading SF Symbol on every row action (as Add Host already has), `.fontWeight(.semibold)`, or `.bordered` for free-standing secondary buttons. Decide once, apply through a `SecondaryAction` component. | M |
| **F-06** | VD | Terminal (SSH and paired), iPhone | **P1.** Terminal text starts at x = 0: the first column touches the screen edge and the rounded display corner, and selection handles at column 0 are half off-screen. | HIG Layout (margins, safe areas) | `round10-joint/phone-07-terminal.png`, `phone-10-selection.png`; `ssh-live/03-terminal-connected-tip.png`, `ssh-live/07-terminal-selection.png` (the start handle at column 0 is off-screen) | Inset the terminal grid by 6 pt horizontally (and by the horizontal safe area in landscape), compute columns from the inset width, and paint the inset in the terminal background so the edge still reads as the terminal. | M |
| **F-07** | IX, PS | Devices tab → device row | **P1.** Tapping a paired device in **Devices** switches to the **Terminals** tab. Its details and Unpair hide behind a small ⓘ. A tab should not navigate another tab, and the row's main tap should open the thing it names. | HIG Tab bars ("don't use a tab to navigate elsewhere"); consistency | `DevicesView.swift:154`; `round10-joint/phone-01-devices.png`, `phone-12-details.png` | In Devices, the row pushes a **device page**: Access, relay server, code, its terminals (each opens in Terminals), and Unpair… last. Drop the ⓘ. Terminals keeps the one-tap open. | M |
| **F-08** | PS | iPad, Terminals tab *(code)* | **P1.** On regular width, `SSHWorkspaceView` puts a `NavigationSplitView` *inside* the tab's `NavigationStack` (`MobileWorkspaceView.swift:69`, `SSHWorkspaceView.swift:419`). Apple requires the split view to be the root of its column hierarchy; nesting gives two navigation bars and an undefined back stack. When a paired device is opened, `RemoteTerminalWorkspace` replaces the whole split view, so the list disappears, contrary to README ("the list stays beside the terminal"). | HIG Split views; SwiftUI `NavigationSplitView` docs | *(code)* | Make the split view the tab's root on regular width (`NavigationStack` only on compact), with paired devices and SSH hosts in the same sidebar and the terminal (SSH or paired) in the detail column. Consider `TabView` with `.tabViewStyle(.sidebarAdaptable)` (iPadOS 18+). Needs an iPad simulator to verify. | L |
| **F-09** | PS | Hardware keyboard (iPad, iPhone with keyboard) | **P1.** iOS registers only Add SSH Host (⇧⌘N), Refresh (⌘R), text size (⌘+/⌘−/⌘0), and next/previous/⌘1–9 for **SSH** terminals. Missing: Stop/Start Typing (⇧⌘T on the Mac), Leave, Disconnect, Find Next/Previous (⌘G/⇧⌘G), Insert Snippet; paired terminals aren't in ⌘1–9. ⌘F exists only on a button inside a toolbar `Menu`, so it isn't in the ⌘-hold overlay and may not fire until the menu has been built. | HIG Keyboards ("support standard shortcuts"; discoverability) | `WitermApp.swift:212–330` (`#if os(macOS)` blocks); `RemoteTerminalWorkspace.swift:393` | Move the terminal commands into `WitermCommands` for iOS too, fed by `focusedSceneValue`; include paired terminals in the list. | M |
| **F-10** | VD, UW | Add / Edit Relay Server sheet | **P1.** The title truncates to "Add Relay…" at the **default** text size in English, because the confirm button says "Add and Check"; at AX5 the title disappears and the medium detent leaves room for one line of the explanation. | HIG Sheets; Nielsen #1 | `en-light/13-add-relay-server.png`, `en-ax5/13-add-relay-server.png` | Confirm button **Add** (the check always follows); title **Add Relay Server**; drop the footer or shorten it to one line; start at `.large` when `dynamicTypeSize.isAccessibilitySize`. | S |
| **F-11** | AX | Relay Servers list (AX5) | **P1.** At AX5 the server's name truncates in the middle ("local…7429") while its status badge wraps and hyphenates ("Connec-tion Failed"): the identifying text loses to the status. | HIG Typography (Dynamic Type: wrap, don't truncate) | `en-ax5/13-add-relay-server.png` (background) | At accessibility sizes stack the badge under the name and allow the name to wrap (`lineLimit(nil)`), as `TerminalActivityCard` already does. | S |
| **F-12** | IX | Terminal scrollback | **P1.** Scrolled back, nothing says new output arrived and there's no one-tap way back to the prompt; the only way is a long fling. | HIG Scroll views; Nielsen #1 | *(code)* no such control in `RemoteNativeTerminalView` or `SSHNativeTerminalView`; `ssh-live/06-terminal-scrolled-back.png` (the fixture's short output) | A floating "Jump to Latest" button (`arrow.down.to.line`, 44 pt, VoiceOver action too) while not following; a dot on it when output arrived. | M |
| **F-13** | PS | Paste (key row, edit menu) | **P1, verify on device.** Both paste paths read `UIPasteboard.general.string` from custom actions, which iOS treats as programmatic access: content from another app triggers the "Allow Paste?" prompt each time unless the person changes the setting. | HIG Pasteboard / privacy | `MobileTerminalAccessory.swift:224`, `RemoteNativeTerminalView.swift:497, 574` | Key row: `UIPasteControl`. Edit menu: route through the standard `paste(_:)` responder action (system Paste item), which counts as user intent. | M |
| **F-14** | UW | Terminals → section "Devices" | **P1.** The Terminals tab has a section named **Devices** that lists SSH hosts and paired devices; the next tab is also **Devices** and there separates "Paired Devices" from "SSH Hosts". The same word means two different sets. | Consistency and standards; README Wording ("one word per idea") | `en-light/22-terminals-one-host.png`, `24-devices-one-host.png` | Drop the header (the section follows "Open"), or name it **Saved** (已保存). Keep "Devices" for the tab only. | S |
| **F-15** | VD, IX | Backgrounds across tabs and sheets | **P1.** Lists and custom screens paint `Canvas` (#F4F5F7 / #0F1013); `Form` pages and all sheets keep the system grouped background (#F2F2F7 / black). In dark mode switching from Terminals to Settings jumps from graphite to black. | Consistency; HIG Dark Mode | `en-dark/04-terminals-empty.png` vs `en-dark/06-settings.png`; light: `en-light/04` vs `06` | One background policy for iOS (see [Color and opacity](#color-and-opacity-shared)). | S |
| **F-46** | AX | Add SSH Host form (AX5) | **P1.** The pinned bottom bar (Connect, Save for Later) takes a quarter of the screen at AX5 and stays while the keyboard is up, leaving room for about one field; the Host chip, the one thing to check, truncates to "b…e.invalid". README: "At accessibility text sizes … primary actions move into the content." | HIG Dynamic Type; README Accessibility | `en-ax5/19-ssh-form-address.png`, `en-ax5/18-ssh-form-empty.png` | At accessibility sizes put the actions at the end of the form instead of `safeAreaInset`; let chips wrap (`lineLimit(nil)`). | S |
| **F-47** | AX, UW | Addresses at large text sizes | **P1.** When an address wraps, the system hyphenates it: `audit@example.invalid:22` shows as "audit@ex- / ample.in- / valid:22", and a host name as "deploy@buil / d.exam- / ple.invalid". A hyphen is a legal host-name character, so the screen shows an address that doesn't exist. In Chinese the same text breaks mid-word and mid-port without hyphens ("buil / d.example", ":2 / 222"). | HIG Typography; error prevention | `en-ax5/22-terminals-one-host.png`, `en-ax5/05-devices-empty.png`, `zh-ax5-dark/04-terminals-empty.png` | For addresses, fingerprints, codes, and paths: no hyphenation (UIKit-backed text with `hyphenationFactor = 0`, or zero-width break opportunities after `@ . : /`) and break only at those characters. | S |
| **F-49** | UW | Chinese: your state vs the device's permission | **P1.** The two *states* are 可输入 (Typing) and 仅观看 (Watching); the two *permissions* are 可观看和输入 (Can watch and type) and 仅可观看 (Can only watch). 仅观看 and 仅可观看 differ by one character, and 可输入 ("can type") reads as a permission, not as what is happening now. In a title line like "仅观看 · *device*" next to a device row saying "仅可观看", a Chinese reader can't tell "you are watching" from "you may only watch". | README Wording ("terms users can't misread"); Nielsen #2 | `Localizable.xcstrings` (Typing, Watching, Can only watch); `round10-joint/phone-09b-watching.png` (English run) | States as ongoing actions: **输入中** (Typing) and **观看中** (Watching); keep 可观看和输入 / 仅可观看 for permissions. Update README's Wording table and the Mac strings together (shared catalog). | S |
| **F-52** | AX, IX | Terminal at accessibility text sizes | **P1.** Terminal text multiplies the chosen size by the Dynamic Type factor without a cap (`@ScaledMetric(relativeTo: .body)`), so at AX5 a 14 pt setting renders at roughly 40 pt: about 16 columns fit, lines wrap mid-word ("ad / ministrating"), full-screen programs that need 80 columns are unusable, and the key row shows four keys. Someone who needs large UI text doesn't necessarily want a 16-column terminal, and can't opt out. | HIG Dynamic Type ("not every element must scale linearly"); WCAG 1.4.10 Reflow | `ssh-live/16-ax5-terminal.png` vs `ssh-live/03-terminal-connected-tip.png` | Cap the automatic factor (e.g. at the `xxxLarge` ratio, ~1.4×), make the explicit size the way past it (pinch, ⌘+, Text and Colors), and show the effective size (F-16). Keep the key row's keys at a capped height with Large Content Viewer on long press. | S |
| **F-16** | AX, IX | Text and Colors (AX sizes) | **P2.** The preview "Aa 0123456789" draws at the stored size (14 pt) although the footer says terminal text follows the system text size; at AX5 the real terminal is much larger than the preview. The Stepper's label splits into two narrow columns ("Font / size", "14 / pt"). | Nielsen #1 (system status) | `en-ax5/07-settings-text-colors.png` | Preview at the effective size (stored × the `@ScaledMetric` factor), and show "14 pt (20 pt with your text size)" only when they differ. At AX sizes, put the value under the label. | S |
| **F-17** | PS | Sheets | **P2.** Large titles inside five sheets (Device Details, Add SSH Host, Host Keys, Port Forwarding, SFTP Files) and inline in the rest; pushed pages also mix (large: Text and Colors, Bell and VoiceOver, Snippets; inline: Keyboard Row, Relay Servers, a server). Only one sheet sets detents; Device Details (four rows) and Terminal Display open full height. | HIG Sheets (detents), Navigation bars | `round10-joint/phone-12-details.png`, `en-light/18-ssh-form-empty.png` vs `14-add-device.png` | Apply the [sheet table](#sheets-and-detents-ios): inline titles in all sheets, large only on tab roots; detents per sheet. | S |
| **F-18** | VD | Cards vs list sections | **P2.** `witermCard` (20 pt radius, 1 pt stroke) sits next to system list sections (larger concentric radius, no stroke): the first-use card, a device's terminal list, the code tile. A device's terminal list is a `ScrollView` of cards, unlike every other list, so it has no row highlight or swipe. | Consistency | `en-light/04-terminals-empty.png` vs `05-devices-empty.png`; `round10-joint/phone-11-back.png` | First use and a device's terminals become inset-grouped `List` sections; cards only for live objects; stroke only with Increase Contrast. | M |
| **F-19** | VD, UW | First use, Add Device | **P2.** Identity hues (rose, sky, violet) color actions that aren't machines: the three first-use rows, the Add Device tile in Devices, the wait step's tile. README: "color belongs to machines". | Brand rule; consistency | `en-light/04-terminals-empty.png`, `05-devices-empty.png` | Neutral `IconTile` (accent) for actions; hues only for hosts and devices. | S |
| **F-20** | IX | Add SSH Host, Add Relay Server | **P2.** The first field isn't focused when the sheet opens, so every add starts with a tap on the field (Add Device's Type Invitation… does focus). | Efficiency (Nielsen #7) | `en-light/18-ssh-form-empty.png`, `13-add-relay-server.png` (no keyboard) | Focus the address field on appear for new items (not for Edit). | S |
| **F-21** | UW | Relay server pages | **P2.** "Server" alone, where the vocabulary says *relay server*: Add Server, Remove Server, Remove Server?, "The server is reachable", "Check the server connection when you are ready", "This server doesn't offer remote terminals", "Continuing adds this server". The New Key card says "Copy the public key to the server" (将公钥复制到服务器) where it means the SSH host. | README Wording ("relay server … not server alone"; SSH host, not server) | `en-light/11-relay-servers.png`, `12-relay-server-page.png`, `17-add-device-check.png` | Add Relay Server, Remove Relay Server…, "Reachable", "This relay server can't open terminals"; "Add the public key to the SSH host". | S |
| **F-22** | UW | Check the Other Device | **P2.** The footer says "Continuing adds this server" under a button that says **Request Access** (or **Watch**). | Consistency | `en-light/17-add-device-check.png` | "Requesting access adds this relay server. Only continue if you trust the device showing the code." / "Watching adds…". | S |
| **F-23** | IX | Add Device, no camera | **P2.** The note says "paste it below" before the instruction that says where to get it; Paste is a small centered capsule while every other primary action is full width; "Type Invitation…" looks like a label (F-05); the sheet is two-thirds empty. | Nielsen #4, #8 | `en-light/14-add-device.png` | Instruction first, then a full-width Paste (`PrimaryButton` styling), Type Invitation… as a bordered button; `.medium` detent when there's no camera. | S |
| **F-24** | UW | Ways to add an SSH host | **P2.** Three labels for one form: "Connect to an SSH Host" (first use), "Add SSH Host…" (+ button, form title), "Add Host" (Devices). | Consistency | `en-light/04-terminals-empty.png`, `24-devices-one-host.png`, `18-ssh-form-empty.png` | **Add SSH Host…** everywhere a form opens; first use may keep its descriptive detail line. | S |
| **F-25** | UW, VD | Settings labels | **P2.** Sentence case in the terminal settings ("Font size", "Color scheme", "Increase terminal contrast", "Ring the terminal bell", "Announce output updates") and title case everywhere else ("Save Credentials on This Device", "Favorites Only", "Press Return After Inserting"). | HIG Writing (capitalization) | `en-light/07-settings-text-colors.png`, `08-settings-bell.png` | Title case, matching iOS Settings: Font Size, Color Scheme, Increase Contrast, Terminal Bell, Announce New Output. | S |
| **F-26** | PS | Host rows, device rows | **P2.** No swipe actions anywhere a list row has a menu: SSH hosts (Delete Host, Favorite) only through the ellipsis; paired devices have no row actions at all. | HIG Lists ("swipe to delete"; actions where people expect them) | `en-light/22-terminals-one-host.png`, `23-host-actions.png` | Trailing swipe: Delete Host (undoable) / Disconnect; leading: Favorite. Same items as the menu. | S |
| **F-27** | UW | Dismiss buttons | **P2.** Four ways to say "close this message": **OK** (tmux tip, No Longer Paired), **Dismiss Message** (SSH issue), **Dismiss** ✕ (watching notice, undo bar), auto-dismiss after 4 s (Unpaired note). | Consistency | `SSHWorkspaceView.swift:227, 490`; `TerminalsHome.swift:54`; `RemoteTerminalWorkspace.swift:288` | ✕ "Dismiss" for transient notices; **OK** only for one-time tips. | S |
| **F-28** | VD | Keyboard Row settings | **P2.** Permanent edit mode: eighteen red minus buttons on arrival, and "More Keys" is empty by default because the default row is *all* keys. Reads as a destructive screen. | HIG Lists (edit mode is entered, not permanent) | `en-light/09-settings-keyboard-row.png`, `en-ax5/09-settings-keyboard-row.png` | A checkmark per key (shown/hidden) plus reorder handles, with an Edit button for reordering; default row = the seven keys that fit plus Ctrl+C, Paste, Snippets. | M |
| **F-29** | UW | Disconnected states | **P2.** "SSH Disconnected" (terminal screen), "Disconnected" (card), "Terminal Disconnected" (paired overlay). | Consistency | `SSHWorkspaceView.swift:505`, `TerminalsHome.swift:111`, `RemoteTerminalWorkspace.swift:466` | **Disconnected** everywhere, with the address or device underneath. | S |
| **F-30** | UW | Visible explanations | **P2.** The minimal-text rule is broken by always-visible hints: "Add :port after the host if it isn't 22.", "RSA keys aren't supported because they would be signed with SHA-1.", the jump-host footnote, two Text and Colors footers, the snippets footer, the relay server sheet footer, the offline banner's second sentence. | README Wording; Nielsen #8 | `en-light/18-ssh-form-empty.png`, `20-ssh-form-private-key.png`, `07-settings-text-colors.png` | Show the RSA line only when an RSA key is chosen (the error exists); make `user@host:port` the placeholder; move the rest to VoiceOver hints or drop them. | S |
| **F-31** | VD | Key choice cards | **P2.** New Key and Existing Key cards have different heights side by side. | Alignment | `en-light/20-ssh-form-private-key.png` | Equal heights (`frame(maxHeight: .infinity)` inside a `fixedSize(vertical:)` row). | S |
| **F-32** | IX | Pinch to resize terminal text | **P2.** The size changes only when the fingers lift; no live preview and no readout of the new size. | Direct manipulation; Nielsen #1 | `RemoteNativeTerminalView.swift:125` | Scale the view live during the pinch, then reflow at the end; show a brief "16 pt" HUD and a haptic at the range ends. | M |
| **F-33** | IX | Reconnecting a saved host | **P2.** Save Credentials is off by default and there's no Face ID–protected option, so every reconnect asks for the password again. | Efficiency | walkthrough 2b; `ssh-live/15-ax5-connect-form.png` | Offer "Save in Keychain, unlock with Face ID" (Keychain access control `.biometryCurrentSet`) as the default choice when saving; still explicit, never silent. Policy question for the lead. | M |
| **F-34** | PS | Snippets page | **P2.** "Snippets" twice (page title and section header); Edit appears with no snippets to edit; the empty state is a sentence in a list row. | HIG Lists | `en-ax5/10-settings-snippets.png` | Drop the section header on the standalone page; hide Edit while empty; `ContentUnavailableView` with Add Snippet. | S |
| **F-35** | VD | Find bar, iPhone | **P2.** Field, count, ↑, ↓, and Done share one row; at accessibility sizes the field shrinks to a few characters *(code)*; at the default size it fits (`ssh-live/09-terminal-find.png`). | HIG Search fields | `TerminalFindBar.swift:96`, `ssh-live/09-terminal-find.png` | Put the count inside the field's trailing edge; at AX sizes move ↑/↓ to a second row or the keyboard's toolbar. | S |
| **F-36** | VD | Welcome Tour | **P2.** The current page dot is white on a light-grey capsule (light mode), barely different from the others; page 2's symbol renders filled grey while pages 1 and 3 are outline. At AX5 the dots sit on top of the content (the key miniature on page 3). | HIG Page controls | `en-light/01-tour-1.png`, `en-ax5/02-tour-2.png`, `zh-ax5-dark/03-tour-3.png` | `UIPageControl.appearance().currentPageIndicatorTintColor = Ink`; `.symbolRenderingMode(.monochrome)`; put dots below the scroll content. | S |
| **F-51** | PS, VD | Terminal toolbar order | **P2.** An SSH terminal shows [⋯] [keyboard]; a paired terminal shows [keyboard] [⋯]. The same two controls swap places depending on how the terminal is reached, so muscle memory taps the wrong one. | Consistency (Nielsen #4) | `ssh-live/03-terminal-connected-tip.png` vs `round10-joint/phone-07-terminal.png` | One order everywhere: keyboard first, actions menu last (as HIG puts "more" at the trailing edge). One shared toolbar view for both terminal kinds. | S |
| **F-37** | UW | Welcome Tour copy | **P3.** "long-press to copy" (a long press selects; Copy is a second tap); "Tap +" while the screen behind shows a larger "Connect to an SSH Host" row. | Match with the real world | `en-light/03-tour-3.png`, `01-tour-1.png` | "Touch and hold to select, pinch to zoom." (Apple's term is *touch and hold*.) | S |
| **F-38** | IX | Haptics | **P3.** Success/error haptics exist for SSH connect, pairing, and an unpair failure; none for Stop/Start Typing completing, Unpair success, Ctrl latching, or key-row presses (no input clicks). | HIG Playing haptics | `RemoteTerminalWorkspace.swift`, `MobileTerminalAccessory.swift` | `.sensoryFeedback(.selection)` on the typing switch; `.success` on unpair; adopt `UIInputViewAudioFeedback` for key clicks. | S |
| **F-39** | AX | Fixed-size decoration | **P3.** `IconTile` (32 pt, 15 pt symbol), row minimum heights, the hue edge, and the first-use brand emblem don't scale; at AX sizes tiles are hidden but the 56 pt emblem stays and pushes the first action down a screen. | HIG Dynamic Type | `en-ax5/04-terminals-empty.png` | `@ScaledMetric` for tiles and row heights; hide the emblem at AX sizes (or drop it, F-40). | S |
| **F-40** | VD | First-use screen | **P3.** The brand emblem above the three ways in carries no information and no action; with "keep UI elements to an absolute minimum" it's the first thing to go. | Minimalism (Nielsen #8) | `en-light/04-terminals-empty.png` | Remove, or move into the tour. | S |
| **F-41** | IX, VD | Terminals after deleting the last host | **P3.** The large "Terminals" title disappears when the first-use overlay returns after a delete, until the tab is revisited. | Consistency | `en-light/25-host-deleted-undo.png` vs `04-terminals-empty.png` | Put first use in the list (F-18) instead of an overlay over an empty list. | S |
| **F-42** | VD | Selection | **P3.** Selected terminal text is teal while the handles are system blue. | Consistency | `round10-joint/phone-10-selection.png` | Use the system selection tint (or the host hue) for both. | S |
| **F-43** | UW | Device Details | **P3.** Relay Server shows the full URL (`https://…:37429`) while every other screen shows the display name. | Consistency | `round10-joint/phone-12-details.png` | `server.displayName`, full address on long press / copy. | S |
| **F-44** | AX | Timed confirmation | **P3.** "Unpaired from *device*" disappears after 4 s (it's also announced). | WCAG 2.2.1 Timing | `DevicesView.swift:68` | Keep it until the next interaction or the next visit to the tab. | S |
| **F-48** | VD, UW | Host rows with an automatic name | **P3.** A host saved without a name is named `user@host`, so its row reads the address twice ("deploy@build.example.invalid" over "deploy@build.ex…ple.invalid:2222"), and the second copy truncates. | Minimalism | `zh-light/04-terminals-empty.png`, `zh-light/05-devices-empty.png` | When the name is automatic, show only `:port` (or nothing for 22) on the second line, or the folder/activity once known. | S |
| **F-50** | UW | Chinese: "code", "New" | **P3.** The "New" badge beside an unsaved relay server is 新建, a verb ("create"); it should read 新 or 未保存 (`zh-light/17-add-device-check.png`). 验证码 is the vocabulary's word for a device code compared by eye, but "Scan a Code Instead" is 改为扫描验证码, where the thing scanned is a QR code (二维码, as the tour says). | README Wording (one word per idea) | `Localizable.xcstrings` | 改为扫描二维码; the badge 新. | S |
| **F-45** | VD | Text and Colors, dark | **P3.** With the System scheme the preview's background equals the row's, so the preview has no visible edge. | Visibility | `en-dark/07-settings-text-colors.png` | Stroke the preview with `divider`, or inset it on the terminal background. | S |

## 2. The visual system as used in code

Measured with a script over every Swift file compiled for iOS under `apps/apple/Sources` (`#if os(macOS)` branches removed, the accessibility test harness excluded): 15 iOS-only files and 30 shared ones. Counts are occurrences; "one-off" means a value used once. The script is reproduced in [QA notes](#qa-notes).

### Type

| Style | Uses | Where | Note |
|---|---|---|---|
| `subheadline` | 25 | banners, explanations, ActivityRow, notices | the de facto "secondary text" style |
| `caption` | 20 | row details, badges, form hints | |
| `headline` | 16 | row and card titles, tour key-row miniature, title bars | |
| `footnote` | 8 | chevrons, form footnotes, camera note | chevrons use `footnote.weight(.semibold)` (4) |
| `caption.monospaced()` | 6 | addresses, last line | plus `.system(.caption, design: .monospaced)` (4): two spellings of one style |
| `body` | 5 | icons in banners, preview | most row text inherits `body` implicitly |
| `subheadline.weight(.semibold)` | 5 | IssueBanner title, undo, KeyChoiceCard | |
| `.system(.body, design: .monospaced)` | 5 | fingerprints, host keys, paste preview, snippet editor | `body.monospaced()` once more in Device Details (a third spelling) |
| `subheadline.weight(.medium)` | 3 | ConnectionFeedback only | **one-off weight** |
| `caption.weight(.medium)` | 2 | StatusBadge, "Connected" | |
| `.system(.callout, design: .monospaced)` / `callout.monospaced()` | 2 + 2 | fingerprint in trust sheet and host keys; key faces in Keyboard Row | |
| `.system(.subheadline, design: .monospaced)` | 2 | invitation field, server address | |
| `.system(.title3, design: .monospaced)` | 2 | both pairing codes | the Device Details code uses `body.monospaced()` (one code, two sizes) |
| `title2.weight(.semibold)` | 1 | `PageHeader` (defined, not used by any screen) | |
| `title2.weight(.bold)` | 1 | tour page titles | **one-off** |
| `callout` | 1 + 2 UIKit | tour key miniature; the real key row | |
| `largeTitle` | 1 | app-switcher lock glyph | |
| `footnote.monospacedDigit()` | 1 | find count | |
| `.system(size: 56)` | 1 | tour symbol | **fixed size, doesn't scale** |
| `.system(size: size * 0.47)` | 1 | `IconTile` (15 pt) | **fixed size, doesn't scale** |

102 semantic font uses, 17 distinct; 18 `.system(...)` uses, 8 distinct. Two `@ScaledMetric`s, both for terminal text. Nothing else that has a size (icon tiles 32 pt, row minimums 52/56 pt, the hue edge, the brand emblem, the tour tile 112 pt) scales with Dynamic Type; 11 `isAccessibilitySize` branches in 8 files hide or restack instead.

### Spacing

Stack `spacing:` (99 uses, 15 values):

| Value | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 8 | 10 | 12 | 14 | 16 | 18 | 20 | 22 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Uses | 8 | 2 | 7 | 4 | 18 | **1** | 10 | 10 | 8 | 16 | 7 | 4 | **1** | 2 | **1** |

`.padding` (63 explicit uses, 36 distinct expressions, plus 5 bare `.padding()`): values 2, 3, 4, 6, 7, 8, 10, 12, 14, 16, 20, 24, 48, 56, 60. One-offs: `.horizontal 7` (last-line chip), `.horizontal 14` (FirstUseRow), `.vertical 3` (address chips), `.vertical 10` (activity card), `.top 24`/`.bottom 8` (wait step), `.top 48`/`.bottom 56` (tour), `.bottom 14` (camera note), `.vertical 24` (first use). `WitermMetrics` tokens are used in only 5 places (`pagePadding` 3, `cardPadding` 2); `witermCard(padding:)` is called with 16 (default), 14, and 0.

Readable widths: 420 (camera), 520 (tour ×2, undo bar), 560 (trust sheet), 600 (connection overlay), 640 (`readableWidth`), 700 (session list): **six different column widths**.

### Corner radii

| Radius | Uses | Where |
|---|---|---|
| `cardRadius` 20 | 4 | `witermCard`, connection overlay |
| 12 | 4 | KeyChoiceCard ×3, invitation field |
| 16 | 3 | `IssueBanner` (fill and stroke), forwarding progress |
| relative (`size × 0.3`, `× 0.27`) | 3 | `IconTile`, `BrandEmblem` |
| 28 | 2 | tour tile, camera |
| 8 | 2 | scheme preview, tour keys (the real key row uses 8 in UIKit) |
| 20 literal | 1 | "This Device's Code" tile (**bypasses the token**) |
| 14 | 1 | QR code |
| 6 | 1 | last-line chip |

Grouped lists and forms on iOS 26+ draw their own, larger, concentric section corners, so a `witermCard` (20 pt, 1 pt divider stroke) next to a list section never matches (compare `audit-ios/en-light/04-terminals-empty.png` with `05-devices-empty.png`).

### Color

`WitermTheme` tokens: 142 uses (`secondary` 53, `ink` 23, `warning` 17, `canvas` 11, `positive` 11, `surface` 11, `accent` 10, `actionLabel` 2, `divider` 2, `statusFill` 2). Outside the tokens: 52 uses.

| Non-token color | Uses | Note |
|---|---|---|
| `.foregroundStyle(.secondary)` | 18 | system grey beside `WitermTheme.secondary` (SecondaryInk) in the same screens: SSH form 4, snippets 4, find bar 2, display settings 2, forwarding 2, host row 2, … **Two secondary greys.** |
| UIKit `.label` / `.tertiarySystemFill` / `.systemBackground` | 10 / 3 / 3 | key row, find-bar backdrop |
| `.bar` | 5 | SSH form's bottom bar |
| `.regularMaterial` | 2 | connection overlay, forwarding |
| `Color(white: 0.12)`, `Color.black`, brand gradient RGB | 4 | preview fallback, camera, emblem |

Backgrounds: tabs that are `List`s or custom scroll views paint `Canvas` (#F4F5F7 / #0F1013); `Form` pages and every sheet keep the system grouped background (#F2F2F7 / #000000 or #1C1C1E). Switching tabs changes the page color (`04-terminals-empty` vs `06-settings`).

Opacities (15 uses, 9 values): 0.06 (`statusFill`), 0.09 (canvas glow), 0.1 (TerminalHeader wash), 0.12 ×4 (tints, shadow), 0.14 (emblem stroke), 0.18 (emblem shadow), 0.25 (undo-bar stroke), 0.45 ×2 (banner stroke, offline dot), 0.55 ×3 (hue edges). 0.1 and 0.12 are the same idea.

Measured contrast (WCAG, from the asset catalog): every text token passes on Canvas and Surface, **except `StatusBadge` in the positive tone in light mode: Positive #1A7F4B on its own 12% tint over Surface is 4.28:1**, below 4.5:1 for 12 pt text. SecondaryInk badges reach 5.41 (light) and 4.96 (dark). Non-text: the `IssueBanner` stroke (Warning at 45%) is 2.04:1 on Surface in light, the undo-bar stroke 1.44:1 (both decorative; the banner's icon and text carry the meaning).

### Symbols

54 distinct SF Symbols in 107 uses. Doubles for one idea: `ellipsis` (host row, SFTP rows) vs `ellipsis.circle` (terminal and file menus); three error glyphs (`exclamationmark.circle` 6, `exclamationmark.circle.fill` 1, `exclamationmark.shield.fill` 3); `checkmark.circle` (unpaired note) vs `checkmark.circle.fill` (server reachable); SSH "Connected" is `lock.shield` in a host row and `circle.fill` in a terminal card; `plus` vs `plus.circle.fill` (Keyboard Row). Symbol sizes are text-relative except `IconTile` (15 pt) and the tour (56 pt); `imageScale(.small)` 2.

### Controls and touch targets

| Measure | Value | Uses |
|---|---|---|
| `touchTarget()` (min height 44) | | 20 |
| `touchTarget(square: true)` (44 × 44) | | 8 |
| explicit 44 × 44 frames (host menu, switcher) | | 3 |
| custom row minimum height | 52 | 5 |
| FirstUseRow minimum height | 56 | **1** |
| key row key | ≥ 44 wide, height max(44, callout line + 12) | UIKit |
| tour key miniature | 40 × 36 | decorative |
| `controlSize` | `.large` (PasteButton), `.small` (spinner); `witermControl()` large capsule | 2 + all primaries |
| button styles | `plain` 11, `bordered` 5, `borderless` 2, `glassProminent`/`borderedProminent` 2+2, `glass` 1 | |

Containers: `List(.insetGrouped)` 2 (Terminals, Devices), `Form(.grouped)` 13, and five custom `ScrollView` screens (first use, a device's terminal list, Add Device scan and wait, trust sheet). Navigation titles: 12 inline; large titles inside the Device Details, Add SSH Host, Host Keys, Port Forwarding, and SFTP sheets and on the Text and Colors, Bell and VoiceOver, and Snippets pages, but inline on Keyboard Row, Relay Servers, and a server's page. Sheet detents: **one** sheet (add or edit relay server). Haptics: `sensoryFeedback` success 3, error 3; a selection tick when a terminal selection starts; the bell.

Accessibility modifiers: `accessibilityHidden` 28, `accessibilityElement` 20, `accessibilityLabel` 19, `accessibilityHint` 8, `accessibilityValue` 7, traits 6, actions 3. **None** of `accessibilityInputLabels` (Voice Control names), `accessibilityRotor`, `accessibilityShowsLargeContentViewer`, `accessibilitySortPriority`.

`lineLimit(1)` sites (truncation risks in Chinese and at AX sizes): TerminalHeader ×3, paired title, SSH title, last-line chip, snippet text, Devices server header, relay server row, paired-device detail, address chips.

## 3. Proposed tokens and component rules

Rule zero: **prefer the system component.** Most of the drift above comes from hand-built cards and rows that imitate a `List` or `Form` and then differ from it. Where a screen is a list of things, use a `List`/`Form` row with the standard metrics; keep custom surfaces for the terminal, banners, and the tour.

Tokens live in `apps/apple/Sources/Design/`. **Shared** means one definition for both apps (the Mac may map it to a smaller value inside `#if os(macOS)`, as `witermControl()` already does); **iOS** means iOS-only.

### Spacing scale (`WitermMetrics.Space`): shared

A 4 pt grid with 2 for hairline stacks.

| Token | pt | Use | Replaces |
|---|---|---|---|
| `xxs` | 2 | title over subtitle in a bar, badge stacks | 1, 2, 3 |
| `xs` | 4 | label stacks inside a row, icon to text in a badge | 3, 4, 5 |
| `s` | 8 | between controls in a row, chips | 6, 7, 8 |
| `m` | 12 | icon tile to text, banner insets, row vertical inset | 10, 12, 14 |
| `l` | 16 | card padding, between cards | 16, 18 |
| `xl` | 20 | page margin (`pagePadding`) | 20, 22 |
| `xxl` | 32 | section gaps in custom scroll views, tour | 24, 48, 56 |

Rows inside `List`/`Form` take no extra padding at all.

### Type ramp (semantic roles): shared

Use roles, never sizes, so both platforms and Dynamic Type follow.

| Role | iOS style | Use |
|---|---|---|
| `pageTitle` | navigation title (large on tab roots, inline everywhere else) | |
| `heroTitle` | `title2.bold()` | tour and empty states only |
| `rowTitle` | `body` (list rows), `headline` (cards and banners) | one per row |
| `rowDetail` | `subheadline`, SecondaryInk | second line of a row, explanations |
| `meta` | `caption`, SecondaryInk | badges, ages, hints under fields |
| `code` | `body.monospaced()` | fingerprints, device codes, addresses on detail pages |
| `codeInline` | `caption.monospaced()` | addresses and last lines in rows |
| `codeHero` | `title3.monospaced()` | the one code a person compares on a pairing screen |

Weights: regular and `.semibold` only (drop `.medium`, `.bold` except `heroTitle`). One spelling for monospace (`.monospaced()`), one grey (`WitermTheme.secondary`, never `.secondary`).

### Radii (`WitermMetrics.Radius`): shared

| Token | pt | Use |
|---|---|---|
| `s` | 8 | keys, chips' inner shapes, previews |
| `m` | 12 | fields and nested cards (KeyChoiceCard, invitation field, code tiles) |
| `l` | 20 | cards and banners (`IssueBanner` moves from 16 to 20) |
| `xl` | 28 | hero tiles and camera |
| `capsule` | | badges, chips, undo bar, buttons |

Inner shapes must be concentric: inner radius = outer radius − padding. On iOS 26+, list sections and sheets are concentric with the display; custom cards that sit next to them should use `ConcentricRectangle`/`.containerConcentric` where available instead of a fixed 20.

### Color and opacity: shared

Keep the asset-catalog tokens. Add `WitermTheme.tint(_:)` = 12% fill, `edge` = 55% hue line, `hairline` = `divider`. Retire 0.1, 0.25, and 0.45 strokes in favor of `divider` or a symbol. **One page background per platform:** either paint `Canvas` behind every `Form` and sheet too (`scrollContentBackground(.hidden)` + `background(canvas)`), or drop `Canvas` on iOS and use the system grouped background everywhere; the second is less code and matches system sheets. Darken Positive in light mode to about #157043 (≥ 4.5:1 on its own tint), or give the positive `StatusBadge` a neutral fill.

### Symbols: shared

One symbol per idea, following the Wording section: error `exclamationmark.triangle.fill` (or keep `exclamationmark.circle.fill`, but one), revoked/unpaired `exclamationmark.shield.fill`, more actions `ellipsis.circle` everywhere, connected `circle.fill` badge, disconnected `bolt.horizontal.circle`. Put the mapping in `WitermSymbols` beside `WitermTheme`.

### List rows: iOS

| Row | Metrics |
|---|---|
| One-line row | system (44 pt min) |
| Two-line row with icon | `IconTile` 32 pt scaled with `@ScaledMetric(relativeTo: .body)`, `m` (12) gap, title `body`, detail `subheadline`/`caption.monospaced()`, min height 52 scaled |
| Leading icon | every row in a list either has an `IconTile` or none does (Devices mixes tiles, bare symbols, and `Label` icons) |
| Trailing | system chevron via `NavigationLink`, or one `ellipsis.circle` menu button 44 × 44; never both |
| Actions | swipe actions mirror the menu: trailing Delete (destructive, full swipe), leading Favorite; context menu = same items |
| AX sizes | icon hides, detail wraps, trailing menu moves to swipe/context menu |

### Cards: iOS (shared component)

A card is for one live object with several facts (an open terminal, a banner, a code to compare), never for a list of navigation rows. Padding `l` (16), radius `l`, Surface fill, no stroke in light/dark (keep the stroke only with Increase Contrast). The first-use screen becomes an inset-grouped list section.

### Sheets and detents: iOS

| Sheet | Detents | Title | Dismiss |
|---|---|---|---|
| Device Details, Host Keys | `.medium, .large` | inline | Done |
| Terminal Display | `.medium, .large` | inline | Done |
| Snippet editor | `.medium, .large` | inline | Cancel / Save |
| Add or edit relay server | `.medium, .large` (already) | inline | Cancel / Add |
| Add SSH Host, Edit SSH Host | `.large` | inline | Cancel; primary at the bottom |
| Add Device | `.large`; `.medium` when there's no camera | inline | Cancel |
| Trust host, paste review | `.large`, interactive dismiss off | inline | Cancel / primary |
| SFTP Files, Port Forwarding | `.large` | inline | Done |

All sheets: inline titles, `presentationDragIndicator(.visible)` where there are several detents, first field focused on appear.

### What to share with the Mac through `apps/apple/Sources/Design/`

| Item | Where | Shared? |
|---|---|---|
| Spacing scale, radii, opacity tokens | `WitermMetrics` | **yes**; the Mac may compress `m`/`l` inside `#if os(macOS)` |
| Type roles | `WitermTheme` or a `Font` extension | **yes** |
| Color tokens, `tint`, `edge`, `hairline`, Positive fix | asset catalog + `WitermTheme` | **yes** |
| `WitermSymbols` | new file in Design | **yes** |
| `StatusBadge`, `IssueBanner`, `IconTile` (scaled), `witermCard` | `Components` | **yes** |
| `TerminalActivityCard`, hue edge (2 pt, 55%) | `TerminalActivityViews` | **yes** (the Mac already uses the 2 pt edge) |
| Readable width (one value, 640) | `WitermMetrics` | **yes** |
| Row metrics, swipe-action rule, 44 pt targets, detents, key-row metrics | `Components` (`#if os(iOS)`) | iOS only |
| Hover, pointer, toolbar rules | `Components` (`#if os(macOS)`) | Mac only |

## 4. Task walkthroughs

Counted on the iPhone 18 Pro simulator in English at the default text size (SSH tasks against the disposable fixture; paired tasks from code and `round10-joint`). **Taps** are deliberate taps by the person, excluding typing and system prompts (counted separately); **screens** are distinct full screens or sheets seen; **reading** is the visible words a first-time user must read to choose correctly (titles, instructions, and footers on the path, not the content they type).

| # | Task | Taps | System prompts | Screens | Reading | Friction | Findings |
|---|---|---|---|---|---|---|---|
| 1 | First launch: tour to Terminals | 3 (Next, Next, Get Started) or 1 (Skip) | 0 | 4 (3 pages, Terminals) | 43 words | Fine. Page 1 says "Tap +" while the screen behind offers a large "Connect to an SSH Host" row as well; page 3 says "long-press to copy", but copying needs a long press and then Copy. | F-37 |
| 2 | Add and connect an SSH host (password, first trust) | 5: Connect to an SSH Host, address field, password field, Connect, Trust and Connect (+1 OK on the one-time tmux tip) | 1 (iOS "Save Password?": Not Now) | 4 (Terminals, form, trust sheet, terminal) | ~60 words (form labels and hints, the trust sheet) | The address field isn't focused when the form opens (an extra tap). The trust sheet's fingerprint is shown but not compared to anything; acceptable, as designed. The keyboard comes up on connect. | F-20, F-27 |
| 2b | Reconnect a saved host (credentials not saved) | 3: host row, password field, Connect | 0–1 | 3 | ~25 | Default **Save Credentials** is off, so every reconnect asks again; no Face ID unlock option. | F-33 |
| 3 | Add Device by paste (pairing code) | From Devices: 3 (Devices tab, Add Device, Paste) + Request Access = **4**; from first use: 3 | 0 (PasteButton needs no permission) | 4 (Devices, Add Device, Check the Other Device, Approve on…) then the terminal | ~55 words (camera note, instruction, code footer, server footer) | Without a camera the sheet says to paste "below" before saying where to get the invitation; the check screen's footer says "Continuing adds this server" under a button that says Request Access. | F-23, F-22 |
| 4 | Open a paired terminal (already paired) | 1 when the device shares one terminal; 2 otherwise (device, terminal) | 0 | 2–3 | 2–6 words | Good. On iPad the paired terminal replaces the split view, so the list disappears *(code)*. | F-08 |
| 5 | Stop Typing, then Start Typing | 2 + 2 (ellipsis, item; twice) | 0 | 1 (menu) | 5 menu items | No hardware-keyboard shortcut on iOS (the Mac has ⇧⌘T); no haptic confirmation of the switch, only the title change and a VoiceOver announcement. | F-09, F-38 |
| 6 | Unpair a device | 4 from Terminals: Devices tab, info (ⓘ), Unpair…, Unpair | 0 | 3 (Devices, Device Details sheet, alert) | ~30 words | The ⓘ is a 44 pt target but the row itself jumps to another tab; a device paired twice shows twice and unpairing one removes both. | F-01, F-07 |
| 7a | Recover an SSH terminal after disconnect | 1 (Reconnect) when credentials are saved; 3 otherwise | 0 | 1–2 | ~12 words ("SSH Disconnected", address, reason) | Good; "SSH Disconnected" vs "Disconnected" on the card. | F-29 |
| 7b | Recover from offline | 0 to see why (banner), 1 to reconnect after the network returns | 0 | 1 | 23 words in the banner | The banner is long (two sentences) on a terminal screen. | F-30 |
| 8a | Larger terminal text (in a terminal) | 2 (ellipsis, A) or pinch | 0 | 1 | 0 | Pinch gives no live preview and no size readout until the fingers lift. | F-32 |
| 8b | Change the terminal color scheme | 4 (Settings tab, Text and Colors, Color scheme, choice) | 0 | 3 | ~30 (incl. 2 footers) | Fine; one section header is "Appearance" again, under the Settings group also called Appearance. | F-30 |
| 8c | Add a relay server by hand | 4 (Settings tab, Relay Servers, Add Server, field) + Add and Check | 0 | 3 | 26 | The sheet's title truncates ("Add Relay…") at the default text size; the field isn't focused. | F-10, F-20 |

Totals against the Round 7 baseline: the post-connect tasks (2, 4, 5, 7a, 8a) are at or near their minimum. The setup tasks (2, 3, 8c) each spend one tap on an unfocused field and 25–60 words of reading, mostly footers the [Wording](README.md#wording) rule ("no explanatory footers") already discourages.

## 5. Known follow-ups

### 5.1 Devices: one row per device, not per pairing (F-01)

Today `RemoteTerminalModel.grants` is a flat list of `DeviceGrant`s and both tabs render one row per grant. Proposal:

- **Model.** A `PairedDeviceGroup` keyed by `(server.id, grant.host.id)`, holding its grants newest first. `permission` = `.control` if any grant has it; `code` = the newest grant's host key (they're the same device key unless the device was reset, in which case the newest wins and the older grant is shown as replaced in Device Details).
- **Rows.** Devices → Paired Devices and Terminals → (unnamed section) list groups. The row's detail stays "Can only watch" only when *no* grant can type.
- **Opening.** Opening a group selects its newest grant (the one the Mac most recently approved), as `openMac` does now for the one grant.
- **Unpair.** Already ends every grant for the host on one relay server (`pairings(endedBy:)`); extend it to every server in the group, and have the confirmation add "…on all relay servers" when the group spans several.
- **Across servers.** The same device paired through two relay servers is still one device to the person: list it once under the device name, with the servers in Device Details. Keep the per-server section headers only for server *problems*.
- **Tests.** Two grants for one `host.id` render one row; Unpair removes the row once; permission merges to control.

### 5.2 Chinese (zh-Hans)

Captured: `zh-light/*` and `zh-ax5-dark/*`, the same screens as English.

At the default text size, Chinese fits everywhere it was captured: Chinese labels are shorter than English, so the English truncation of "Add Relay…" (F-10) doesn't occur (添加中继服务器 fits beside 添加并检查, though the title sits off-center). No clipped buttons, tabs, menu items, or section headers in `zh-light/*`.

The risks are words and mixed scripts, not width:

| Item | Where | Finding |
|---|---|---|
| 仅观看 (Watching, a state) vs 仅可观看 (Can only watch, a permission) differ by one character; 可输入 (Typing) reads as a permission | terminal title, device rows, menus | **F-49 (P1)** |
| 验证码 used for a scanned QR code; 新建 (a verb) as the "New" badge | Add Device | F-50 |
| 服务器 for an SSH host in the New Key card ("将公钥复制到服务器") | SSH form | F-21 |
| Key row: faces stay English (Esc, Ctrl, Tab) while names are Chinese (退出键, 下一键使用 Control, 制表键); Voice Control needs both | key row, Keyboard Row settings | F-04 |
| 14 磅 for "14 pt": correct typographic term, but the terminal font size elsewhere (menus, VoiceOver) should use the same word | Settings, Text and Colors | — (consistent today) |
| Addresses, ports, and code keep Latin monospace inside Chinese sentences; mid-sentence wrapping keeps them whole at default size | relay server errors | — |

`lineLimit(1)` sites that would truncate first with long Chinese device names (Chinese device names are often 10+ characters, e.g. 某某的 MacBook Pro): the paired terminal's title line ("可输入 · *device*" keeps the state first, as designed), the Devices server header (with several servers), and the relay server row (F-11).

At AX5 (`zh-ax5-dark/*`), Chinese behaves better than English in two places (the Add Relay Server sheet keeps its title, 添加中继服务器, where English loses it) and the same in the rest: the relay server name still truncates to "local…7429" (F-11), addresses break mid-word and mid-port (F-47), and the SSH form's pinned bar takes a quarter of the screen (F-46). One Chinese-only break: the port hint splits its quoted token across lines (“: / 端口”), which a non-breaking `:端口` would avoid. The leftover hosts in `zh-light/04`, `05` and `zh-ax5-dark/04` came from the AX5 accident described in F-46; `testAuditCleanup` removed them.

### 5.3 AX5 Dynamic Type, screen by screen

Captured with `UICTContentSizeCategoryAccessibilityXXXL` (`en-ax5/*`, `zh-ax5-dark/*`, `ssh-live/14–17`). "Pass" means everything is reachable and readable by scrolling, nothing essential truncates, and actions stay within reach.

| Screen | Result | Notes | Finding |
|---|---|---|---|
| Welcome Tour | **Fail** | Text scrolls, but the page dots float over the content: over the last line on page 2 and over the key miniature on page 3 | F-36 |
| Terminals, first use | Pass, minor | Rows wrap well; the 56 pt brand emblem stays and pushes the first action down | F-39, F-40 |
| Terminals, hosts | **Fail** | Addresses hyphenate ("ex-ample.in-valid") | F-47 |
| Host actions menu | Pass | System menu scales | |
| Devices | **Fail** | Address in the relay error breaks inside the port ("localhost:37 / 429"); the Add Device tile isn't hidden at AX sizes like the other tiles | F-47, F-39 |
| Settings index | Pass | `LabeledContent` stacks values under labels | |
| Text and Colors | Partial | Large title truncates ("Text and Col…"); the Stepper label splits into columns; the preview doesn't show the effective size | F-16 |
| Bell and VoiceOver | Pass | | |
| Keyboard Row | Pass, heavy | Each key takes a third of the screen; the permanent edit controls dominate | F-28 |
| Snippets | Partial | Empty-state sentence is 7 lines; "Add Snippet" is below the fold | F-34 |
| Relay Servers | **Fail** | Server name truncates in the middle; the badge hyphenates | F-11 |
| Add Relay Server sheet | **Fail** | No title at all; medium detent shows one line of the footer | F-10 |
| Add Device | Pass | Actions first, as designed | |
| Add Device, invalid invitation | Pass, heavy | The warning is 9 lines before the field | F-30 |
| Check the Other Device | Not captured | The test couldn't reach Request Access at AX5 (field and Continue below the keyboard); covered by `zh-ax5-dark` if present | |
| Add SSH Host | **Fail** | Pinned action bar covers a quarter of the screen; the Host chip truncates; during the run a tap meant for a field landed on Save for Later through the bar and saved a host | F-46 |
| SSH terminal | **Fail** | Title bar fits (the address middle-truncates); terminal text at ~40 pt, ~16 columns; key row shows four keys; the actions menu scales (`ssh-live/16`, `17`) | F-52 |
| Paired terminal *(code)* | Likely partial | The title is two lines at `.headline`/`.caption` with `lineLimit(1)`; at AX5 the state line ("Watching · Typing on *device*") truncates; `TerminalSwitcher` sits beside it | F-11 pattern |

### 5.4 Light and dark

Every screen was captured in both (`en-light`, `en-dark`; `zh-ax5-dark` repeats dark at AX5 in Chinese). Tokens adapt correctly; the problems are the ones that sit outside them:

| Screen | Light | Dark | Finding |
|---|---|---|---|
| Tab backgrounds | Canvas #F4F5F7 vs system #F2F2F7 (subtle) | Canvas #0F1013 vs system black (obvious) | F-15 |
| Paste button | white on graphite, fine | white on #A3A5A7, 2.5:1 | F-02 |
| Positive badge | 4.28:1 | 7.65:1 | F-03 |
| Terminal display preview | visible | no edge against the row | F-45 |
| Tour page dots | current dot white on light grey | fine | F-36 |
| Cards (`witermCard` stroke) | 1 pt divider stroke visible | stroke barely visible; cards rely on Surface | F-18 |
| Terminal, header hue edge, selection | `ssh-live/04`, `round10-joint` | `ssh-live/10-terminal-dark.png` | F-42 |

No in-app appearance override exists (correct per AGENTS.md); terminal colors follow the system through `TerminalColorScheme.system`.

### 5.5 iPad regular width *(code; no iPad simulator on this Mac)*

| Item | Code | Problem | Proposal |
|---|---|---|---|
| Split view nested in a stack | `MobileWorkspaceView.swift:69`, `SSHWorkspaceView.swift:418` | `NavigationSplitView` inside the Terminals tab's `NavigationStack` | Split view as the root on regular width (F-08) |
| Paired terminal replaces the split view | `MobileWorkspaceView.swift:70` (`if let activeMac`) | The sidebar disappears for paired terminals; SSH keeps it | Paired devices in the same sidebar; terminal in detail (F-08) |
| Tab bar on iPad | `MobileWorkspaceView.swift:68` (`.tabItem`) | Three top tabs plus a sidebar inside one of them | `Tab` API + `.sidebarAdaptable`, Terminals' sidebar becoming the app sidebar |
| Devices and Settings | `DevicesView`, `MobileSettingsView` | Phone-width single columns stretched to 1000+ pt; `readableContent` caps only custom screens | Two-column (list → detail) on regular width, or `.frame(maxWidth: 640)` for forms |
| Terminal header | `TerminalHeader` in `RemoteTerminalWorkspace`/`SSHWorkspaceView` | iPad uses a second header row (name, status, actions) under the navigation bar, iPhone puts them in the bar: two patterns | Use the navigation bar on iPad too (`.toolbar` principal + trailing), keep `TerminalHeader` for the Mac only if at all |
| Keyboard | `WitermCommands` | Most terminal commands are Mac-only (F-09) | Share the Terminal menu |
| Pointer | none on iOS | No `hoverEffect` on custom rows, cards, key-row keys | `.hoverEffect(.highlight)` on custom tappable views; keys get `UIPointerInteraction` |
| Multitasking | `.frame(maxWidth: 700)`, `600`, `560` | Six readable widths (see Spacing) behave differently in Split View and Slide Over | One `readableWidth` |
| Selection highlight in the sidebar | `TerminalsHome.swift:131` | hue 12% background on the shown host; no selection for paired devices | Use `List(selection:)` so the system selection, keyboard focus, and VoiceOver selected trait come for free |

## QA notes

**Environment.** Xcode at `/Applications/Xcode.app`, derived data inside the worktree, simulator <simulator-udid> (iPhone 18 Pro, iOS 27.2, already booted; nothing created or erased), parallel testing off, one `xcodebuild` at a time. The Mac app and its service weren't touched.

**Screenshots without a network** (about 20 minutes for the five variants):

```sh
xcodebuild build-for-testing -project apps/apple/Witerm.xcodeproj -scheme WitermiOS \
  -destination 'id=<simulator-udid>' -derivedDataPath .build/DerivedData
TEST_RUNNER_WITERM_AUDIT_DIR=.build/screenshots/audit-ios \
xcodebuild test-without-building -project apps/apple/Witerm.xcodeproj -scheme WitermiOS \
  -destination 'id=<simulator-udid>' -derivedDataPath .build/DerivedData \
  -parallel-testing-enabled NO -only-testing:WitermiOSUITests/AuditScreenshotTests/testAuditScreens
```

The test switches the simulator's appearance with `XCUIDevice.shared.appearance` and restores the original value in `tearDown`; text size and language are launch arguments only. The relay server it saves (`http://localhost:37429`) is unreachable on purpose, so status screens show a failed check. Its one saved host is deleted through Delete Host.

**Live SSH screenshots.** A disposable fixture from `tools/ssh-fixture/compose.yaml` with fresh keys in a private temporary folder (project `witerm-ssh-audit`, `target` only, on a random loopback port), then:

```sh
TEST_RUNNER_WITERM_AUDIT_DIR=… TEST_RUNNER_WITERM_SSH_UI_PORT=<port> \
TEST_RUNNER_WITERM_SSH_UI_FINGERPRINT=<SHA256 of target/host.pub> \
xcodebuild test-without-building … -only-testing:WitermiOSUITests/AuditScreenshotTests/testAuditLiveSSH
```

It checks the fingerprint before trusting, removes the host's pinned key through Host Keys (only if it is the fixture's), deletes the host, and the fixture is taken down afterwards. No user SSH configuration, key, or host is read.

**Inventory script.** `python3 -I inventory.py apps/apple/Sources` strips `#if os(macOS)` branches, then counts regex matches for `.font(`, `spacing:`, `.padding(`, `cornerRadius:`, `.opacity(`, `.frame(`, `WitermTheme.*`, other color literals, `systemImage:`/`systemName:`, `touchTarget`, button and list styles, title modes, detents, haptics, and accessibility modifiers. Contrast ratios come from the asset catalog JSON with the WCAG relative-luminance formula, and alpha tints are composited over Surface. The scripts are kept out of the repository (they're one-off measurement tools); the counts above are their output on 1291bce.

**Run record (this audit).** `testAuditScreens` captured 132 screenshots in 18 minutes with 9 soft failures, all at AX5 where an element stayed under the pinned SSH form bar or below the fold (Keyboard Row and Relay Servers rows, More Options, the name field); the AX5 "Check the Other Device" screen wasn't reached. At AX5 one tap meant for a field landed on **Save for Later** through the pinned bar and saved a host named `deploy@build.example.invalid` (F-46); the test now leaves the form with Cancel. `testAuditLiveSSH` captured 19 screenshots; XCTest can't type into the terminal's input view, and the snippet it now uses to produce output wasn't created in this run, so the terminal shows only the fixture's login message. Its own cleanup stopped at an ambiguous alert button (fixed with `firstMatch`), so `testAuditCleanup` (with `WITERM_AUDIT_CLEANUP=1` and the fixture fingerprint) removed the fixture's pin, both audit SSH hosts, and the accidental hosts. The simulator ends with no audit data, and its original appearance; language and text size were only ever launch arguments.

**Not covered.** Paired-terminal screens on this build (the simulator isn't paired; Round 10's joint-run screenshots stand in); iPad (no simulator; code only); real VoiceOver speech and Voice Control (code and labels only); Bold Text, Increase Contrast, and Reduce Transparency/Motion (code paths read, not captured: launch arguments can't set them and changing the simulator's settings was out of scope); a physical camera; the system paste prompt (F-13).
