import SwiftUI
#if os(macOS)
import AppKit
import SwiftTerm
#endif

@main
struct WitermApp: App {
    @State private var servers = ServerList()
    #if os(macOS)
    @State private var service = LocalAgentService()
    @State private var pairedDevices = MacPairedDevices()
    #endif

    var body: some Scene {
        mainWindow
        #if os(macOS)
        Settings {
            MacSettingsView(service: service)
                .environment(servers)
                .environment(pairedDevices)
                .environment(\.localAgent, service.client)
        }
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            #if DEBUG
                if TerminalAccessibilityHarness.requested {
                    TerminalAccessibilityHarnessView()
                } else {
                    workspace
                }
            #else
                workspace
            #endif
        }
        #if os(macOS)
            .defaultSize(width: 1180, height: 760)
            .windowResizability(.contentMinSize)
        #endif
            .commands { WitermCommands() }
    }

    private var workspace: some View {
        Group {
            #if os(macOS)
                MacWorkspaceView(service: service)
                    .environment(pairedDevices)
                    .environment(\.localAgent, service.client)
            #else
                MobileWorkspaceView()
            #endif
        }
        .connectionLifecycle()
        .environment(servers)
    }
}

#if os(macOS)
/// Sends a standard text-finder action up the responder chain, as AppKit's
/// own Find menu items do; SwiftTerm reads the action from the item's tag.
@MainActor enum TerminalFind {
    static func send(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }
}
#endif

#if os(macOS)
/// Sends a snippet up the responder chain to the focused terminal, or beeps
/// when no terminal has focus.
@MainActor enum TerminalSnippet {
    static func insert(_ snippet: CommandSnippet) {
        let item = NSMenuItem()
        item.representedObject = SnippetBox(snippet)
        if !NSApp.sendAction(#selector(TerminalView.witermInsertSnippet(_:)), to: nil, from: item) { NSSound.beep() }
    }
}

final class SnippetBox: NSObject {
    let snippet: CommandSnippet
    init(_ snippet: CommandSnippet) { self.snippet = snippet }
}

extension TerminalView {
    /// Input goes through the terminal's delegate like typing, so a view-only
    /// session drops it.
    @objc func witermInsertSnippet(_ sender: Any?) {
        guard let snippet = ((sender as? NSMenuItem)?.representedObject as? SnippetBox)?.snippet else { return }
        send(snippet.input(bracketedPaste: getTerminal().bracketedPasteMode))
    }
}
#endif

/// Where Open On ▸ sends the selected terminal (Mac): the sheet's device
/// step, a paired device, a new device, or someone else's.
enum OpenOnTarget: Equatable {
    case choose, device(String), newDevice, someoneElse
}

/// A paired device as Open On ▸ lists it.
struct OpenOnDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

#if os(macOS)
/// Open On ▸'s items, the same in File, Terminal, and a terminal's context
/// menu. Native menu items, so hover and the pointer are the system's.
struct OpenOnItems: View {
    let devices: [OpenOnDevice]
    /// ⌥⌘P belongs to one place, File.
    var shortcut = false
    let open: (OpenOnTarget) -> Void

    var body: some View {
        Button(String(localized: "Choose a Device…", bundle: .main)) { open(.choose) }
            .keyboardShortcut(shortcut ? KeyboardShortcut("p", modifiers: [.command, .option]) : nil)
            .accessibilityIdentifier("continueOnDeviceMenu")
        if !devices.isEmpty { Divider() }
        ForEach(devices) { device in
            Button(device.name) { open(.device(device.id)) }
                .accessibilityIdentifier("openOnDevice-\(device.id)")
        }
        Divider()
        Button(String(localized: "New Device…", bundle: .main)) { open(.newDevice) }
            .accessibilityIdentifier("openOnNewDevice")
        Button(String(localized: "Someone Else…", bundle: .main)) { open(.someoneElse) }
            .accessibilityIdentifier("openOnSomeoneElse")
    }
}

/// Sharing ▸: who besides this Mac may reach a terminal, each switch with a
/// checkmark while on.
struct SharingMenu: View {
    let keepPrivate: Bool
    let remoteTypingPaused: Bool
    let shared: Bool
    let toggleKeepPrivate: () -> Void
    let toggleRemoteTyping: () -> Void
    let stopSharing: (() -> Void)?
    var remoteTypingShortcut = false

