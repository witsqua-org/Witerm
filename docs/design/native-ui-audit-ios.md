# Native UI Audit (iOS, Round 18)

The owner, on 2026-11-04: "The 'Device is offline' box is not using native system UI. Replace it with a native system-style component", then "inspect the rest of the app for similar non-native UI components and replace them with native system-style equivalents wherever appropriate." The box was the paired terminal's connection card: a custom rounded rectangle of material drawn over the terminal, titled **Device Is Offline**.

**Rule from this round** (also in the [Design Guidelines](README.md#design-system)): prefer the system's component; a custom one needs a stated reason, which this page records.

**Method.** Every iOS screen and shared component was read for custom-drawn surfaces: `.background(…, in: shape)` with our own fills, `witermOutline`, `witermCard`, capsules, and hand-built status, empty and error states. Screens were captured on the iPhone 18 Pro simulator through the DEBUG fixture (`NativeUIScreenshotTests`, English, dark, the system's appearance), before and after: `.build/screenshots/round18-ios/native-before/` and `native-after/` (not committed). SSH-only screens (the host-key card, a live host's card) were checked in code and through `SSHTypingChromeTests`, not captured separately. Dynamic Type, VoiceOver, Increase Contrast and light/dark come with the system components; the identifiers tests use didn't change.

## Replaced

| Component | Where | Before | Now | Shots |
|---|---|---|---|---|
| Terminal connection card ("Device Is Offline", Disconnected, Terminal Ended, Opening…) | Paired terminal (`RemoteTerminalWorkspace.connectionOverlay`) | A custom rounded card of material (or `surface` with Reduce Transparency) at the top of the terminal, a bold title, gray text, a glass button | **`ContentUnavailableView`** over the system's `.regularMaterial`: a symbol (`wifi.slash` when the device is offline), the title, the recovery as its description, **Reconnect** or **Back to Terminals** as its action (`PrimaryButton`: system glass, bordered with Reduce Transparency). While connecting, the system **`ProgressView`** with its label and a **bordered** Cancel. The material follows Reduce Transparency and Increase Contrast itself | `native-07-terminal-device-offline` |
| `IssueBanner` (No Longer Paired, a relay server's problem, a terminal that didn't open, No Network Connection, the SSH background tip, an SSH issue) | Terminals, Devices, the terminal screens | A custom card: `surface` fill, 12 pt corners, a 1 pt orange border | The system **`GroupBox`** with a **`Label`** title (the symbol keeps the warning color), the message in secondary text, actions below. On Mac unchanged | `native-01`, `native-08` |
| `StatusBadge` (Online, Offline, Checking…, Connected) | Device section headers, terminal rows, SSH host cards | A tinted capsule with an outline | A plain **`Label`** (`.titleAndIcon`) in the status color: symbol and text, so color is never the only signal. On Mac unchanged | `native-02` |
| Offline device's row | Terminals, a device's section | Gray text alone in a row | A **`Label`** with the offline symbol, in secondary text, in the list's own row | `native-03` |
| A live terminal's last line | SSH host cards in Terminals | Monospaced text in its own filled, outlined box inside the row | Monospaced secondary text in the row | — |
| Camera unavailable / Camera Access Needed | Add Device | A custom card (`witermCard`) with an icon tile | **`ContentUnavailableView`** with the camera symbol, the reason, and its actions | — |
| Invitation field | Add Device ▸ Type Invitation… | A `TextField` in a drawn box with an outline | The system's **`.roundedBorder`** field | — |
| This device's code | Add Device, the pairing code step | Monospaced code in a drawn box | In a **`GroupBox`** | — |
| Host fingerprint card | SSH first connection (trust sheet) | `witermCard` | **`GroupBox`** on iOS (`witermGroupBox()`); Mac keeps its card | — |
| Welcome Tour symbols | Settings ▸ Help ▸ Welcome Tour | A large symbol in a drawn 112 pt tile with an outline | The symbol alone in the tint, as on the system's What's New pages | — |
| Notices over a terminal (Typing on *device*, a kept terminal disconnected at the limit) | Paired terminal | A row on Witerm's `surface` color | The same row on the system **`.bar`** material | `r18-limit-1-note` |
| Terminal rows' Disconnect | Terminals | — (new) | System **swipe actions** and **context menu** | `r18-disconnect-*` |

## Kept custom, with the reason

| Component | Reason |
|---|---|
| The terminal surface (SwiftTerm), its selection handles, reading view | It's the content: no system view renders a terminal. |
| `FloatingTerminalButton` (keyboard button, Jump to Latest, Hide Keyboard) | Already the system's `UIButton.Configuration.glass()` (gray with Reduce Transparency), only placed by us. |
| Key row (`MobileTerminalAccessory`) | An input accessory with terminal keys (Esc, Ctrl, arrows): there's no system equivalent; its keys use `tertiarySystemFill`, as the system keyboard's do. |
| `IconTile` | The tinted rounded symbol tiles of Settings-style rows; the tint is the machine's identity hue, which is how Witerm tells machines apart. |
| `PrimaryButton` | A wrapper around the system's `.glassProminent` (`.borderedProminent` with Reduce Transparency), with the label color that keeps contrast on the accent. |
| `TerminalActivityCard`'s hue edge | The 4 pt identity hue marks which machine a live terminal is on; the rest of the card is now system text and labels. |
| `TerminalHeader` (iPad) | A thin header above the terminal in the split view's detail; the navigation bar can't carry the status line and the machine's hue there. |
| The SSH Undo bar | A transient, floating Undo after Delete Host, like Mail's; iOS has no system toast. Its capsule uses `surface` with a hairline. Candidate if a system component appears. |
| SSH address chips (`SSHProfileForm`) | Token-like chips parsed from the address (user, host, port); the system has no token view for SwiftUI on iOS. |
| Welcome Tour key caps | Pictures of keys, not controls. |
| Text and Colors preview | A preview of the terminal's own colors; it must draw them. |
| QR code tile | A scannable code needs a white quiet zone in every appearance. |
| Find bar | Built from a system `TextField` and buttons; its bar background is the terminal's chrome surface. |

## Mac candidates (report only; not changed this round)

| Component | Candidate |
|---|---|
| `IssueBanner`, `StatusBadge` capsule | `GroupBox` and a plain `Label`, as on iOS. |
| `witermCard` (SSH host page, trust sheet, pairing pages) | `GroupBox` or a `Form` section (`.formStyle(.grouped)`). |
| `ContinueOnDeviceSheet` code and status tiles (`statusFill` with outlines) | `GroupBox`; the code tile may stay custom for its size. |
| `LocalTerminalWorkspace` "Still Running" and status boxes | `ContentUnavailableView` with Open and Watch as its actions. |
| `SelectableCard` (Continue sheet choices) | A `Picker` with `.radioGroup` style, or a `List` with selection, if the cards' descriptions fit. |
| Snippet editor field (`textBackgroundColor` box) | `TextEditor` in a `Form` section. |
| SFTP browser's busy overlay (material rounded rect) | `ProgressView` in the toolbar, or `.overlay { ProgressView() }` without a drawn box. |
