# Mac UI/UX Audit (Phase 1)

An audit of the Mac app on 2026-11-03, before any change, toward production-grade interaction, layout, visual consistency, and Apple HIG conformance. It follows the [design guidelines](README.md) and the [HCI log](hci-improvements.md) through Round 9. No app source was changed in this phase.

**Build audited.** Main at `1291bce`. The installed signed app (`.build/Applications/Witerm.app`, built 04:35 on 2026-11-03, after the last app-code commit `8c4f0f3`) has the same UI code.

**Roles.** Every finding names the role that found it: **VD** (visual and layout designer), **PS** (macOS platform specialist), **A11Y** (accessibility specialist), **IxD** (interaction designer), **UXW** (UX writer), **UXR** (UX researcher), and **QA**.

## Evidence and reproducibility (QA)

- **Live captures.** Once UI automation was authorized, the opt-in `AuditScreenshotTests` ran in one batch against the installed signed app and passed in 705 s. It produced 146 attachments, in `.build/screenshots/audit-mac/live/<pass>/NN-name.png`:
  - three accessibility-tree dumps (`en-light/tree-*.txt`);
  - `metrics.txt`.

  The first pass also used a disposable OpenSSH fixture on 127.0.0.1. The test made only "Audit A", "Audit B", and one "Audit Host", and ended or deleted each; Terminal 1, remote access, and the service were untouched. Teardown quits the GUI, so the installed app was relaunched afterwards (one instance).
- **What the passes really show.**
  - **All three passes rendered dark.** `-AppleInterfaceStyle Light` doesn't override the system's Dark appearance on macOS 27, so the folders named `en-light` and `zh-light` are English dark and Chinese dark. Light still needs the system appearance switched, which this audit may not do. The app has no appearance override, and AGENTS.md rules out an in-app one.
  - **Paired-device screens weren't reached.** Nothing is paired on the relay server, so Open On ▸ went straight to the code step, and the device step, Approve, and the device Edit sheet were never shown.
  - **Some captures are missing.** The Open On ▸ New Device… and Someone Else… captures (23, 24) didn't happen. Three hover targets weren't hittable: the toolbar +, a device card, and Check Now.
- **Earlier captures.** Round 8 and Round 9 captures (English, dark) are kept in `.build/screenshots/audit-mac/prior-en-dark/` for the screens above.
- **Measurements.** The scripts are in `.build/screenshots/audit-mac/tools/`:
  - `inventory.py`: the visual inventory, counting only lines the Mac build compiles. Its raw output is `inv-mac.txt`.
  - `contrast.py`: token contrast ratios.
  - `vocab.py`: zh-Hans vocabulary consistency, read-only on `Localizable.xcstrings`.
  - `fixture.sh`: a disposable OpenSSH fixture on 127.0.0.1, with keys in a private temp folder.
- **Not testable without changing the user's system.** Increase Contrast, Reduce Motion, Reduce Transparency, and the macOS Text Size setting are system-wide, and VoiceOver speech needs a person listening. These are reviewed from code only and marked *(code)*.

## 1. Findings

`live/` means `.build/screenshots/audit-mac/live/`.

Ranks: **P0** broken, misleading or inaccessible · **P1** clearly below production quality · **P2** inconsistency or polish · **P3** nice to have. Effort: **S** < ½ day · **M** ½–2 days · **L** > 2 days.

### P0

| ID | Role | Surface | Issue | HIG / heuristic | Evidence | Proposed fix | Effort |
|---|---|---|---|---|---|---|---|
| M-01 | UXW, A11Y | Open On ▸ sheet: code and approve steps | **"Code" names two different things, and one of them is a trust check.** In the vocabulary, the code is the device fingerprint you compare by eye ("This Mac's code", "Device Code", Approve: "Check that *X* shows this code"). The sheet also calls the QR invitation "code": Show Code, Show New Code, Making a code…, The code expired…, strip step **Code**, "Point at the code". zh-Hans translates both as 验证码 (verification code). On the code step, "This Mac's code" sits beside a QR titled "Scan with the Other Device", so a person can't tell which "code" Approve later asks them to compare. That's a misread on the one step whose purpose is a trust decision. | Writing: one term per idea; Nielsen #2 match, #4 consistency; standing requirement "terminology users can't misread" | `live/en-light/20-continue-first-step.png` and `live/zh-light/20-…` (这台 Mac 的验证码 next to the QR under 用另一台设备扫描); `ContinueOnDeviceSheet.swift:252,275,294,490,505,519`; `vocab.py` (code → 验证码 ×18, 二维码 ×1) | Keep **code / 验证码** for the fingerprint only. Call the scannable thing the **QR code / 二维码** (Show QR Code, Making the QR code…, The QR code expired…, strip step **Scan**). Label the fingerprint "This Mac's code (compare on the other device)" only on Approve, not beside the QR. Update the README Wording table. Do it with iOS, which has the same "Scan a Code Instead" and "Point at the code". | S (strings) + catalog |
| M-02 | A11Y, IxD | Sidebar footer → Settings → Devices | **VoiceOver and keyboard activation open the wrong Settings tab.** The footer is a `SettingsLink` whose Devices tab is set by `.simultaneousGesture(TapGesture())`. That only fires on a mouse click, so VoiceOver's press (VO-Space) and Full Keyboard Access's Space open Settings on whatever tab was last shown. Meanwhile the VoiceOver hint promises "Opens Settings → Devices". | Accessibility: every action reachable the same way; WCAG 2.1.1 | `MacWorkspaceView.swift:507–536` | Use a `Button` that sets `settingsTab = devices` and then calls `@Environment(\.openSettings)`, as `StartFromTerminalHint` does (`LocalTerminalWorkspace.swift:238–241`). | S |

### P1

