# HCI Improvements 1–7

Implemented and verified on 2026-10-27. The review used [Figma's introduction to human-computer interaction](https://www.figma.com/resource-library/human-computer-interaction/) to examine task choice, feedback, error prevention and recovery in Witerm's existing native interface.

## Delivered behavior

| # | Improvement | Result | Main implementation |
|---|---|---|---|
| 1 | Start with the user's task | First-use iOS offers SSH or continuing from a Mac. Independent SSH needs no server setup; existing configurations bypass the choice, and subsequent launches remember the last work tab. | [MobileWorkspaceView](../../apps/apple/Sources/Mobile/MobileWorkspaceView.swift) |
| 2 | Complete the Mac-to-iPhone preparation flow | One session sheet checks the selected server, pairing, live remote access and explicit session sharing, with control release when appropriate. iOS supports QR scanning and pasting through the same invitation and fingerprint review. | [SessionHandoffView](../../apps/apple/Sources/LocalTerminal/SessionHandoffView.swift), [PairingScannerView](../../apps/apple/Sources/Pairing/PairingScannerView.swift) |
| 3 | Identify the input destination and mode | Terminal headers name the destination and distinguish input enabled, view only, pending handoff and disconnected states. Machine color identifies the host; status also uses text and symbols. | [TerminalHeader](../../apps/apple/Sources/Design/Components.swift), [RemoteTerminalWorkspace](../../apps/apple/Sources/RemoteTerminal/RemoteTerminalWorkspace.swift) |
| 4 | Explain connection lifetime and recovery | iOS SSH explains background disconnection and retains the host and reason for explicit reconnect. Local Mac disconnection keeps the shell running; End Session moves into More and still requires confirmation. | [SSHWorkspaceModel](../../apps/apple/Sources/SSH/SSHWorkspaceModel.swift), [LocalTerminalWorkspace](../../apps/apple/Sources/LocalTerminal/LocalTerminalWorkspace.swift) |
| 5 | Separate saving from connecting | Edit uses Save. New hosts offer Save and Connect or Save Without Connecting. Names are optional, advanced fields use disclosures, and errors and cleared-credential feedback appear beside the relevant fields. | [SSHProfileForm](../../apps/apple/Sources/SSH/SSHProfileForm.swift) |
| 6 | Support common mobile terminal actions | A shared accessory provides Esc, one-key Ctrl, Tab, Ctrl+C, Paste and arrows with accessible labels, Dynamic Type and at least 44 pt targets. Multiline paste previews the full text and destination before sending and is invalidated on disconnect. | [MobileTerminalAccessory](../../apps/apple/Sources/RemoteTerminal/MobileTerminalAccessory.swift), [RemoteNativeTerminalView](../../apps/apple/Sources/RemoteTerminal/RemoteNativeTerminalView.swift) |
| 7 | Prioritize daily navigation | Hosts support search, favorites and recent-connection ordering. Regular-width iPad keeps hosts beside the terminal. Device rows emphasize name and permission, with the full fingerprint available in details. | [SSHWorkspaceView](../../apps/apple/Sources/SSH/SSHWorkspaceView.swift), [MacWorkspaceView](../../apps/apple/Sources/LocalTerminal/MacWorkspaceView.swift), [RemoteDevicesView](../../apps/apple/Sources/RemoteTerminal/RemoteDevicesView.swift) |

## Verification

- Normal signed macOS and iOS Simulator builds passed.
- Native terminal tests passed: 9 on Mac and 15 on iOS, including mobile control keys, accessibility state, read-only input rejection and paste invalidation.
- iPhone workflow, language and configuration cases passed; iPad configuration cases passed in landscape on an existing simulator.
- All three VoiceOver cases passed on each platform. Mac tests now initialize the XCTest VoiceOver driver before each harness launch, even when the system setting is already enabled, and handle backward entry into the native scroll container. Speech, navigation and no-write assertions remain intact.
- SSH package tests and all 7 isolated live OpenSSH cases passed. A real simulator SSH UI flow verified trust, typing, SFTP, background disconnect and explicit reconnect using the existing verified pin.
- The fixed signed development app was replaced as a whole bundle after stopping its service and confirming process exit. Signature checks and a new disposable-session probe verified that the same shell, state and child survived. Actual input through the new GUI reached the original shell; the test session was then cleaned up.

Detailed evidence and test limits are recorded in [Verification Status](../verification.md). Reproduction guidance for the VoiceOver driver is in [Terminal Experience](../terminal-experience.md#native-tests).

## Remaining evaluation scope

Physical-device camera scanning and permission recovery, a new end-to-end phone handoff, one-handed ergonomics, hardware keyboards, iPad multitasking and real-network/background behavior were not established by this simulator run. Existing relay acceptance is separate evidence. These limits do not imply additional permissions or capabilities in the interface.
