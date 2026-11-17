#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// A request to open a terminal on another device (Open On ▸), or to pair
/// one when `sessionID` is nil.
struct ContinueRequest: Identifiable {
    let id = UUID()
    let sessionID: String?
    var target = OpenOnTarget.choose
}

enum MacDestination: Hashable {
    /// Home (Round 27): the command bar, this Mac's terminals, SSH hosts and devices.
    case home
    /// Paired devices, invitations and remote access, in the window rather than Settings.
    case devices
    case local(String)
    case ssh(UUID)

    /// The stable ID Open Quickly remembers it by.
    var quickOpenID: String {
        switch self {
        case .home: "place:home"
        case .devices: "place:devices"
        case .local(let id): "local:\(id)"
        case .ssh(let id): "ssh:\(id.uuidString)"
        }
    }

    /// A terminal or host, as opposed to a page.
    var isTerminal: Bool {
        switch self {
        case .local, .ssh: true
        case .home, .devices: false
        }
    }
}

/// One sidebar for everything a person can open (Round 27): Home and Devices
/// first, then terminals on this Mac and saved SSH hosts, each section with
/// its own +. The detail column is the work itself, or the page chosen.
struct MacWorkspaceView: View {
    let service: LocalAgentService
    @Environment(ServerList.self) private var servers
    @Environment(MacPairedDevices.self) private var pairedDevices
    @State private var selection: MacDestination? = .home
    @State private var terminal = LocalTerminalModel()
    @State private var ssh = SSHWorkspaceModel()
    @State private var sshUI = SSHWorkspaceUI()
    @State private var endingSession: LocalSessionInfo?
    @State private var renamingSession: LocalSessionInfo?
    /// Continuing a session on another device, or pairing one without a session.
    @State private var continuing: ContinueRequest?
    @State private var remoteAccess = MacRemoteAccessModel()
    @AppStorage(WelcomeTour.key) private var tourVersion = 0
    @State private var showingTour = false
    @State private var connectingTooLong = false
    /// Open Quickly (⇧⌘O), and what was chosen in it: run once the sheet has
    /// closed, so a sheet it opens or a terminal it focuses isn't racing it.
    @State private var quickOpen = false
    @State private var quickOpenChoice: QuickOpenItem?
    /// The next selection change takes the keyboard even though a key
    /// (Return in Open Quickly) is what caused it.
    @State private var focusNextSelection = false
    @Environment(\.openSettings) private var openSettings
    @Environment(NetworkStatus.self) private var network: NetworkStatus?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .witermTint()
        .frame(minWidth: 860, minHeight: 560)
        .toolbar {
            // The list refreshes on its own; ⌘R stays in the View menu.
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button(String(localized: "New Terminal", bundle: .main), systemImage: "terminal", action: newSession)
                        .disabled(!canCreateSession)
                        .accessibilityIdentifier("newLocalSession")
                        .help(LocalTerminalHelp.newTerminal)
                    if selectedLocalSession != nil {
                        Button(String(localized: "New Terminal in Same Folder", bundle: .main), systemImage: "folder",
                               action: newSessionBeside)
                            .disabled(!canCreateSession)
                            .accessibilityIdentifier("newLocalSessionBeside")
                            .help(LocalTerminalHelp.newTerminalBeside)
                    }
                    Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "network", action: sshUI.presentNew)
                        .disabled(ssh.connecting)
                        .accessibilityIdentifier("newSSHProfile")
                        .help(LocalTerminalHelp.addSSHHost)
                } label: {
                    Label(String(localized: "New", bundle: .main), systemImage: "plus")
                } primaryAction: {
                    if canCreateSession { newSession() } else { sshUI.presentNew() }
                }
                .accessibilityIdentifier("newMenu")
                .help(LocalTerminalHelp.newTerminal)
            }
            // Open Quickly from any page; Home also has it inline.
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Open Quickly…", bundle: .main), systemImage: "magnifyingglass") { quickOpen = true }
                    .help(String(localized: "Open Quickly (⇧⌘O): terminals, hosts, snippets and commands", bundle: .main))
                    .accessibilityIdentifier("openQuicklyToolbar")
            }
        }
        .focusedSceneValue(\.workspaceActions, workspaceActions)
        .modifier(SSHPresentations(model: ssh, ui: sshUI))
        .sheet(item: $renamingSession, onDismiss: refocus) { session in
            RenameSessionSheet(current: session.name) { name in
                guard let client = service.client, name != session.name else { return }
                terminal.rename(session, to: name, using: client)
            }
        }
        .sheet(item: $continuing, onDismiss: refocus) { request in
            ContinueOnDeviceSheet(service: service, sessionID: request.sessionID, target: request.target) { id in
                terminal.summary(for: id)
            }
        }
        .sheet(isPresented: $quickOpen, onDismiss: {
            if let choice = quickOpenChoice {
                quickOpenChoice = nil
                choice.perform()
            } else {
                refocus()
            }
        }) {
            MacQuickOpenSheet(items: quickOpenItems, suggestions: quickOpenSuggestions) { choice in
                quickOpenChoice = choice
                quickOpen = false
            } cancel: {
                quickOpen = false
            }
        }
        .alert(String(localized: "End “\(endingSession?.name ?? "")”?", bundle: .main), isPresented: Binding(get: { endingSession != nil }, set: { if !$0 { endingSession = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { endingSession = nil }
            Button(String(localized: "End Terminal", bundle: .main), role: .destructive) {
                if let session = endingSession, let client = service.client { terminal.close(session, using: client) }
                endingSession = nil
            }
        } message: {
            Text(String(localized: "Its shell and the programs in it stop, here and on every device. Unsaved work in them is lost.", bundle: .main))
        }
        .sheet(isPresented: $showingTour) {
            MacWelcomeTour(service: service) { finished in
                tourVersion = WelcomeTour.version
                showingTour = false
                // Land on the first useful thing: a new terminal, ready to type.
                if finished, canCreateSession, terminal.sessions.isEmpty { newSession() }
            }
        }
        .task {
            #if DEBUG
            // Test hook only (docs/verification.md): `-witerm.debug.appearance
            // light|dark` fixes the appearance for screenshot runs. Never in
            // the UI or in release builds; the app otherwise follows the system.
            switch UserDefaults.standard.string(forKey: "witerm.debug.appearance") {
            case "light"?: NSApp.appearance = NSAppearance(named: .aqua)
            case "dark"?: NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
            #endif
            if tourVersion < WelcomeTour.version { showingTour = true }
            await refresh()
        }
        .modifier(TerminalPlaceTracking(service: service, terminal: terminal))
        .onReceive(NotificationCenter.default.publisher(for: .witermShowWelcomeTour)) { _ in
            NSApp.activate()
            showingTour = true
        }
        .onChange(of: service.state) { _, state in
            if state == .ready, let client = service.client {
                terminal.refresh(using: client)
                terminal.watch(using: client)
            } else {
                terminal.stopWatching()
                terminal.serviceUnavailable()
            }
        }
        .onChange(of: service.stopRequests) { terminal.serviceUnavailable() }
        .onChange(of: selection) { old, new in selectionChanged(from: old, to: new) }
        .onChange(of: terminal.selectedID) { _, id in
            if let id {
                selection = .local(id)
            } else if case .local = selection {
                selection = .home
            }
        }
        .onChange(of: ssh.connectingProfile?.id) { _, id in
            if let id { selection = .ssh(id) }
        }
        .onChange(of: ssh.profiles.map(\.id)) { _, ids in
            if case .ssh(let id) = selection, !ids.contains(id), ssh.connectingProfile?.id != id { selection = .home }
        }
        .onDisappear { ssh.disconnectAll(); terminal.stopWatching() }
        // From a server address that turned out to be an SSH login.
        .onReceive(NotificationCenter.default.publisher(for: .witermAddSSHHost)) { note in
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeMain && $0.isVisible && $0.identifier?.rawValue.contains("Settings") != true }?
                .makeKeyAndOrderFront(nil)
            sshUI.presentNew(address: note.object as? String)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            terminal.detach()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await refresh() }
        }
    }

    /// What the menu bar offers for this window.
    private var workspaceActions: WorkspaceActions {
        let create: (() -> Void)? = canCreateSession ? { newSession() } : nil
        var actions = WorkspaceActions(
            newSession: create,
            newSessionBeside: canCreateSession && selectedLocalSession != nil ? { newSessionBeside() } : nil,
            openQuickly: { quickOpen = true },
            newSSHConnection: sshUI.presentNew,
            importSSHHosts: sshUI.presentImport,
            continueOnDevice: { continuing = ContinueRequest(sessionID: selectedLocalSessionID) },
            continueTitle: String(localized: "Pair a Device…", bundle: .main),
            refresh: { Task { await refresh() } },
            terminalNames: openTerminals.map(\.name),
            showTerminal: { index in
                let terminals = openTerminals
                if terminals.indices.contains(index) { selection = terminals[index].destination }
            },
            showAdjacentTerminal: { step in
                let terminals = openTerminals
                guard !terminals.isEmpty else { return }
                let current = terminals.firstIndex { $0.destination == selection }
                let next = current.map { ($0 + step + terminals.count) % terminals.count } ?? (step > 0 ? 0 : terminals.count - 1)
                selection = terminals[next].destination
            }
        )
        if case .ssh(let id) = selection, let profile = ssh.profiles.first(where: { $0.id == id }) {
            if let session = ssh.session(for: id) {
                actions.sshFiles = { sshUI.files = session }
                actions.sshForwarding = { sshUI.forwarding = session }
                actions.disconnect = { NotificationCenter.default.post(name: .witermDisconnectSSH, object: id) }
            } else if !ssh.connecting {
                actions.connect = { sshUI.open(profile, model: ssh) }
            }
        }
        if let session = selectedLocalSession {
            actions.openOn = { continuing = ContinueRequest(sessionID: session.id, target: $0) }
            actions.openOnDevices = openOnDevices
            actions.renameSession = { renamingSession = session }
            actions.endSession = { endingSession = session }
            if let mode = terminal.openMode(session), let client = service.client {
                actions.typingHere = mode == .control
                actions.setTyping = { terminal.setTyping($0, using: client) }
                actions.leave = { terminal.detach() }
            }
            actions.remoteTypingPaused = session.sharing?.remoteTyping == false
            actions.keepPrivate = session.sharing?.keepPrivate == true
            actions.shared = session.sharing?.shared == true
            if let client = service.client {
                let paused = actions.remoteTypingPaused, kept = actions.keepPrivate
                // Sharing ▸ disables Pause Remote Typing while kept private.
                actions.toggleRemoteTyping = { if !kept { terminal.configure(session, remoteTyping: paused, using: client) } }
                actions.toggleKeepPrivate = { terminal.configure(session, keepPrivate: !kept, using: client) }
                actions.stopSharing = { terminal.setShared(session, false, using: client) }
            }
        }
        return actions
    }

    /// Paired devices for Open On ▸.
    private var openOnDevices: [OpenOnDevice] {
        pairedDevices.devices.map { OpenOnDevice(id: $0.id, name: $0.name) }
    }

    /// Follows the relay server in use while remote access is on through it.
    private var pairedDevicesKey: String? {
        guard let server = servers.selected, remoteAccess.isEnabled(for: server.address) else { return nil }
        return server.address
    }

    /// Terminals in sidebar order: sessions on this Mac, then connected SSH hosts.
    private var openTerminals: [(name: String, destination: MacDestination)] {
        let local = service.state == .ready && terminal.tmuxAvailable
            ? terminal.sessions.map { (name: $0.name, destination: MacDestination.local($0.id)) } : []
        return local + ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil }
            .map { (name: $0.name, destination: MacDestination.ssh($0.id)) }
    }

    private var selectedLocalSessionID: String? {
        if case .local(let id) = selection { return id }
        return nil
    }

    private var selectedLocalSession: LocalSessionInfo? {
        selectedLocalSessionID.flatMap { id in terminal.sessions.first { $0.id == id } }
    }

    /// A new session right away, named for you and ready to type in.
    private func newSession() {
        guard canCreateSession, let client = service.client else { return }
        terminal.create(name: terminal.nextSessionName, using: client)
    }

    /// "npm just finished", then "npm finished 2 minutes ago", for a
    /// terminal's Finished mark. Under a minute the formatter would say "in
    /// 0 seconds", so that's said in words.
    static func finishedText(_ done: LocalTerminalModel.FinishedCommand, now: Date = .now) -> String {
        guard now.timeIntervalSince(done.at) >= 60 else {
            return String(localized: "\(done.command) just finished", bundle: .main)
        }
        let ago = RelativeDateTimeFormatter().localizedString(for: done.at, relativeTo: now)
        return String(localized: "\(done.command) finished \(ago)", bundle: .main)
    }

    /// A new terminal in the folder the selected terminal's shell is in now,
    /// named after that folder.
    private func newSessionBeside() {
        guard canCreateSession, let client = service.client, let session = selectedLocalSession else { return }
        terminal.createBeside(session, using: client)
    }

    /// Gives the keyboard back to the terminal on screen after a sheet.
    private func refocus() {
        switch selection {
        case .local?: if terminal.attachment != nil { terminal.focusTerminal() }
        case .ssh(let id)?: ssh.session(for: id)?.terminal.surface.terminal.requestFocus()
        case .home?, .devices?, nil: break
        }
    }

    /// Arrowing through the sidebar browses; a click, a menu shortcut, or
    /// Return means "take me there", so only those move keyboard focus.
    private var browsingWithKeyboard: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// Return on the sidebar opens the selection: focuses its terminal, or
    /// connects a saved host or a session that isn't open here.
    private func openSelection() -> Bool {
        switch selection {
        case .local(let id)?:
            guard let client = service.client else { return false }
            if terminal.selectedID == id, terminal.attachment != nil { terminal.focusTerminal() }
            else if let session = terminal.sessions.first(where: { $0.id == id }) { terminal.attach(session, using: client, mode: .control) }
            return true
        case .ssh(let id)?:
            if let session = ssh.session(for: id) {
                session.terminal.surface.terminal.requestFocus()
            } else if let profile = ssh.profiles.first(where: { $0.id == id }), !ssh.connecting {
                sshUI.open(profile, model: ssh)
            }
            return true
        case .home?, .devices?, nil:
            return false
        }
    }

    private var canCreateSession: Bool {
        service.state == .ready && terminal.tmuxAvailable && !terminal.isWorking && terminal.sessions.count < 16
    }

    private func refresh() async {
        await service.refresh()
        if service.state == .ready, let client = service.client {
            terminal.refresh(using: client)
            terminal.watch(using: client)
        }
        await ssh.load()
    }

    private func selectionChanged(from old: MacDestination?, to new: MacDestination?) {
        let focus = focusNextSelection || !browsingWithKeyboard
        focusNextSelection = false
        // What was opened most recently comes first in Open Quickly; arrowing
        // through the sidebar only browses, so it isn't counted.
        if let new, new.isTerminal, focus { QuickOpenRanking.saveRecent(QuickOpenRanking.remember(new.quickOpenID, in: QuickOpenRanking.loadRecent())) }
        // SSH sessions own their renderers and stay connected across selection.
        if case .ssh(let id) = new, let session = ssh.session(for: id) {
            session.terminal.surface.terminal.focusWhenShown = focus
        }
        // Round 28: a click on a host connects it, as a click on a terminal
        // opens it; arrowing through the list only browses.
        if case .ssh(let id) = new, focus, ssh.session(for: id) == nil, !ssh.connecting,
           let profile = ssh.profiles.first(where: { $0.id == id }) {
            sshUI.open(profile, model: ssh)
        }
        guard case .local(let id) = new, let client = service.client else { return }
        terminal.select(id, using: client, focus: focus)
        if terminal.selectedID != id {
            selection = terminal.selectedID.map(MacDestination.local)
        }
    }

    // MARK: Open Quickly

    /// Everything Open Quickly reaches, from what this window has now. Only
    /// commands that would work are listed ("Never show actions that can't
    /// work yet"), each with its menu shortcut so the shortcut can be learned.
    private var quickOpenItems: [QuickOpenItem] {
        var items: [QuickOpenItem] = []
        if service.state == .ready, terminal.tmuxAvailable, service.client != nil {
            for session in terminal.sessions {
                let open = terminal.openMode(session) != nil
                items.append(QuickOpenItem(
                    id: MacDestination.local(session.id).quickOpenID, kind: .terminal, title: session.name,
                    detail: terminal.summary(for: session.id),
                    symbol: open ? "terminal.fill" : "terminal",
                    keywords: [String(localized: "This Mac", bundle: .main)]) {
                        show(.local(session.id))
                    })
            }
        }
        for profile in ssh.orderedProfiles() {
            let session = ssh.session(for: profile.id)
            items.append(QuickOpenItem(
                id: MacDestination.ssh(profile.id).quickOpenID, kind: .host, title: profile.name,
                detail: session?.activity.summary(home: nil) ?? profile.endpointSummary,
                symbol: session != nil ? "terminal.fill" : WitermSymbols.sshHost,
                keywords: ["ssh", profile.host.hostname, profile.host.username, profile.endpointSummary],
                tint: profile.identityHue) {
                    show(.ssh(profile.id))
                })
        }
        items += quickOpenCommands
        for snippet in CommandSnippets.load() where terminalShown {
            items.append(QuickOpenItem(
                id: "snippet:\(snippet.id.uuidString)", kind: .snippet, title: snippet.name,
                detail: snippet.text.split(whereSeparator: \.isNewline).first.map(String.init),
                symbol: "text.insert", keywords: [String(localized: "Insert Snippet", bundle: .main)]) {
                    refocus()
                    // The terminal takes the keyboard back as the sheet ends;
                    // the snippet is typed where it lands, like the menu's.
                    DispatchQueue.main.async { TerminalSnippet.insert(snippet) }
                })
        }
        return items
    }

    private var quickOpenCommands: [QuickOpenItem] {
        func command(_ id: String, _ title: String, symbol: String, shortcut: String? = nil, keywords: [String] = [],
                     detail: String? = nil, _ perform: @escaping () -> Void) -> QuickOpenItem {
            QuickOpenItem(id: "action:" + id, kind: .command, title: title, detail: detail, symbol: symbol,
                          keywords: keywords, shortcut: shortcut, perform: perform)
        }
        var commands: [QuickOpenItem] = []
        if canCreateSession {
            commands.append(command("newTerminal", String(localized: "New Terminal", bundle: .main), symbol: "plus",
                                    shortcut: "⌘N", keywords: ["shell", "tab"], newSession))
            if selectedLocalSession != nil {
                commands.append(command("newTerminalBeside", String(localized: "New Terminal in Same Folder", bundle: .main),
                                        symbol: "folder", shortcut: "⌥⌘N", keywords: ["shell", "tab", "cd", "here"],
                                        newSessionBeside))
            }
        }
        if !ssh.connecting {
            commands.append(command("addSSHHost", String(localized: "Add SSH Host…", bundle: .main), symbol: "network",
                                    shortcut: "⇧⌘N", keywords: ["ssh", "server", "connect"], sshUI.presentNew))
            commands.append(command("importSSHHosts", String(localized: "Import SSH Hosts…", bundle: .main),
                                    symbol: "square.and.arrow.down", keywords: ["ssh", "config"], sshUI.presentImport))
        }
        if let session = selectedLocalSession, let client = service.client {
            commands.append(command("openOn", String(localized: "Open “\(session.name)” on Another Device…", bundle: .main),
                                    symbol: WitermSymbols.openOn, shortcut: "⌥⌘P", keywords: ["iphone", "ipad", "share", "continue"]) {
                continuing = ContinueRequest(sessionID: session.id)
            })
            if let mode = terminal.openMode(session) {
                let typing = mode == .control
                commands.append(command("typing", typing ? String(localized: "Stop Typing", bundle: .main)
                                                         : String(localized: "Start Typing", bundle: .main),
                                        symbol: typing ? WitermSymbols.watching : WitermSymbols.typing, shortcut: "⇧⌘T") {
                    terminal.setTyping(!typing, using: client)
                })
                commands.append(command("leave", String(localized: "Leave", bundle: .main), symbol: WitermSymbols.leave) {
                    terminal.detach()
                })
            }
            commands.append(command("rename", String(localized: "Rename Terminal…", bundle: .main), symbol: "pencil",
                                    shortcut: "⇧⌘R") { renamingSession = session })
            commands.append(command("endTerminal", String(localized: "End Terminal…", bundle: .main), symbol: "xmark.octagon",
                                    keywords: ["kill", "close", "quit"]) { endingSession = session })
        } else {
            commands.append(command("pair", String(localized: "Pair a Device…", bundle: .main), symbol: WitermSymbols.pair,
                                    shortcut: "⌥⌘P", keywords: ["iphone", "ipad"]) {
                continuing = ContinueRequest(sessionID: nil)
            })
        }
        if case .ssh(let id) = selection, let session = ssh.session(for: id) {
            commands.append(command("sftp", String(localized: "SFTP Files…", bundle: .main), symbol: "folder",
                                    keywords: ["upload", "download", "files"]) { sshUI.files = session })
            commands.append(command("forwarding", String(localized: "Port Forwarding…", bundle: .main), symbol: "arrow.left.arrow.right",
                                    keywords: ["tunnel", "port"]) { sshUI.forwarding = session })
            commands.append(command("disconnect", String(localized: "Disconnect", bundle: .main), symbol: WitermSymbols.disconnect) {
                NotificationCenter.default.post(name: .witermDisconnectSSH, object: id)
            })
        }
        commands.append(command("settings", String(localized: "Settings…", bundle: .main), symbol: "gearshape", shortcut: "⌘,",
                                keywords: ["preferences", "font", "colors", "snippets"]) { openSettings() })
        commands.append(command("home", LocalTerminalHelp.homePage, symbol: "house",
                                keywords: ["start", "overview"]) { selection = .home })
        commands.append(command("devices", String(localized: "Devices", bundle: .main), symbol: WitermSymbols.openOn,
                                keywords: ["paired", "unpair", "relay server", "remote access", "iphone", "ipad"],
                                detail: devicesStatus) { selection = .devices })
        commands.append(command("tour", String(localized: "Welcome Tour", bundle: .main), symbol: "questionmark.circle",
                                keywords: ["help"]) { showingTour = true })
        return commands
    }

    /// An SSH address typed into Open Quickly that no saved host has:
    /// offer to add it, with the form already filled in.
    private func quickOpenSuggestions(_ query: String) -> [QuickOpenItem] {
        guard !ssh.connecting, let text = SSHAddressInput.unsavedSuggestion(query, saved: ssh.profiles) else { return [] }
        return [QuickOpenItem(id: "suggest:addSSHHost", kind: .command,
                              title: String(localized: "Add SSH Host “\(text)”…", bundle: .main),
                              detail: LocalTerminalHelp.addSSHHost, symbol: "network") {
            sshUI.presentNew(address: text)
        }]
    }

    /// Selects a destination and gives it the keyboard, as a click would.
    /// Already selected: opens it (a terminal left here is opened again, a
    /// host connects) or gives it the keyboard; otherwise selecting it does.
    private func show(_ destination: MacDestination) {
        if selection == destination {
            _ = openSelection()
        } else {
            focusNextSelection = true
            selection = destination
        }
    }

    /// Whether a terminal is on screen here for a snippet to be typed into.
    private var terminalShown: Bool {
        switch selection {
        case .local?: terminal.attachment != nil
        case .ssh(let id)?: ssh.session(for: id) != nil
        case .home?, .devices?, nil: false
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            // The two pages first: where everything starts, and who else can
            // open this Mac's terminals, with its state at a glance.
            Label(LocalTerminalHelp.homePage, systemImage: "house")
                .witermRowHover(selected: selection == .home || selection == nil)
                .tag(MacDestination.home)
                .accessibilityIdentifier("homeSidebarRow")
            devicesRow
            Section {
                localRows
            } header: {
                SidebarSectionHeader(String(localized: "This Mac", bundle: .main),
                                     add: String(localized: "New Terminal", bundle: .main), help: LocalTerminalHelp.newTerminal,
                                     identifier: "newLocalSessionSidebar", action: newSession)
                    .disabled(!canCreateSession)
            }
            Section {
                ForEach(ssh.orderedProfiles()) { profile in
                    let session = ssh.session(for: profile.id)
                    SSHHostRowContent(profile: profile, active: session != nil, favorite: ssh.isFavorite(profile),
                                      activity: session?.activity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .witermRowHover(selected: selection == .ssh(profile.id))
                        .tag(MacDestination.ssh(profile.id))
                        .accessibilityIdentifier("sshProfileRow-\(profile.id.uuidString)")
                        .accessibilityLabel(profile.name)
                        .accessibilityValue(profile.accessibilitySummary
                            + (session == nil ? "" : String(localized: ", connected", bundle: .main))
                            + (ssh.isFavorite(profile) ? String(localized: ", favorite", bundle: .main) : ""))
                        .contextMenu {
                            // The primary action first, the destructive one last.
                            if let session {
                                Button(String(localized: "Disconnect", bundle: .main)) { ssh.disconnectChosen(session) }
                            } else {
                                Button(String(localized: "Connect", bundle: .main)) { show(.ssh(profile.id)) }
                                    .disabled(ssh.connecting)
                            }
                            // A checkmark shows the state, as on iOS.
                            Toggle(String(localized: "Favorite", bundle: .main),
                                   isOn: Binding(get: { ssh.isFavorite(profile) }, set: { _ in ssh.toggleFavorite(profile) }))
                            Divider()
                            if session == nil {
                                Button(String(localized: "Edit Host…", bundle: .main)) { sshUI.open(profile, model: ssh, editing: true) }
                                    .disabled(ssh.connecting)
                                    .accessibilityIdentifier("sshEditHostMenu")
                            }
                            Button(String(localized: "Host Keys", bundle: .main)) { sshUI.inspectKeys(profile) }
                            Divider()
                            Button(String(localized: "Delete Host…", bundle: .main), role: .destructive) { sshUI.remove(profile) }
                                .accessibilityIdentifier("sshDeleteHostMenu")
                        }
                }
                if ssh.profiles.isEmpty {
                    Text(String(localized: "None saved", bundle: .main))
                        .font(WitermType.rowDetail)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            } header: {
                SidebarSectionHeader(String(localized: "SSH Hosts", bundle: .main),
                                     add: String(localized: "Add SSH Host…", bundle: .main), help: LocalTerminalHelp.addSSHHost,
                                     identifier: "addSSHHostSidebar", action: sshUI.presentNew)
                    .disabled(ssh.connecting)
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) { openSelection() ? .handled : .ignored }
        // Native selection: the row fills with the tint behind white text, so
        // the sidebar keeps the system accent rather than the app's ink.
        .tint(Color.accentColor)
        .navigationTitle("Witerm")
        // Connecting… for more than 10 seconds becomes a reason, not a wait.
        .task(id: devicesRemoteState == .connecting) {
            connectingTooLong = false
            guard devicesRemoteState == .connecting else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { connectingTooLong = true }
        }
        .task { remoteAccess.load() }
        .onChange(of: terminal.relays) { remoteAccess.load() }
        // The paired devices for Open On ▸, rechecked so a device that
        // unpairs itself leaves at once, and is announced.
        .task(id: pairedDevicesKey) { pairedDevices.track(serverAddress: pairedDevicesKey, agent: service.client) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await pairedDevices.recheck() }
        }
        .onChange(of: PairedSnapshot(address: pairedDevices.pairing?.serverAddress, devices: pairedDevices.devices)) { old, new in
            guard old.address == new.address else { return }
            for name in MacPairedDevices.removed(from: old.devices, to: new.devices) {
                AccessibilityNotification.Announcement(String(localized: "\(name) unpaired", bundle: .main)).post()
            }
        }
    }

    @ViewBuilder
    private var localRows: some View {
        if service.state == .ready, terminal.tmuxAvailable {
            ForEach(terminal.sessions) { session in
                // How this window has it open, if it does.
                let here = terminal.openMode(session)
                let attached = here != nil
                let shared = session.sharing?.shared == true
                let keptPrivate = session.sharing?.keepPrivate == true
                // Who else has this terminal open right now, at a glance.
                let elsewhere = session.remoteDeviceNames
                let elsewhereDetail = terminal.elsewhere(session)
                let doing = terminal.summary(for: session.id)
                Label {
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                        HStack(spacing: WitermMetrics.Space.xs) {
                            Text(session.name).lineLimit(1)
                            if keptPrivate {
                                Image(systemName: "lock.fill")
                                    .font(WitermType.meta)
                                    .foregroundStyle(.secondary)
                                    .help(String(localized: "Private: no paired device can open it", bundle: .main))
                                    .accessibilityHidden(true)
                            } else if shared {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(WitermType.meta)
                                    .foregroundStyle(.secondary)
                                    .help(String(localized: "Shared: every paired device can open it", bundle: .main))
                                    .accessibilityHidden(true)
                            }
                            if !elsewhere.isEmpty {
                                HStack(spacing: WitermMetrics.Space.xxs) {
                                    Image(systemName: "laptopcomputer.and.iphone")
                                    if elsewhere.count > 1 { Text(verbatim: "\(elsewhere.count)").monospacedDigit() }
                                }
                                .font(WitermType.meta)
                                .foregroundStyle(WitermTheme.positive)
                                .help(ListFormatter.localizedString(byJoining: elsewhereDetail))
                                .accessibilityHidden(true)
                            }
                            // A long command ended while it wasn't shown here.
                            if let done = terminal.finished[session.id] {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(WitermType.meta)
                                    .foregroundStyle(WitermTheme.positive)
                                    .help(Self.finishedText(done))
                                    .accessibilityHidden(true)
                            }
                            // Watching here: nothing typed in this window is sent.
                            if here == .view {
                                Image(systemName: "eye")
                                    .font(WitermType.meta)
                                    .foregroundStyle(.secondary)
                                    .help(String(localized: "Watching", bundle: .main))
                                    .accessibilityHidden(true)
                            }
                        }
                        // What it was doing when last shown here.
                        if let doing {
                            Text(verbatim: doing)
                                .font(WitermType.codeInline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } icon: {
                    Image(systemName: attached ? "terminal.fill" : "terminal")
                        .foregroundStyle(attached ? WitermTheme.positive : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .witermRowHover(selected: selection == .local(session.id))
                .tag(MacDestination.local(session.id))
                .accessibilityLabel(session.name)
                .accessibilityValue([here == .control ? String(localized: "Typing", bundle: .main)
                                        : here == .view ? String(localized: "Watching", bundle: .main) : nil,
                                     keptPrivate ? String(localized: "Kept private", bundle: .main)
                                        : shared ? String(localized: "Shared", bundle: .main) : nil,
                                     elsewhereDetail.isEmpty ? nil : ListFormatter.localizedString(byJoining: elsewhereDetail),
                                     terminal.finished[session.id].map { Self.finishedText($0) },
                                     doing]
                    .compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier("localSession-\(session.id)")
                .contextMenu {
                    if let client = service.client {
                        // Shown here: the switch, titled by what it does next,
                        // and Leave. Not shown: the two ways to open it.
                        if let here {
                            TypingMenuItems(mode: here) { terminal.setTyping($0, using: client) }
                            Button(String(localized: "Leave", bundle: .main), systemImage: "rectangle.portrait.and.arrow.right") { terminal.detach() }
                                .accessibilityIdentifier("leaveLocalSession")
                        } else {
                            Button(LocalTerminalHelp.open, systemImage: "keyboard") { terminal.attach(session, using: client, mode: .control) }
                                .accessibilityIdentifier("typeLocalSession")
                            Button(String(localized: "Watch", bundle: .main), systemImage: "eye") { terminal.attach(session, using: client, mode: .view) }
                                .accessibilityIdentifier("watchLocalSession")
                        }
                        Button(String(localized: "New Terminal in Same Folder", bundle: .main), systemImage: "folder") {
                            terminal.createBeside(session, using: client)
                        }
                        .disabled(!canCreateSession)
                        .help(LocalTerminalHelp.newTerminalBeside)
                        .accessibilityIdentifier("newLocalSessionBesideMenu")
                        Divider()
                        Menu(String(localized: "Open On", bundle: .main)) {
                            OpenOnItems(devices: openOnDevices) { continuing = ContinueRequest(sessionID: session.id, target: $0) }
                        }
                        .accessibilityIdentifier("openOnMenu")
                        SharingMenu(keepPrivate: keptPrivate, remoteTypingPaused: session.sharing?.remoteTyping == false,
                                    shared: shared,
                                    toggleKeepPrivate: { terminal.configure(session, keepPrivate: !keptPrivate, using: client) },
                                    toggleRemoteTyping: { terminal.configure(session, remoteTyping: session.sharing?.remoteTyping == false, using: client) },
                                    stopSharing: { terminal.setShared(session, false, using: client) })
                        Divider()
                        Button(String(localized: "Rename…", bundle: .main)) { renamingSession = session }
                        Button(String(localized: "End Terminal…", bundle: .main), role: .destructive) { endingSession = session }
                            .accessibilityIdentifier("endSessionMenu")
                    }
                }
                .disabled(terminal.isWorking)
            }
            if terminal.sessions.isEmpty {
                Text(String(localized: "None running", bundle: .main))
                    .font(WitermType.rowDetail)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        } else {
            Text(localStatusSummary)
                .font(WitermType.rowDetail)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }

    private var localStatusSummary: String {
        if service.state == .ready { return String(localized: "tmux Required", bundle: .main) }
        switch service.state {
        case .starting: return String(localized: "Turning on terminals…", bundle: .main)
        case .requiresApproval: return String(localized: "Waiting for approval in System Settings", bundle: .main)
        case .notRegistered: return String(localized: "Terminals are off", bundle: .main)
        case .unavailable, .ready: return String(localized: "Terminals not responding", bundle: .main)
        }
    }

    /// Devices: who else can open this Mac's terminals. Its second line is
    /// whether this Mac is reachable, from what the background service
    /// reports rather than the setting alone (Round 27; it was a footer that
    /// opened Settings → Devices).
    private var devicesRow: some View {
        Label {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                Text(String(localized: "Devices", bundle: .main))
                Text(devicesStatus)
                    .font(WitermType.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: WitermSymbols.openOn)
                .foregroundStyle(devicesRemoteState == .ready ? WitermTheme.positive : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witermRowHover(selected: selection == .devices)
        .tag(MacDestination.devices)
        .help(String(localized: "Relay server: \(devicesServerTitle)", bundle: .main))
        .accessibilityLabel(String(localized: "Devices", bundle: .main))
        .accessibilityValue(devicesStatus)
        .accessibilityIdentifier("devicesSidebarRow")
    }

    /// The server new pairings go through, the same one Devices shows.
    private var devicesServerTitle: String {
        servers.selected?.displayName ?? String(localized: "No Relay Server", bundle: .main)
    }

    /// What the background service reports for the selected server, not only
    /// the setting: a server can answer checks while this Mac isn't online.
    /// Nil unless remote access is on for the selected server.
    private var devicesRemoteState: MacRemoteAccessState? {
        guard let server = servers.selected, remoteAccess.isEnabled(for: server.address) else { return nil }
        return MacRemoteAccessState(enabled: true, serviceReady: service.state == .ready, relays: terminal.relays,
                                    address: server.address)
    }

    /// Why this Mac isn't reachable, when there's a reason worth showing:
    /// no network at all, or the relay server still not accepting this Mac
    /// after 10 seconds.
    private enum DevicesProblem { case offline, unreachable }

    private var devicesProblem: DevicesProblem? {
        guard devicesRemoteState != nil else { return nil }
        if network?.online == false { return .offline }
        if devicesRemoteState == .connecting, connectingTooLong { return .unreachable }
        return nil
    }

    private var devicesStatus: String {
        guard devicesRemoteState != nil else { return String(localized: "Remote access off", bundle: .main) }
        if let server = servers.selected, case .failed = server.phase { return server.statusTitle }
        switch devicesProblem {
        case .offline?: return String(localized: "Remote access on · Offline", bundle: .main)
        case .unreachable?: return String(localized: "Remote access on · Can’t reach the relay server", bundle: .main)
        case nil: break
        }
        switch devicesRemoteState {
        case .serviceOff?: return String(localized: "Remote access on · Terminals off", bundle: .main)
        case .ready?: return String(localized: "Remote access on · Online", bundle: .main)
        case .connecting?, .off?, nil: return String(localized: "Remote access on · Connecting…", bundle: .main)
        }
    }

    private var devicesSymbol: String {
        guard devicesRemoteState != nil else { return "antenna.radiowaves.left.and.right.slash" }
        if let server = servers.selected, case .failed = server.phase { return server.statusSymbol }
        switch devicesProblem {
        case .offline?: return WitermSymbols.offline
        case .unreachable?: return WitermSymbols.problem
        case nil: return devicesRemoteState?.systemImage ?? WitermSymbols.sharing
        }
    }

    private var devicesTint: Color {
        guard devicesRemoteState != nil else { return WitermTheme.secondary }
        if let server = servers.selected, case .failed = server.phase { return WitermTheme.warning }
        if devicesProblem != nil { return WitermTheme.warning }
        switch devicesRemoteState {
        case .ready?: return WitermTheme.positive
        case .serviceOff?: return WitermTheme.warning
        default: return WitermTheme.secondary
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .local?:
            LocalTerminalDetail(service: service, model: terminal, endSession: { endingSession = $0 },
                                renameSession: { renamingSession = $0 },
                                continueSession: { continuing = ContinueRequest(sessionID: $0.id) })
        case .ssh(let id)?:
            // A new host is selected as soon as it starts connecting, before
            // it is saved; show it so its progress and errors stay visible.
            if let profile = ssh.profiles.first(where: { $0.id == id })
                ?? ssh.connectingProfile.flatMap({ $0.id == id ? $0 : nil }) {
                SSHHostDetail(profile: profile, model: ssh, ui: sshUI)
                    .safeAreaInset(edge: .top, spacing: 0) { offlineBanner }
            } else {
                home
            }
        case .devices?:
            MacDevicesView(service: service)
                .navigationTitle(String(localized: "Devices", bundle: .main))
                .background(WitermTheme.canvas)
        case .home?, nil:
            home
        }
    }

    /// Remote destinations only; terminals on this Mac work offline.
    private var offlineBanner: some View {
        OfflineBanner(insets: EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20))
    }

    private var home: some View {
        MacHomeView(service: service, terminalModel: terminal, terminals: homeTerminals, hosts: homeHosts,
                    devices: homeDevices, canCreate: canCreateSession, items: quickOpenItems,
                    suggestions: quickOpenSuggestions, newTerminal: newSession, addHost: sshUI.presentNew,
                    importHosts: sshUI.presentImport,
                    openTerminal: { id, mode in
                        guard let client = service.client, let session = terminal.sessions.first(where: { $0.id == id }) else { return }
                        if mode == .view {
                            selection = .local(id)
                            terminal.attach(session, using: client, mode: .view)
                        } else {
                            show(.local(id))
                        }
                    },
                    openHost: { show(.ssh($0)) },
                    showDevices: { selection = .devices },
                    pairDevice: { continuing = ContinueRequest(sessionID: nil) })
            .safeAreaInset(edge: .top, spacing: 0) {
                if let issue = terminal.issue, service.state == .ready {
                    IssueBanner(issue.title, message: issue.recovery)
                        .padding(.horizontal, WitermMetrics.Space.l)
                        .padding(.top, WitermMetrics.Space.m)
                }
            }
    }

    private var homeTerminals: [HomeTerminal] {
        guard service.state == .ready, terminal.tmuxAvailable else { return [] }
        let relative = RelativeDateTimeFormatter()
        return terminal.sessions.map { session in
            let started = String(localized: "Started \(relative.localizedString(for: session.createdAt, relativeTo: .now))", bundle: .main)
            let summary = terminal.summary(for: session.id)
            let lastLine = terminal.activity(for: session.id).lastLine
            return HomeTerminal(id: session.id, name: session.name,
                                detail: summary ?? started, detailIsCode: summary != nil,
                                lastLine: lastLine == summary ? nil : lastLine,
                                here: terminal.openMode(session), shared: session.sharing?.shared == true,
                                keptPrivate: session.sharing?.keepPrivate == true, elsewhere: terminal.elsewhere(session),
                                finished: terminal.finished[session.id])
        }
    }

    private var homeHosts: [HomeHost] {
        ssh.orderedProfiles().map { profile in
            let session = ssh.session(for: profile.id)
            return HomeHost(id: profile.id, name: profile.name,
                            detail: session?.activity.summary(home: nil) ?? profile.distinctAddress,
                            connected: session != nil, favorite: ssh.isFavorite(profile), hue: profile.identityHue)
        }
    }

    private var homeDevices: HomeDevices {
        let names = pairedDevices.devices.map(\.name)
        let detail = names.isEmpty
            ? String(localized: "Pair your iPhone or iPad to open these terminals there.", bundle: .main)
            : ListFormatter.localizedString(byJoining: names)
        return HomeDevices(status: devicesStatus, symbol: devicesSymbol, tint: devicesTint, detail: detail)
    }
}
/// A sidebar section's heading with its one way to add more (+), which
/// stays visible, unlike a row that disappears once the section has items.
private struct SidebarSectionHeader: View {
    let title: String
    let add: String
    let help: String
    let identifier: String
    let action: () -> Void

    init(_ title: String, add: String, help: String, identifier: String, action: @escaping () -> Void) {
        self.title = title
        self.add = add
        self.help = help
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: WitermMetrics.Space.s)
            Button(add, systemImage: "plus", action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(add + " " + help)
                .accessibilityIdentifier(identifier)
        }
    }
}
/// Where each terminal is and what it runs, rechecked while this Mac's
/// terminals are in reach, in the background too, so a long command that
/// finishes while Witerm isn't in front still gets its mark. Finished
/// terminals count on the Dock icon until they're opened; no notification
/// permission is needed for that (Round 28).
private struct TerminalPlaceTracking: ViewModifier {
    let service: LocalAgentService
    let terminal: LocalTerminalModel

    func body(content: Content) -> some View {
        content
            .task(id: service.state == .ready && terminal.tmuxAvailable) {
                guard service.state == .ready, terminal.tmuxAvailable else { return }
                while !Task.isCancelled {
                    if let client = service.client { await terminal.refreshFolders(using: client) }
                    try? await Task.sleep(for: .seconds(NSApp.isActive ? 4 : 8))
                }
            }
            .onChange(of: terminal.finished.count, initial: true) { _, count in
                NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
            }
    }
}
#endif