| ID | Role | Surface | Issue | HIG / heuristic | Evidence | Proposed fix | Effort |
|---|---|---|---|---|---|---|---|
| M-03 | A11Y, VD | Open On ▸ sheet; device Edit sheet | **Fixed-height, scroll-disabled Forms clip content.** The server step is 110 pt, permissions 96, the reach picker 130 or `120 + 26 × n` pt, the invite step 200, and the Edit sheet 220 or 150. All are `.scrollDisabled(true)` inside a `ScrollView`, and four use `.padding(.horizontal, -20)` to cancel the Form inset. A row with a second line (a shared terminal's caption, an activity line, All terminals' note) is taller than 26 pt, so the last rows are cut off and can't be scrolled to. The same happens with longer zh strings or a larger macOS text size. | Layout: content adapts to text and localization; WCAG 1.4.4 / 1.4.10 | `ContinueOnDeviceSheet.swift:381,575,698,1006`; `MacDevicesView.swift:357–359`. *Code evidence only:* the live run had no paired device, so neither Approve nor the Edit sheet appeared. Priority unchanged. | Make each step a single scrolling grouped `Form` (Sections for reach, permission and code), or plain `VStack` rows with intrinsic height. Delete the fixed heights and the negative paddings. | M |
| M-04 | PS, A11Y | SSH first-connection (trust) sheet | **An iOS layout with no keyboard path.** "Trust and Connect" is a full-width glass button inside the scroll content, with a plain-text Cancel below it. Neither has `.defaultAction` or `.cancelAction`, and the sheet is `interactiveDismissDisabled`. Esc does nothing, and without Full Keyboard Access (off by default) the keyboard can't reach either button. On top of that, the sheet title is a `navigationTitle` inside a sheet. | macOS sheets: buttons bottom-right, default rightmost, Esc cancels | `live/en-light/43-ssh-trust-sheet.png`: the title sits in a toolbar band, the full-width pill and centered Cancel sit mid-sheet, and the bottom 40% is empty; `SSHWorkspaceView.swift:237–295` | Use a bottom-trailing footer: Cancel (`.cancelAction`), then Trust and Connect. Don't give Trust Return (it's a trust decision, like Approve). Put an in-content `title2` header in the shared sheet scaffold (M-05). | S |
| M-05 | PS, VD | Every sheet | **Five ways to lay out sheet actions.** (1) A custom footer with `.large` capsule buttons (Open On ▸, device Edit, Manage Servers, Welcome Tour). (2) A `.bar` inset with a glass Primary at max 200 pt plus a toolbar Cancel (SSH form). (3) Toolbar `cancellationAction` / `confirmationAction` (Snippet editor, Import, Server address, Host Keys, Forwarding, SFTP, where "Done" is placed as a *cancellation*). (4) An inline HStack with regular controls (Rename). (5) In-content full-width buttons (SSH trust). Button size, shape, position and Esc behavior change from sheet to sheet. | Consistency (Nielsen #4); HIG sheets and push buttons | `live/zh-light/41-ssh-form-empty-errors.png`: **two footers**, 保存以后使用 / 连接 above a second bar holding only 取消. `live/en-light/47-ssh-sftp.png`: Done and File Actions both in the footer. `live/*/20-…`, `00-rename-…`, `72-tour-…`; `ContinueOnDeviceSheet.swift:165–207`; `MacDevicesView.swift:363–373,459–470`; `MacWelcomeTour.swift:75–91`; `SSHProfileForm.swift:186–212`; `SSHFilesView.swift:200`; `LocalTerminalWorkspace.swift:376–384` | One `SheetScaffold` (header, scrolling content, `Divider`, footer): secondary and destructive actions leading, then Cancel and the primary trailing, all `.regular` (see §3). It lives in `Components.swift`; iOS keeps toolbar placements. | M |
| M-06 | A11Y, VD | Settings → Devices and every switch | **On a dark appearance, the On state of a switch is hard to see.** `witermTint()` tints Settings with AccentColor, `#ECEEF2` in dark, so Allow Remote Access *on* is a light-grey track with a white knob, close to how *off* looks. Terminal and Snippets switches use `.tint(WitermTheme.positive)` (green) instead, so switches in one window come in two colors. | Color: state not by subtle color; HIG toggles use the system accent; README "Mac target sets no global accent" | Confirmed live in both passes: `live/en-light/33-settings-devices.png` and `live/zh-light/33-…` (允许远程连接 on: a grey track) against `live/zh-light/31-settings-terminal.png` (终端响铃 on: green; 增强终端对比度 off: dark). Light is untested; there the ink tint is near-black, which reads as on. `MacSettingsView.swift:40`; `TerminalAppearanceSettings.swift:53,85,95`; `SnippetSettings.swift:101` | Remove `witermTint()` from the Settings scene and from Mac sheets that hold system controls, and let switches, radios and checkboxes use the system accent. Keep the ink tint only for `PrimaryButton`. Drop the green `.tint` on the Mac. | S |
| M-07 | IxD, UXR | Relay offline and service off | **Recovery is under-explained.** While the relay is unreachable the footer stays "Remote access on · Connecting…" with no reason, no time, and no action until a check fails (checks run at launch and on foreground). `OfflineBanner` appears only on SSH host pages, not in the footer, Settings → Devices, or the Open On ▸ sheet. With remote access off there's no footer at all, by design. | Visibility of system status; "Honest status" principle | `MacWorkspaceView.swift:548–575,602`; `MacRemoteAccessSettings.swift:19–24` | After about 10 s of Connecting…, say why in the footer ("Can't reach *server*" or "No network") with the warning tint. Clicking it opens Devices with **Check Now**. Show `OfflineBanner` in Settings → Devices and the sheet's server step as well. | M |
| M-08 | UXR, IxD | Re-pairing (follow-up 5a) | **A second pairing with the same device looks like two devices.** See §5a. The server allows one active grant per pair of *identities*. A re-pair after either side gets a new identity (another signed build, another Keychain, another spelling of the server) therefore leaves the old grant active, and the lists show two rows with the same name and nothing to tell them apart. The Approve step's "Already paired" notice compares identity IDs only, so it never appears in this case. | Error prevention; recognition | `DevicePairingModel.swift:161–179`; `MacDevicesView.swift:167–171`; `RemoteTerminalModel.swift:562–564`; `0001_identity.sql:26` | On Approve, when the requester's **name and platform** match an existing grant with a different ID, show "*X* is already paired (paired *date*). Approving adds a second pairing." with **Replace the Older Pairing** (default on). Device rows show "Paired *date*" when two share a name. | M |
| M-09 | PS | SFTP Files sheet | **iOS interaction on the Mac.** A single click on a file downloads it, and on a folder navigates. Each row has a 44 × 44 pt "…" menu, there's a "Parent Folder" row, and a path field with Go. There's no selection, no double-click, no context menu, and no drag to or from Finder. | HIG lists and tables: click selects, double-click opens, context menus | `live/en-light/47-ssh-sftp.png`: the path field shows the raw "." instead of the resolved home path; "Parent Folder" is a pill above "Folder Is Empty"; Done and File Actions sit together in the footer. `SSHFilesView.swift:136–200` | A `Table` with selection: double-click opens, a context menu offers Download and Delete…, a back/up control sits in the toolbar, and files drop in to upload. Remove the per-row "…". | L |
| M-38 | IxD, QA | Terminal subtitle after Stop Typing (*new, live*) | **False state for about 1–2 s.** Right after Stop Typing on a terminal nobody else has open, the subtitle reads **"Watching · Typing in another window"** (正在另一个窗口中输入), then settles to "Watching". This happened in all three passes. Most likely the window's own earlier control attachment is still listed while the switch re-attaches. A momentary false "someone else is typing" undermines the state the subtitle exists to show; VoiceOver may read it if focus lands there. | Visibility of status (honest) | `live/en-light/10-main-watching.png` and `live/zh-light/10-main-watching.png` (wrong), against `live/zh-light/11-hover-toolbar-start-typing.png` 2.5 s later (correct); `LocalTerminalWorkspace.swift:135–156`; `LocalTerminalModel` `elsewhere(here:)` | Exclude this window's own attachment IDs, old and new, from `elsewhere`, or hold the subtitle until the switch is acknowledged (as iOS does with "Switching to Watching…"). Add an assertion to `LocalSessionFlowTests`. | S |

### P2

| ID | Role | Surface | Issue | HIG / heuristic | Evidence | Proposed fix | Effort |
|---|---|---|---|---|---|---|---|
| M-39 | UXW | zh-Hans step strip (*new, live*) | The last step, **Open** (a verb, "where it opens"), is translated **已打开**, "Opened", a past state, so the strip reads as if the terminal has already opened. | Wording consistency | `live/zh-light/20-continue-first-step.png` | 打开. Check the "Open" catalog key's context comment. | S |
| M-40 | UXW, IxD | New terminal names (*new, live*) | Default names are localized and numbered per language. In Chinese, ⌘N made **终端 1** beside the existing **Terminal 1**, so two terminals both read as "terminal 1". | Recognition; error prevention | `live/zh-light/00-rename-sheet-empty-error.png` (sidebar) | Number across all existing names regardless of language (the next free N for both "Terminal N" and "终端 N"). | S |
| M-41 | IxD | SSH host page after an explicit Disconnect (*new, live*) | Choosing **Disconnect** shows the dropped-connection state: "Disconnected", a 16-word reason ("Whether previous programs keep running depends on the remote host."), and **Reconnect**, as if something failed. | Match with the real world; minimal text | `live/en-light/50-ssh-host-page.png`, `52-…` | After a user Disconnect, show the plain host page with Connect; keep "Disconnected" and the reason for drops only. | S |
| M-10 | VD | All | **Ad-hoc spacing.** 14 spacing values and 39 padding combinations (§2). Sheet headers use 24/20/14 or 24/20/8 insets, footers 20/12 or 20/14, and the tour 36. There are 10 one-off paddings and 4 negative `-20` paddings that cancel Form insets. | Consistency; 4-pt grid | `inv-mac.txt` §padding, §spacing | Adopt `WitermSpacing` (§3) and replace literals. | M |
| M-11 | VD | All | **21 font styles**, including one-offs: `title3` on the SSH host page (`title2` everywhere else), `caption2` in the step strip, a 44 pt tour symbol, and `subheadline.monospaced` once. Essential information is set in `caption` (10 pt on the Mac): device-step details, the code's expiry, "Waiting for the other device…", and Invitations. | Typography: legible sizes; hierarchy | `inv-mac.txt` §font; `ContinueOnDeviceSheet.swift:505–521,1090` | Use the type ramp (§3): `callout` for secondary lines, and `caption` only for timestamps and metadata. | M |
| M-12 | VD | All | **12 corner radii** (6, 8, 9, 10, 12, 14, 16, 20, plus factors). `KeyChoiceCard` isn't `.continuous` while `ChoiceRow` is; `IssueBanner` is 16; `witermCard` is 20 on the Mac, which looks oversized next to macOS grouped-form sections. | Consistency | `inv-mac.txt` §cornerRadius | Four radius tokens (§3); Mac card 12. | S |
| M-13 | VD | Sheets | **14 distinct sheet sizes** (§2). The Open On ▸ sheet is a fixed 560 × 540 and is mostly empty on the code step, with about 40% blank below the content (`after-10-continue-sheet.png`), yet it clips on Approve (M-03). | Layout | `inv-mac.txt` §frame | Three sheet sizes (§3), with height fitting content up to a maximum. | S |
| M-14 | A11Y | Mixed secondary text | **Two secondary greys.** `.foregroundStyle(.secondary)` is used 21 times and `WitermTheme.secondary` 64 times. In light mode the system secondary on white is about 3.95:1, below 4.5:1 for 10–11 pt captions, such as snippet text and sidebar activity outside vibrancy. SecondaryInk is 6.4:1. | WCAG 1.4.3 | `contrast.py`; `SnippetSettings.swift:21`; `TerminalAppearanceSettings.swift:41`. *Not measurable live:* every pass rendered dark, where both greys pass (about 6:1). Priority unchanged until a light pass. | Rule: `.secondary` only inside native sidebar and list rows (vibrancy); `WitermTheme.secondary` elsewhere. Re-measure on light captures. | S |
| M-15 | A11Y | Welcome Tour | **Page dots are now buttons but fail non-text contrast:** the inactive dot is 1.69:1 (light) and 1.82:1 (dark), against 3:1 needed. `.focusEffectDisabled()` on the whole tour also removes focus rings from Skip, Next, and the dots for Full Keyboard Access users. | WCAG 1.4.11, 2.4.7 | `MacWelcomeTour.swift:96–97,160`; `live/zh-light/72-tour-page-2.png` (the inactive dots are barely visible) | Inactive dot at `secondary` 0.6 or higher (at least 3:1). Scope `.focusEffectDisabled()` to the container only. | S |
| M-16 | A11Y, VD | Open On ▸ device cards; SSH key cards | **Selection is shown four ways.** On a `ChoiceRow`, the selected fill (accent 6%) matches the hover fill (primary 8%), so a hovered card looks selected. It reports `accessibilityValue("Selected"/"Not Selected")`, while `KeyChoiceCard` uses the `.isSelected` trait. Selected borders are 1 pt at 55% on `ChoiceRow` and 2 pt at 100% on `KeyChoiceCard`. | Consistency; recognition | `ContinueOnDeviceSheet.swift:1094–1105`; `SSHProfileForm.swift:449–466`; `prior-en-dark/round9-mac-hover-continue-choice-row.png` | One `SelectableCard` component with a selected fill of accent 10% and a 1.5 pt accent border, hover at the `hoverFill` token (never on the selected card), and the `.isSelected` trait. | S |
| M-17 | UXW | Settings → Terminal vs. elsewhere | **Mixed capitalization.** Sentence case: "Font size", "Color scheme", "Increase terminal contrast", "Ring the terminal bell", "Announce output updates". Title case: "Allow Remote Access", "Type at the Same Time as This Mac", "Press Return After Inserting". | HIG writing: sentence case for checkbox, toggle and radio labels | `TerminalAppearanceSettings.swift:30–95`; `MacDevicesView.swift:113,340`; `SnippetSettings.swift:100` | Sentence case for every toggle, radio and checkbox label; title case for buttons and menu items. | S |
| M-18 | UXW | zh-Hans | **"Remote access" has two translations:** 远程连接 12 times, 远程访问 once. 连接 collides with Connect and Disconnect, which the vocabulary reserves for SSH. | Wording: one word per idea, both languages | `vocab.py` | 远程访问 everywhere; add a row to the README Wording table. | S |
| M-19 | UXW | Open On ▸, Settings | **"Server" stands alone where the vocabulary says relay server:** strip step **Server**, "Manage Servers…", "Remove Server?", "Unable to Remove Server". The sheet's server step is titled "Connect This Mac", so the strip and the title disagree. "Copy Invitation" (pairing) and "Copy Link" (someone else's device) are copies of the same kind of thing. | Wording table | `ContinueOnDeviceSheet.swift:271,292,511,708`; `MacDevicesView.swift:158,476,489` | Strip step **Relay**. Use "Relay Servers…", "Remove Relay Server?", and **Copy Invitation** in both places. | S |
| M-20 | IxD | Open On ▸ Approve | **Esc rejects the pending pairing.** Reject has `.cancelAction`, so the reflex "Esc to close" sends a rejection, and the other device must start again. | Error prevention | `ContinueOnDeviceSheet.swift:169–173` | Bind Esc to Cancel, which closes the sheet and rejects as it does today, but put **Reject** on a separate button with no shortcut. Or keep Esc but label the button "Reject and Close". | S |
| M-21 | IxD | SSH connected toolbar | **Disconnect has no confirmation and sits beside two harmless icons.** It ends the remote shell and its programs, which can't be undone. | Error prevention ("confirm only what can't be undone") | `SSHHostDetail.swift:27–35` | Confirm only when the activity shows a running foreground program ("Disconnect? *vim* on *host* stops."); otherwise disconnect at once. | S |
| M-22 | PS, UXW | SSH host menus | The Mac retitles Add to / Remove from Favorites, while iOS (Round 9) shows **Favorite ✓**. | Consistency across platforms | `MacWorkspaceView.swift:320`; `SSHHostDetail.swift:102` | `Toggle("Favorite")` in both Mac menus. | S |
| M-23 | VD | SSH host page | **The More menu floats about 600 pt away from Connect and Edit…** at the far right of a 640 pt column. The page repeats the window title as a `title3` heading and leaves about 75% of the pane empty. | Proximity; minimal design | `prior-en-dark/round9-mac-hover-ssh-host-more.png`; `live/en-light/50-ssh-host-page.png`; `SSHHostDetail.swift:49–98` | Put More beside Edit… in one action row; drop the in-page title (the window title already names the host); keep the address and the route. | S |
| M-24 | VD, UXW | Settings → Devices | The section header "Relay Server" repeats the row label "Relay Server". "Manage Servers…" sits alone in the section footer as a bordered button. | Minimal design | `prior-en-dark/round8-mac-after-14-settings-devices.png` | Header **Relay Server**, row label **Server** (or the picker with no label); move Manage Servers… into the picker as its last item ("Edit Relay Servers…"). | S |
| M-25 | VD | Settings tabs | The **Terminal** (`terminal`) and **Command Line** (`apple.terminal`) tab icons look almost identical. **Snippets** uses `text.badge.plus`, which reads as "add". | Icons: distinct silhouettes | `MacSettingsView.swift:24,29,37`; `prior-en-dark/round8-mac-after-13-settings-general.png` | Terminal → `textformat.size` (it holds text and colors); Command Line → `chevron.left.forwardslash.chevron.right`; Snippets → `text.insert`. | S |
| M-26 | UXW, VD | Symbols | The vocabulary says "pairing the link", but Pair a Device… and Pair a New Device use `plus`. Add SSH Host uses `network`, while host rows use `terminal`. Connect uses `play.fill`. | One icon per idea | symbol list in this audit (§2) | `link` for pairing, `server.rack` or `terminal` for SSH hosts consistently; Connect without a symbol, or `arrow.right.circle`. | S |
| M-27 | IxD | Open On ▸ sheet header | **Three headings above every step:** a caption eyebrow ("Open "*name*" on Another Device"), the step strip, the `title2` step title, and often a subtitle. That's about 15 words before any content. | Minimal text (standing requirement) | `ContinueOnDeviceSheet.swift:140–163` | Put the terminal name in the step title on the first step only and drop the eyebrow; the strip stays. | S |
| M-28 | A11Y | Reduce Motion *(code)* | The SSH form's More Options uses a bare `withAnimation` (expansion and chevron rotation) and ignores Reduce Motion. | HIG Motion | `SSHProfileForm.swift:93` | `WitermMotion.transition(reduceMotion:)`, or use a native `DisclosureGroup` (see M-29). | S |
| M-29 | PS | SSH form | **More Options is a custom disclosure row** (a plain button, a rotating chevron, and its own hover), not `DisclosureGroup`. | Prefer native controls | `SSHProfileForm.swift:91–110`; `prior-en-dark/round9-mac-hover-ssh-form-more-options.png` | `DisclosureGroup("More Options")` on the Mac. | S |
| M-30 | IxD | Copy feedback | "Copy Invitation" becomes "Invitation Copied" until the step changes, while Command Line's Copy reverts after 2 s and is announced. The sheet's copy isn't announced. | Consistency; feedback | `ContinueOnDeviceSheet.swift:511,708,742–746`; `CommandLineToolSettings.swift:221–233` | Reuse `CopyableCommand`'s timing and announcement. | S |

### P3

| ID | Role | Surface | Issue | Evidence | Proposed fix | Effort |
|---|---|---|---|---|---|---|
| M-31 | UXW | Toolbar tooltips | SFTP Files, Port Forwarding, and "Open on another device" tooltips repeat the label (Round 8 asked for "what happens"). | `SSHHostDetail.swift:28,31`; `LocalTerminalWorkspace.swift:112` | "Browse and transfer files on *host*", "Forward a port through *host*", "Open “*name*” on a paired device or a new one". | S |
| M-32 | VD | Settings window | Every tab is 640 × 600, so General is about 80% empty (`after-13-settings-general.png`). Apple's own settings windows fit each pane. | `MacSettingsView.swift:47` | Keep the width; let height fit content between 300 and 600 (an explicit choice in Round 7: revisit). | S |
| M-33 | A11Y | Increase Contrast *(code)* | Hover fills double, but borders (IssueBanner at 45% warning, ChoiceRow at 55% accent, dividers) don't strengthen. | `Components.swift:91`; `ContinueOnDeviceSheet.swift:1098` | At `.increased`, borders 100% and 1.5 pt. | S |
| M-34 | UXW | Long texts | OfflineBanner on the Mac (26 words), Manage Servers' subtitle (19), the Import intro (29), and the snippets footer (17) exceed the minimal-text bar. | `NetworkStatus.swift:41`; `MacDevicesView.swift:426`; `SSHConfigImportView.swift:63` | Cut to one clause each; move the rest into help. | S |
| M-35 | PS | Row context menu | macOS adds **Ask Siri** as the first item of the terminal row's context menu (the row exposes text), above Open. | `prior-en-dark/round9-mac-menu-terminal-open-on.png` | Investigate whether the row's text exposure can opt out of Siri suggestions; otherwise accept it. | S |
| M-36 | PS | Shortcuts | ⇧⌘P (Pause Remote Typing) is the system's Page Setup… shortcut, and ⇧⌘T is commonly "reopen" or "show tab bar". Neither conflicts in Witerm today (no printing, no tabs). | `WitermApp.swift:150,289` | Keep; note them in the Help shortcuts list if one is added. | — |
| M-37 | UXW | "SSH session" | "Disconnect another SSH session before opening a new one." and "The SSH session has ended." use *session*, which the vocabulary keeps out of the UI. | `strings.txt` (§2) | "…another SSH host…", "The SSH connection ended." | S |

## 2. Measured inventory (Mac build)

Counted by `inventory.py` over `apps/apple/Sources`, keeping only lines the Mac compiles. The debug-only accessibility harness is noted where it appears. Raw output: `.build/screenshots/audit-mac/tools/inv-mac.txt`.

**Fonts (21 distinct, 139 uses).** `caption` 37, `subheadline` 28, `headline` 11, `caption.monospaced` 9, `body.monospaced` 7, `subheadline.semibold` 6, `body` 5, `footnote` 5, `callout` 4, `subheadline.medium` 4, `callout.monospaced` 4, `caption.monospaced` (system form) 4, `title2.semibold` 4, `caption.medium` 3, `title3.monospaced` 2. One-offs: `caption2.semibold` (step strip), `subheadline.monospaced` (SSH page address), `system(size: 44)` (tour symbol), `system(size: fontSize, .monospaced)` (font preview), `system(size: size × 0.47)` (IconTile), `title3.semibold` (SSH page title). `fontWeight(.semibold)` 4.

**Spacing (14 distinct, 115 uses).** 12 ×21, 0 ×18, 10 ×14, 4 ×13, 2 ×12, 8 ×12, 6 ×10, 16 ×4, 14 ×3, 18 ×2, 3 ×2, 5 ×2. One-offs: **1** (sidebar row), **20** (overview actions). Off the 4-pt grid: 1, 3, 5, 6, 10, 14, 18 (66 uses).

**Padding (39 distinct, 91 uses).**
- Most used: horizontal 24 ×6, horizontal 20 ×5, vertical 4 ×5, bare ×4, horizontal **−20** ×4, horizontal 12 ×4, vertical 10 ×4, vertical 12 ×4, all 12 ×4, horizontal 14 ×3, horizontal 16 ×3, horizontal 8 ×3, top 20 ×3, top 4 ×3, all 10 ×3.
- Used twice: horizontal 6, vertical 3, vertical 6, vertical 8, vertical 9, `pagePadding`.
- One-offs: bottom 12, bottom 14, bottom 16, bottom 8, horizontal 36, horizontal 4, horizontal 7, leading 20, top 2, vertical 14, vertical 2, all 16, `readableContent(padding: 32)`.

**Corner radii (12 distinct, 35 uses).** 12 ×7, 6 ×6, 10 ×4, 16 ×3, 14 ×2, 8 ×2, `cardRadius` (20) ×2, brand tile `size × 0.27`, IconTile `size × 0.3`, one-off **9** (tour dot hover). Continuous vs. plain is mixed: `KeyChoiceCard` and `LocalDependencyView` aren't continuous.

**Colors (201 uses).** `WitermTheme.secondary` 64, `warning` 24, `.foregroundStyle(.secondary)` **21** (the second grey), `positive` 16, `accent` 15, `ink` 15, `surface` 9, `statusFill` 8, `divider` 6, `canvas` 5, `actionLabel` 3, `Color.clear` 3, `Color.primary` 2, `Color.accentColor` 1 (sidebar selection). Contrast (`contrast.py`):
- Ink on Canvas: 17.2 light, 16.4 dark.
- SecondaryInk: 5.9 and 6.3.
- Positive on Canvas: 4.6 light (4.1 on a light sidebar, an estimate).
- Warning: 5.4 light.
- System `.secondary` on white: about 3.95.

**Opacities (10 distinct).**
- Fills: 0.12 ×4 (tint fills), 0.06 ×2 (`statusFill`, the `ChoiceRow` selected fill).
- Strokes: 0.45 ×2 (banner border, inactive dot), 0.55 ×2 (ChoiceRow border, header hue edge).
- One-offs: 0.09 (canvas glow), 0.10 (TerminalHeader wash), 0.14 (brand stroke), 0.18 (brand shadow), 0.25 (undo-bar stroke), 0.35 (tour dot).
- Hover: `witermHover` 0.08, or 0.16 with Increase Contrast; `witermRowHover` 0.06 or 0.12.

**Symbols.**
- Sizes: `imageScale(.small)` ×1 (StatusBadge), IconTile 32 pt with a 15 pt glyph, route stops 28 pt, tour 44 pt, sidebar default.
- Most used: `plus` 9, `terminal` 8, `exclamationmark.circle` 7, `eye` 5, `server.rack` 4, `laptopcomputer.and.iphone` 4, `keyboard` 4, `folder` 4, `ellipsis.circle` 4, `checkmark.circle.fill` 4.
- Weights: all default (regular).

**Controls.**
- `controlSize`: `.large` ×4 (sheet footers: Open On ▸, device Edit, Manage Servers, tour), `.small` ×5 (spinners).
- Button styles: `.borderedProminent` 9, `.bordered` 8, `.plain` 7 (custom hover), `.borderless` 3, `.glassProminent` 2, `.link` 2, `.glass` 1.
- `witermControl()` gives regular capsules on the Mac.
- Hover modifiers: 17 uses across 10 variants (radii 6, 8, 9, 12; row hover; link pointer ×3).
- Tooltips: 39 `.help`.

**Window and sheet sizes.**

| Surface | Size (pt) |
|---|---|
| Main window | min 860 × 560, default 1180 × 760; sidebar 220 / 250 / 320 |
| Settings (all tabs) | 640 × 600 fixed |
| Open On ▸ sheet | 560 × 540 fixed |
| Device Edit | 480 × 520 fixed |
| Manage Servers | 560 × 420 fixed |
| Welcome Tour | 440 × 320 fixed |
| Rename | width 360 |
| SSH form | min 440, ideal 520, min height 640 |
| SSH trust | 440 / 520 × 440 |
| Import SSH Hosts | 440 / 520 × 420 |
| Port Forwarding | 440 / 520 × 580 |
| Host Keys | 440 / 560 × 420 |
| SFTP Files | 540 / 680 × 540 |
| Snippet editor | 420 / 480 × 360 |
| Terminal Display | 400 / 440 × 400 |
| Relay server address | min 520 × 340 |

That's **14 distinct sheet sizes**. Other fixed sizes: QR 168 (192 with its tile), step dots 16, `TerminalHeader` min 44 (iOS).

**Flagged one-offs to remove:** spacing 1 and 20; paddings 36, 7, 4, 2 and −20; radius 9; opacities 0.09, 0.10, 0.25 and 0.35; `title3` and `caption2`; the 44 pt symbol; `.large` control size (4 uses, all sheet footers).

**`WitermMetrics` is barely used:** `cardRadius` 2, `cardPadding` 1 (default), `pagePadding` 2, `readableWidth` 1, `iconTile` 1. Most layout uses literals.

## 3. Proposed tokens and component rules (Mac)

**Shared** marks what belongs in `apps/apple/Sources/Design/` for iOS too. Platform values differ where noted; the *names* are shared.

| Token | Mac value | iOS value | Shared? | Replaces |
|---|---|---|---|---|
| `WitermSpacing.xxs / xs / s / m / l / xl / xxl` | 2 / 4 / 8 / 12 / 16 / 20 / 24 | same | **Shared** (`WitermMetrics`) | 1, 3, 5, 6, 9, 10, 14, 18, 36 |
| `sheetInset` (header, content, footer horizontal) | 20 | 20 | **Shared** | 24 / 20 mix |
| `sheetFooterVertical` | 12 | — (toolbar) | Mac | 12 / 14 |
| `Radius.control` | 6 (= sidebar selection, hover) | 10 | **Shared name** | 6, 8, 9 |
| `Radius.inline` (code chips, inline fills) | 8 | 10 | **Shared name** | 8, 10, 14 |
| `Radius.card` (cards, banners, choice cards) | 12 | 20 | **Shared name**; `cardRadius` per platform | 12, 16, 20 |
| `Radius.tile` | `iconTile × 0.3` | same | **Shared** | — |
| `Fill.hover` | primary 0.06 (0.12 with Increase Contrast), rows and custom controls alike | — | Mac (in `Components`) | 0.06 / 0.08 split |
| `Fill.selected` | accent 0.10 + 1.5 pt accent border | same | **Shared** | 0.06 + 55% / 2 pt |
| `Fill.tint` (hue tiles, badges) | hue 0.12 | same | **Shared** (exists) | — |
| `Fill.status` | primary 0.06 | same | **Shared** (exists) | — |
| `Stroke.hairline` | 1 pt divider (1.5 pt with Increase Contrast) | same | **Shared** | — |
| Sheet sizes | `.compact` 400 wide; `.form` 520 × fit (max 640); `.flow` 600 × fit (min 420, max 640) | detents | Mac | 14 sizes |
| List row (custom) | min height 28 single-line, 40 two-line; inset 8 × 4; icon 16 pt | List default | Mac | — |
| Settings | 640 wide; height fits the pane (300–600) | n/a | Mac | 640 × 600 |

**Type ramp** (text styles only, so the system Text Size setting can scale them):
- `title2.semibold`: sheet and page titles, one per view.
- `headline`: section and card titles, device names.
- `body`: content and controls.
- `callout`: secondary lines, notes, status (replaces most `caption` and `subheadline`).
- `caption`: metadata only (timestamps, counts).
- Monospaced: `body` for commands, `title3` for a code to compare, `caption` for sidebar activity.
- Drop `title3` as a title, `caption2`, `subheadline.medium`, and fixed point sizes outside `IconTile` and the tour.

**Shared** as a `WitermType` namespace, so iOS keeps its own Dynamic Type sizes with the same names.

**Component rules.**
- **`SheetScaffold`** (*new; shared shape, Mac footer*). Optional eyebrow, a `title2` header, a scrolling content area, a `Divider`, and a footer. In the footer: destructive and secondary actions leading; Cancel (`.cancelAction`) and the primary (`.defaultAction` unless it's a trust decision) trailing; all `.regular` with the system bezel. iOS uses toolbar placements with the same roles. It replaces the five patterns in M-05.
- **`PrimaryButton`** (*shared*). One per view; the ink tint stays here only. Inside a sheet footer on the Mac, use the standard `.borderedProminent` (not glass) so footers match system alerts.
- **System controls** (Mac). No app tint. Switches, checkboxes, radios and links use the system accent (M-06); the sidebar already does.
- **`SelectableCard`** (*new; shared*). It merges `ChoiceRow` and `KeyChoiceCard` with `Fill.selected`, `Fill.hover` (never on the selected card), `Radius.card`, and the `.isSelected` trait.
- **Hover** (Mac). One `Fill.hover` value for rows and custom controls, in the element's own radius token; the pointing hand only on links. Native bordered and toolbar buttons keep system behavior (§5b).
- **Forms in sheets.** Never a fixed height or `scrollDisabled`; the sheet's single scroll view is the Form.
- **Secondary text.** `.secondary` inside native List and sidebar rows; `WitermTheme.secondary` elsewhere (M-14).

## 4. Task walkthroughs (before any change)

Counted from code paths and the Round 8–9 captures (English). Clicks include right-clicks; keys count shortcuts and Return or Esc, not typed text. Reading load counts words shown before the next action.

| Task | Fastest path | Clicks | Keys | Reading | Friction |
|---|---|---|---|---|---|
| **First launch** (service on) | The tour: Next ×3, then Get Started → a new terminal with focus | 4 (or 0) | 0 (or Return ×4) | ~45 words over 4 pages | Skip or Esc lands on "No Terminals Yet" (one more click). With the service off, page 2 adds Turn On, plus a System Settings approval outside the app. |
| **New terminal** | ⌘N | 0 | 1 | 0 | Measured: 1.7–1.8 s from ⌘N to the terminal on screen, in 6 of 6 runs, with XCTest polling included. Otherwise no friction. Naming is deferred to ⇧⌘R. The toolbar + hides Add SSH Host… behind a press-and-hold or chevron. |
| **Open a saved SSH host** | Click the row, then Connect, or arrow and Return | 2 (or 1 + Return) | 0–1 | 4 words (title, address) | A click selects without connecting, unlike a terminal row, which opens on click. |
| **First SSH host** | ⇧⌘N, address, password, Return → trust sheet → **Trust and Connect** | 1 + Tab/clicks | 2 | ~30 words in the trust sheet | No Return or Esc on the trust sheet (M-04). Measured: Connect to the trust sheet in 1.94 s (local fixture). Clicking Connect on an empty form shows both field errors at once (`live/*/41-…`), which is good. |
| **Pair a phone via Open On ▸** | Right-click the row → Open On ▸ New Device… → (phone scans) → compare the code → **Approve** → **Done** | 4 | 0 (Approve has no Return, by design) | ~60 words (header 15, code step 20, approve 25) | "Code" ambiguity (M-01); the eyebrow, strip and title triple (M-27); a fixed-height reach list may clip (M-03). With remote access off, add Turn On Remote Access (+1 click). ⌥⌘P → Choose a Device… adds a choice and Show Code (+2). |
| **Change a device's access** | ⌘, → Devices → **Edit…** → radio or toggle (saved at once) → Done | 4 | 1 | ~35 words | Only reachable from Settings; there's no "Edit access" from Open On ▸ *device*. Saving gives no visible confirmation. The Edit sheet may clip (M-03). |
| **Unpair** | ⌘, → Devices → Edit… → **Unpair…** → Unpair (alert) | 4 | 1 | ~20 words | Fine. Destructive actions sit leading in the footer, as proposed in §3. |
| **Recover: service off** | The main pane shows "Terminals Are Off" → **Turn On Terminals**; the footer says "Remote access on · Terminals off" | 1 (+2–3 in System Settings if approval is needed) | 0 | 4 words | Good. The pane says what's needed. |
| **Recover: relay offline** | Footer "Connecting…" (no reason) → click → Devices → **Check Now** → read the badge → Manage Servers… or wait | 3 | 0 | ~25 words | No reason or time is shown while connecting (M-07). VoiceOver and keyboard users land on the wrong tab (M-02). OfflineBanner only shows on SSH pages. |

## 5. Follow-ups

### 5a. Re-pair left an older pairing active (read-only analysis; no pairing was revoked)

- **Server rule.** `device_grants_active_idx` is a unique index on `(host_device_id, client_device_id) WHERE revoked_at IS NULL` (`server/internal/store/migrations/0001_identity.sql:26`). Approve inserts and maps `23505` to `conflict` (`server/internal/pairing/database.go:303–311`). Two active grants between the *same two identities* are impossible.
- **Mac.** `DevicePairingModel.approve` revokes `existingGrantForRequest` first, which matches by the requester's **identity ID** in this Mac's current grants (`DevicePairingModel.swift:163–179`). If the list is stale and a grant exists, the server answers `conflict`, which shows as "Pairing Status Changed · Refresh and try again", not as a duplicate. Revoking and then approving isn't atomic either: if approve fails after the revoke, the device is left unpaired.
- **So a phone holding two grants with "the same Mac" means one of two things:**
  1. **Two Mac identities with one name.** Identities are per normalized server address and per Keychain item, so a differently signed build (a worktree or test build), another Keychain access group, or another spelling of the relay address registers a new Mac device. The old identity's grant stays active. Neither the Mac's `existingGrantForRequest` nor iOS's `pairings(endedBy:)` (which matches `host.id`) can see it.
  2. **A stale list on iOS.** `RemoteTerminalModel.select` appends a just-approved grant without dropping the one the Mac revoked during re-pairing (`RemoteTerminalModel.swift:224`). `8c4f0f3` covers this case for Unpair, but the list still shows two rows until the next listing.
- **Recommendation (M-08).** Detect same-name, same-platform grants on Approve and offer to replace them. Show "Paired *date*" when names collide. On iOS, refresh grants after approval instead of appending. Lead decision: should the server optionally revoke older grants from a client with the same name and platform? That's a protocol change, so it's out of scope here.

### 5b. Buttons that are still natively hover-less

Bordered and prominent push buttons on macOS 27 highlight on press, not on hover. Round 9 found this, and the live hover pairs confirm it: `live/*/12-main-still-running` vs. `13-hover-primary-open` and `14-hover-bordered-watch`; `50-ssh-host-page` vs. `51-…-connect-primary` and `52-…-edit-bordered`; `20-continue-first-step` vs. `22-hover-continue-cancel`. These show no visible change by eye; no pixel diff was possible without an imaging library. Only the custom elements change: `02-hover-sidebar-row` and `53-hover-ssh-more`. In Mac code:
- **Main window:** New Terminal and Add SSH Host… (overview); Open (glass) and Watch (Still Running); Check Again (tmux); Turn On Terminals, Open System Settings, and Try Again (service setup); Install the witerm Command…; Connect (glass, hue) and Edit… (SSH page).
- **SSH surfaces:** Check Connection…, Try Again, and Dismiss Message (SSH banner); Undo and Dismiss ×; Trust and Connect, with a plain Cancel.
- **Open On ▸ sheet:** Back, Cancel, Continue, Show Code, Approve, Reject, Done, Copy Invitation and Copy Link, Show New Code, Start Over, and Try Again.
- **Settings:** Turn Off… and Turn On Terminals; Check Now, Cancel Check, Manage Servers…, Edit… per device, and End Invitation; Install, Uninstall, Use This Copy, and every Copy; Add Snippet; Restore Display Defaults.
- **Other sheets:** Unpair…, Done, Add Relay Server…, Edit… and Remove… (servers).
- **SSH sheets:** Add Jump Host, Remove This Jump Host, Copy Public Key, Hide Private Key; Start Forwarding and Stop Forwarding; Go and **Parent Folder** (a plain list button with no hover, unlike the file rows beside it); Remove Host Trust.
- **Tour:** Skip and Next.

Plain or borderless buttons **without** `witermHover` that should get it: SFTP **Parent Folder**, the SFTP row "…" menu, Undo bar **Dismiss ×** (borderless), and the IssueBanner action buttons (system default: fine).

Recommendation: leave native push buttons as they are (system behavior) and add hover only to the four plain or borderless ones.

### 5c. zh-Hans truncation and overflow (to verify before and after)

The live zh-Hans pass (`live/zh-light/`, dark appearance, default window 1180 × 760 with about a 260 pt sidebar) shows **no truncation or overflow** on any captured screen. `vocab.py` finds no missing zh-Hans strings (834 keys). Use this as the before list; re-run the same pass after changes.

| Where | Constraint | Observed (zh) | Result |
|---|---|---|---|
| Sidebar footer | `lineLimit(1)` | 远程连接已开启 · 在线, about 120 pt of about 176 pt (`01-…`) | Fits. The "正在连接…" variant (about 155 pt) also fits. **English** "Remote access on · Connecting…" (about 179 pt) is borderline and was not captured. |
| Sidebar rows, section headers | sidebar | 这台 Mac, SSH 主机, 添加 SSH 主机… | Fit. M-40: 终端 1 next to Terminal 1. |
| Toolbar title and subtitle | window toolbar | 仅观看 · 正在另一个窗口中输入 (`10-…`) | Fits. The content is wrong for about 1–2 s (M-38). |
| Context menu, Open On ▸, Sharing ▸, toolbar More | native menus | 停止输入 / 离开 / 打开于 / 共享 / 重命名… / 结束终端… (`06–09`) | Fit. The system adds "Ask Siri" in English (M-35). |
| Menu bar | File, Edit, View, Terminal, Help (`25–29`) | — | Fit. |
| Open On ▸ code step | 560 × 540 | 用另一台设备扫描, step strip 服务器 — 设备 — 批准 — 已打开 (`20-…`) | Fits. M-39: 已打开. M-01: 验证码 beside the QR. |
| Rename sheet | width 360 | 名称需为 1–64 个字符，且不能包含控制字符。 (`00-…`) | Fits on one line. |
| Settings tabs and panes | 640 × 600 | 通用 / 终端 / 片段 / 设备 / 命令行; Terminal, Snippets, Devices, Command Line panes (`30–39`) | Fit. Terminal's footer continues below the fold and scrolls, as intended. |
| SSH form | min 440 × 640 | 添加 SSH 主机, field errors 请输入地址… / 请输入密码或载入私钥。, 将认证信息保存在本机 (`40–42`) | Fit. Two footers (M-05). |
| SSH host page, More, Host Keys, Undo bar | — | `50–57` | Fit. |
| Welcome Tour | 440 × 320 | 在后台运行 / Witerm 会在后台保持你的终端运行。 (`71–74`) | Fit. |
| **Not reached live** | device step, Approve, device Edit sheet, invite steps, server step | Nothing is paired on the relay server | Still an estimate. The reach picker (fixed `120 + 26 × n`) clips its last two-line row (M-03); the rest should fit at the default text size. |

### 5d. Light and dark appearance

- **Dark** is verified live in English and Chinese (all 146 attachments). The issues found:
  - M-06: the On state of the Allow Remote Access switch reads as a grey track, while Terminal's switches are green.
  - M-13 and M-04: empty space in fixed-size sheets.
  - Inactive tour dots are barely visible (M-15).
  - Hue accents (Connect and Reconnect pills, the 2 pt edge on SSH terminals) are clear.
- **Light** wasn't captured. `-AppleInterfaceStyle Light` as a launch argument doesn't override a Dark system appearance on macOS 27, so the pass named `en-light` is dark. A light pass needs the system appearance switched to Light for the run (a system setting, so the user's or the lead's call), or a DEBUG-only appearance launch argument; AGENTS.md rules out an in-app override in the product. From tokens:
  - Every token pair is at least 4.5:1, except Positive on a light sidebar (about 4.1:1, only for icons, so fine as non-text).
  - The hover fill is 1.14:1 (rows) or 1.19:1 (custom) against Surface. That's subtle but conventional; with Increase Contrast it's 1.32:1 or 1.45:1.
  - The system `.secondary` on white for captions is about 3.95:1 (M-14).
- **Owed:** a light pass of the same screens. Larger text and Increase Contrast stay code-reviewed (M-03, M-33), because both are system settings this audit doesn't change.

## Re-running the captures

`apps/apple/MacVoiceOverUITests/AuditScreenshotTests.swift` (opt-in; added in this phase; passed on 2026-11-03 in 705 s):

- **What it covers.** It walks the main window (typing, watching, Still Running), context and toolbar menus, the Open On ▸ sheet's entries, all Settings tabs and their sheets, the SSH form, host page, trust sheet, connected toolbar, SFTP, Forwarding, Host Keys and Undo bar, the menu bar, and the tour.
- **Passes.** It runs English light, English dark, and zh-Hans light, attaching cropped images, three accessibility-tree dumps, and timing metrics. The "light" passes follow the system appearance (see §5d), so switch the system to Light for a real light pass.
- **Afterwards.** Teardown quits Witerm. Reopen the installed app once afterwards, and keep one instance.
- **Safety.** It creates and ends only "Audit A" and "Audit B", and one SSH host, never presses Return in the Open On ▸ sheet, and never toggles remote access or the service.
- **Run it.** With UI automation authorized:

```sh
zsh .build/screenshots/audit-mac/tools/fixture.sh up        # prints PORT and FINGERPRINT
TEST_RUNNER_WITERM_HCI_FIXED_APP=$PWD/.build/Applications/Witerm.app TEST_RUNNER_WITERM_AUDIT_SHOTS=1 \
TEST_RUNNER_WITERM_AUDIT_SSH_PORT=<PORT> TEST_RUNNER_WITERM_AUDIT_SSH_FINGERPRINT=<FINGERPRINT> \
xcodebuild test-without-building -xctestrun <derived>/Build/Products/WitermMacVoiceOverUITests_*.xctestrun \
  -destination 'platform=macOS' -only-testing:WitermMacVoiceOverUITests/AuditScreenshotTests -resultBundlePath audit.xcresult
xcrun xcresulttool export attachments --path audit.xcresult --output-path .build/screenshots/audit-mac/live
zsh .build/screenshots/audit-mac/tools/fixture.sh down
```