    var body: some View {
        Menu(String(localized: "Sharing", bundle: .main)) {
            Toggle(String(localized: "Keep Private", bundle: .main), isOn: Binding(get: { keepPrivate }, set: { _ in toggleKeepPrivate() }))
                .help(String(localized: "No paired device can open it", bundle: .main))
                .accessibilityIdentifier("keepSessionPrivate")
            Toggle(String(localized: "Pause Remote Typing", bundle: .main), isOn: Binding(get: { remoteTypingPaused }, set: { _ in toggleRemoteTyping() }))
                .keyboardShortcut(remoteTypingShortcut ? KeyboardShortcut("p", modifiers: [.command, .shift]) : nil)
                .disabled(keepPrivate)
                .help(String(localized: "Paired devices can watch but not type", bundle: .main))
                .accessibilityIdentifier("pauseRemoteTyping")
            if let stopSharing, shared {
                Divider()
                Button(String(localized: "Stop Sharing", bundle: .main), action: stopSharing)
                    .accessibilityIdentifier("stopSharingLocalSession")
            }
        }
        .accessibilityIdentifier("sharingMenu")
    }
}
#endif

/// Actions the focused workspace window offers to the menu bar, and to the
/// iPad's hardware-keyboard shortcut list.
struct WorkspaceActions {
    var newSession: (() -> Void)?
    var newSSHConnection: () -> Void
    var importSSHHosts: (() -> Void)?
    /// Pairs a device when no terminal is selected (Mac).
    var continueOnDevice: (() -> Void)? = nil
    var continueTitle = ""
    /// Open On ▸ for the selected terminal (Mac); nil without one.
    var openOn: ((OpenOnTarget) -> Void)? = nil
    var openOnDevices: [OpenOnDevice] = []
    /// Sharing ▸ for the selected terminal (Mac).
    var keepPrivate = false
    var shared = false
    var toggleKeepPrivate: (() -> Void)? = nil
    var stopSharing: (() -> Void)? = nil
    var refresh: () -> Void
    /// Open terminals in sidebar order; the first nine get ⌘1–⌘9.
    var terminalNames: [String] = []
    var showTerminal: (Int) -> Void = { _ in }
    /// Moves by one open terminal (+1 or −1), wrapping around.
    var showAdjacentTerminal: (Int) -> Void = { _ in }
    /// The selected Mac session's own commands; nil without one (Mac only).
    var renameSession: (() -> Void)? = nil
    var endSession: (() -> Void)? = nil
    /// Pauses or allows typing from other devices in the selected session.
    var toggleRemoteTyping: (() -> Void)? = nil
    var remoteTypingPaused = false
    /// Whether this window types in the terminal it shows (Mac); nil when it
    /// shows none. `setTyping` switches between typing and watching.
    var typingHere: Bool? = nil
    var setTyping: ((Bool) -> Void)? = nil
    /// Stops showing the terminal here; it keeps running (Mac).
    var leave: (() -> Void)? = nil
    /// Closes the shown SSH connection (iOS; on the Mac it asks first while
    /// a program runs).
    var disconnect: (() -> Void)? = nil
    /// The selected SSH host's commands (Mac): Connect while it isn't
    /// connected; SFTP Files and Port Forwarding while it is.
    var connect: (() -> Void)? = nil
    var sshFiles: (() -> Void)? = nil
    var sshForwarding: (() -> Void)? = nil
    /// Shows the find bar in the shown terminal (iOS; the Mac routes Find itself).
    var find: (() -> Void)? = nil
    /// Moves to the next (+1) or previous (−1) match in the shown terminal (iOS).
    var findStep: ((Int) -> Void)? = nil
}

extension Notification.Name {
    /// Asks the terminal on screen to show its find bar.
    static let witermFindInTerminal = Notification.Name("witerm.findInTerminal")
    /// Asks the terminal on screen for its next (`object` 1) or previous (−1) match.
    static let witermFindStep = Notification.Name("witerm.findStep")
    /// Asks the SSH host page whose profile ID is `object` to disconnect,
    /// confirming first while a program runs (Mac).
    static let witermDisconnectSSH = Notification.Name("witerm.disconnectSSH")
}

extension FocusedValues {
    @Entry var workspaceActions: WorkspaceActions?
}

struct WitermCommands: Commands {
    @FocusedValue(\.workspaceActions) private var actions
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage(CommandSnippets.key) private var snippets = Data()

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            #if os(macOS)
            Button(String(localized: "New Terminal", bundle: .main)) { actions?.newSession?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.newSession == nil)
            #endif
            Button(String(localized: "Add SSH Host…", bundle: .main)) { actions?.newSSHConnection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button(String(localized: "Import SSH Hosts…", bundle: .main)) { actions?.importSSHHosts?() }
                .disabled(actions?.importSSHHosts == nil)
            #if os(macOS)
            Divider()
            if let openOn = actions?.openOn {
                Menu(String(localized: "Open On", bundle: .main)) {
                    OpenOnItems(devices: actions?.openOnDevices ?? [], shortcut: true, open: openOn)
                }
            } else {
                Button(actions?.continueTitle ?? String(localized: "Pair a Device…", bundle: .main)) { actions?.continueOnDevice?() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(actions?.continueOnDevice == nil)
            }
            #endif
        }
        CommandGroup(before: .toolbar) {
            Button(String(localized: "Refresh", bundle: .main)) { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button(String(localized: "Increase Text Size", bundle: .main)) { fontSize = TerminalFontSize.clamped(fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(fontSize >= TerminalFontSize.range.upperBound)
            Button(String(localized: "Decrease Text Size", bundle: .main)) { fontSize = TerminalFontSize.clamped(fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(fontSize <= TerminalFontSize.range.lowerBound)
            Button(String(localized: "Actual Text Size", bundle: .main)) { fontSize = TerminalFontSize.standard }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
        #if os(macOS)
        // Routed to the focused terminal, whose find bar overlays the text and
        // only scrolls this view; the session's grid is never resized.
        // Edit ▸ Find ▸, as in every Mac app.
        CommandGroup(replacing: .textEditing) {
            Menu(String(localized: "Find", bundle: .main)) {
                Button(String(localized: "Find…", bundle: .main)) { TerminalFind.send(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button(String(localized: "Find Next", bundle: .main)) { TerminalFind.send(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button(String(localized: "Find Previous", bundle: .main)) { TerminalFind.send(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button(String(localized: "Use Selection for Find", bundle: .main)) { TerminalFind.send(.setSearchString) }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
        #endif
        CommandMenu(String(localized: "Terminal", bundle: .main)) {
            let names = actions?.terminalNames ?? []
            Button(String(localized: "Show Next Terminal", bundle: .main)) { actions?.showAdjacentTerminal(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(names.count < 2)
            Button(String(localized: "Show Previous Terminal", bundle: .main)) { actions?.showAdjacentTerminal(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(names.count < 2)
            if !names.isEmpty { Divider() }
            ForEach(Array(names.prefix(9).enumerated()), id: \.offset) { index, name in
                Button(name) { actions?.showTerminal(index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            #if os(iOS)
            // The shown terminal's commands, listed while ⌘ is held.
            Divider()
            Button(String(localized: "Find in Terminal", bundle: .main)) { actions?.find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.find == nil)
            Button(String(localized: "Find Next", bundle: .main)) { actions?.findStep?(1) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions?.findStep == nil)
            Button(String(localized: "Find Previous", bundle: .main)) { actions?.findStep?(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.findStep == nil)
            Button(actions?.typingHere == false ? String(localized: "Start Typing", bundle: .main)
                   : String(localized: "Stop Typing", bundle: .main)) {
                if let typing = actions?.typingHere { actions?.setTyping?(!typing) }
            }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions?.setTyping == nil)
            Button(String(localized: "Leave", bundle: .main)) { actions?.leave?() }
                .disabled(actions?.leave == nil)
            Button(String(localized: "Disconnect", bundle: .main)) { actions?.disconnect?() }
                .disabled(actions?.disconnect == nil)
            #endif
            #if os(macOS)
            Divider()
            // The selected terminal's commands, so none needs the pointer.
            // Start or Stop Typing is titled by what it does next.
            Button(actions?.typingHere == false ? String(localized: "Start Typing", bundle: .main)
                   : String(localized: "Stop Typing", bundle: .main)) {
                if let typing = actions?.typingHere { actions?.setTyping?(!typing) }
            }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions?.setTyping == nil)
            Button(String(localized: "Leave", bundle: .main)) { actions?.leave?() }
                .disabled(actions?.leave == nil)
            // The selected SSH host's commands, the same as its toolbar.
            if let connect = actions?.connect {
                Divider()
                Button(String(localized: "Connect", bundle: .main), action: connect)
            } else if let disconnect = actions?.disconnect {
                Divider()
                Button(String(localized: "SFTP Files…", bundle: .main)) { actions?.sshFiles?() }
                Button(String(localized: "Port Forwarding…", bundle: .main)) { actions?.sshForwarding?() }
                Button(String(localized: "Disconnect", bundle: .main), action: disconnect)
            }
            Divider()
            if let openOn = actions?.openOn {
                Menu(String(localized: "Open On", bundle: .main)) {
                    OpenOnItems(devices: actions?.openOnDevices ?? [], open: openOn)
                }
            }
            Button(String(localized: "Rename Terminal…", bundle: .main)) { actions?.renameSession?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.renameSession == nil)
            // Checkmarks show which is on; ⇧⌘P works from inside the submenu.
            if let toggleRemoteTyping = actions?.toggleRemoteTyping, let toggleKeepPrivate = actions?.toggleKeepPrivate {
                SharingMenu(keepPrivate: actions?.keepPrivate == true, remoteTypingPaused: actions?.remoteTypingPaused == true,
                            shared: actions?.shared == true, toggleKeepPrivate: toggleKeepPrivate,
                            toggleRemoteTyping: toggleRemoteTyping, stopSharing: actions?.stopSharing,
                            remoteTypingShortcut: true)
            }
            Button(String(localized: "End Terminal…", bundle: .main)) { actions?.endSession?() }
                .disabled(actions?.endSession == nil)
            Divider()
            // Typed into the focused terminal; a view-only terminal ignores it.
            Menu(String(localized: "Insert Snippet", bundle: .main)) {
                let saved = CommandSnippets.decode(snippets)
                if saved.isEmpty {
                    Text(String(localized: "Add snippets in Settings → Snippets.", bundle: .main))
                }
                ForEach(Array(saved.enumerated()), id: \.element.id) { index, snippet in
                    if index < 9 {
                        Button(snippet.name) { TerminalSnippet.insert(snippet) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                    } else {
                        Button(snippet.name) { TerminalSnippet.insert(snippet) }
                    }
                }
            }
            #endif
        }
        #if os(macOS)
        CommandGroup(replacing: .help) {
            Button(String(localized: "Welcome Tour", bundle: .main)) {
                NotificationCenter.default.post(name: .witermShowWelcomeTour, object: nil)
            }
        }
        #endif
    }
}
