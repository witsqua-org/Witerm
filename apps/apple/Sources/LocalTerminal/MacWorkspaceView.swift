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
    case local(String)
    case ssh(UUID)
}

/// One sidebar for everything a person can open: sessions on this Mac and
/// saved SSH hosts. Paired devices are managed in Settings. The detail column
/// is always the work itself.
struct MacWorkspaceView: View {
    let service: LocalAgentService
    @Environment(ServerList.self) private var servers
    @Environment(MacPairedDevices.self) private var pairedDevices
    @State private var selection: MacDestination?
    @State private var terminal = LocalTerminalModel()
    @State private var ssh = SSHWorkspaceModel()
    @State private var sshUI = SSHWorkspaceUI()
    @State private var endingSession: LocalSessionInfo?
    @State private var renamingSession: LocalSessionInfo?
    /// Continuing a session on another device, or pairing one without a session.
    @State private var continuing: ContinueRequest?
    @State private var search = ""
    @State private var remoteAccess = MacRemoteAccessModel()
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.general.rawValue
    @AppStorage(WelcomeTour.key) private var tourVersion = 0
    @State private var showingTour = false
    @State private var connectingTooLong = false
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
                terminal.activity(for: id).summary(home: NSHomeDirectory())
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
                selection = nil
            }
        }
        .onChange(of: ssh.connectingProfile?.id) { _, id in
            if let id { selection = .ssh(id) }
        }
        .onChange(of: ssh.profiles.map(\.id)) { _, ids in
            if case .ssh(let id) = selection, !ids.contains(id), ssh.connectingProfile?.id != id { selection = nil }
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

    /// Gives the keyboard back to the terminal on screen after a sheet.
    private func refocus() {
        switch selection {
        case .local?: if terminal.attachment != nil { terminal.focusTerminal() }
        case .ssh(let id)?: ssh.session(for: id)?.terminal.surface.terminal.requestFocus()
        case nil: break
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
        case nil:
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
        let focus = !browsingWithKeyboard
        // SSH sessions own their renderers and stay connected across selection.
        if case .ssh(let id) = new, let session = ssh.session(for: id) {
            session.terminal.surface.terminal.focusWhenShown = focus
        }
        guard case .local(let id) = new, let client = service.client else { return }
        terminal.select(id, using: client, focus: focus)
        if terminal.selectedID != id {
            selection = terminal.selectedID.map(MacDestination.local)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section(String(localized: "This Mac", bundle: .main)) {
                localRows
            }
            Section(String(localized: "SSH Hosts", bundle: .main)) {
                ForEach(ssh.orderedProfiles(search: search)) { profile in
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
                                Button(String(localized: "Connect", bundle: .main)) { selection = .ssh(profile.id); sshUI.open(profile, model: ssh) }
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
                // Importing stays in File; one way in here is enough.
                if ssh.profiles.isEmpty {
                    Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus", action: sshUI.presentNew)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .witermRowHover(selected: false)
                        .help(LocalTerminalHelp.addSSHHost)
                        .accessibilityIdentifier("addSSHHostSidebar")
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) { openSelection() ? .handled : .ignored }
        .searchable(text: $search, prompt: String(localized: "Search Terminals and Hosts", bundle: .main))
        // Native selection: the row fills with the tint behind white text, so
        // the sidebar keeps the system accent rather than the app's ink.
        .tint(Color.accentColor)
        .navigationTitle("Witerm")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Only while remote access is on: then whether this Mac is
            // reachable is worth a glance. Setup lives in the Continue sheet.
            if footerRemoteState != nil { serverFooter }
        }
        // Connecting… for more than 10 seconds becomes a reason, not a wait.
        .task(id: footerRemoteState == .connecting) {
            connectingTooLong = false
            guard footerRemoteState == .connecting else { return }
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
            ForEach(terminal.sessions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { session in
                // How this window has it open, if it does.
                let here = terminal.openMode(session)
                let attached = here != nil
                let shared = session.sharing?.shared == true
                let keptPrivate = session.sharing?.keepPrivate == true
                // Who else has this terminal open right now, at a glance.
                let elsewhere = session.remoteDeviceNames
                let elsewhereDetail = terminal.elsewhere(session)
                let doing = terminal.activity(for: session.id).summary(home: NSHomeDirectory())
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
                Button(String(localized: "New Terminal", bundle: .main), systemImage: "plus", action: newSession)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .witermRowHover(selected: false)
                    .disabled(!canCreateSession)
                    .help(LocalTerminalHelp.newTerminal)
                    .accessibilityIdentifier("newLocalSessionSidebar")
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

    private var serverFooter: some View {
        // A button rather than SettingsLink plus a tap gesture: the tab is set
        // before Settings opens however it's pressed (click, Space with Full
        // Keyboard Access, or VoiceOver).
        Button {
            settingsTab = SettingsTab.devices.rawValue
            openSettings()
        } label: {
            HStack(spacing: WitermMetrics.Space.s) {
                Image(systemName: footerSymbol)
                    .foregroundStyle(footerTint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(footerStatus)
                    .font(WitermType.rowDetail)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: WitermMetrics.Space.xs)
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, WitermMetrics.Space.s)
            .padding(.vertical, WitermMetrics.Space.s)
            .contentShape(Rectangle())
            .witermHover(cornerRadius: WitermMetrics.Radius.s)
            .padding(.horizontal, WitermMetrics.Space.s)
            .padding(.vertical, WitermMetrics.Space.xs)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help(String(localized: "Relay server: \(footerTitle). Opens Settings → Devices.", bundle: .main))
        .accessibilityLabel(String(localized: "Relay server: \(footerTitle), \(footerStatus)", bundle: .main))
        .accessibilityHint(String(localized: "Opens Settings → Devices", bundle: .main))
        .accessibilityIdentifier("serverStatusFooter")
    }

    /// The server new pairings go through, the same one Settings → Devices shows.
    private var footerTitle: String {
        servers.selected?.displayName ?? String(localized: "No Relay Server", bundle: .main)
    }

    /// What the background service reports for the selected server, not only
    /// the setting: a server can answer checks while this Mac isn't online.
    /// Nil unless remote access is on for the selected server. A server that
    /// answers checks while this Mac isn't online reads as Connecting….
    private var footerRemoteState: MacRemoteAccessState? {
        guard let server = servers.selected, remoteAccess.isEnabled(for: server.address) else { return nil }
        return MacRemoteAccessState(enabled: true, serviceReady: service.state == .ready, relays: terminal.relays,
                                    address: server.address)
    }

    /// Why this Mac isn't reachable, when there's a reason worth showing:
    /// no network at all, or the relay server still not accepting this Mac
    /// after 10 seconds.
    private enum FooterProblem { case offline, unreachable }

    private var footerProblem: FooterProblem? {
        if network?.online == false { return .offline }
        if footerRemoteState == .connecting, connectingTooLong { return .unreachable }
        return nil
    }

    private var footerStatus: String {
        if let server = servers.selected, case .failed = server.phase { return server.statusTitle }
        switch footerProblem {
        case .offline?: return String(localized: "Remote access on · Offline", bundle: .main)
        case .unreachable?: return String(localized: "Remote access on · Can’t reach the relay server", bundle: .main)
        case nil: break
        }
        switch footerRemoteState {
        case .serviceOff?: return String(localized: "Remote access on · Terminals off", bundle: .main)
        case .ready?: return String(localized: "Remote access on · Online", bundle: .main)
        case .connecting?, .off?, nil: return String(localized: "Remote access on · Connecting…", bundle: .main)
        }
    }

    private var footerSymbol: String {
        if let server = servers.selected, case .failed = server.phase { return server.statusSymbol }
        switch footerProblem {
        case .offline?: return WitermSymbols.offline
        case .unreachable?: return WitermSymbols.problem
        case nil: return footerRemoteState?.systemImage ?? WitermSymbols.sharing
        }
    }

    private var footerTint: Color {
        if let server = servers.selected, case .failed = server.phase { return WitermTheme.warning }
        if footerProblem != nil { return WitermTheme.warning }
        switch footerRemoteState {
        case .ready?: return WitermTheme.positive
        case .serviceOff?: return WitermTheme.warning
        default: return .secondary
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
                overview
            }
        case nil:
            overview
        }
    }

    /// Remote destinations only; terminals on this Mac work offline.
    private var offlineBanner: some View {
        OfflineBanner(insets: EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20))
    }

    private var overview: some View {
        LocalOverview(service: service, model: terminal, canCreate: canCreateSession,
                      newSession: newSession, newSSHConnection: sshUI.presentNew)
    }
}
#endif
