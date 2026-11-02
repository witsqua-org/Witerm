#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// A request to continue a session on another device; nil pairs one.
struct ContinueRequest: Identifiable {
    let id = UUID()
    let sessionID: String?
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
                    Button(String(localized: "New Terminal Session", bundle: .main), systemImage: "terminal", action: newSession)
                        .disabled(!canCreateSession)
                        .accessibilityIdentifier("newLocalSession")
                    Button(String(localized: "New SSH Connection", bundle: .main), systemImage: "network", action: sshUI.presentNew)
                        .disabled(ssh.connecting)
                        .accessibilityIdentifier("newSSHProfile")
                } label: {
                    Label(String(localized: "New", bundle: .main), systemImage: "plus")
                } primaryAction: {
                    if canCreateSession { newSession() } else { sshUI.presentNew() }
                }
                .accessibilityIdentifier("newMenu")
                .help(String(localized: "New Terminal Session", bundle: .main))
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
            ContinueOnDeviceSheet(service: service, sessionID: request.sessionID) { id in
                terminal.activity(for: id).summary(home: NSHomeDirectory())
            }
        }
        .alert(String(localized: "End Terminal Session?", bundle: .main), isPresented: Binding(get: { endingSession != nil }, set: { if !$0 { endingSession = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { endingSession = nil }
            Button(String(localized: "End Session", bundle: .main), role: .destructive) {
                if let session = endingSession, let client = service.client { terminal.close(session, using: client) }
                endingSession = nil
            }
        } message: {
            Text(String(localized: "Programs in this session will be terminated. Unsaved changes may be lost.", bundle: .main))
        }
        .sheet(isPresented: $showingTour) {
            MacWelcomeTour(service: service) { finished in
                tourVersion = WelcomeTour.version
                showingTour = false
                // Land on the first useful thing: a new session, ready to type.
                if finished, canCreateSession, terminal.sessions.isEmpty { newSession() }
            }
        }
        .task {
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
            continueTitle: selectedLocalSessionID == nil ? String(localized: "Pair a Device…", bundle: .main)
                : String(localized: "Continue on Another Device…", bundle: .main),
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
            actions.renameSession = { renamingSession = session }
            actions.endSession = { endingSession = session }
            actions.remoteTypingPaused = session.sharing?.remoteTyping == false
            if session.sharing?.keepPrivate != true, let client = service.client {
                let paused = actions.remoteTypingPaused
                actions.toggleRemoteTyping = { terminal.configure(session, remoteTyping: paused, using: client) }
            }
        }
        return actions
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
                        .tag(MacDestination.ssh(profile.id))
                        .accessibilityIdentifier("sshProfileRow-\(profile.id.uuidString)")
                        .accessibilityLabel(profile.name)
                        .accessibilityValue(profile.accessibilitySummary
                            + (session == nil ? "" : String(localized: ", connected", bundle: .main))
                            + (ssh.isFavorite(profile) ? String(localized: ", favorite", bundle: .main) : ""))
                        .contextMenu {
                            Button(ssh.isFavorite(profile) ? String(localized: "Remove from Favorites", bundle: .main) : String(localized: "Add to Favorites", bundle: .main)) { ssh.toggleFavorite(profile) }
                            if let session {
                                Button(String(localized: "Disconnect", bundle: .main)) { ssh.disconnect(session) }
                            } else {
                                Button(String(localized: "Connect", bundle: .main)) { selection = .ssh(profile.id); sshUI.open(profile, model: ssh) }
                                    .disabled(ssh.connecting)
                                Button(String(localized: "Edit Connection", bundle: .main)) { sshUI.open(profile, model: ssh, editing: true) }
                                    .disabled(ssh.connecting)
                            }
                            Button(String(localized: "Host Keys", bundle: .main)) { sshUI.inspectKeys(profile) }
                            Divider()
                            Button(String(localized: "Delete Connection", bundle: .main), role: .destructive) { sshUI.remove(profile) }
                        }
                }
                // Importing stays in File; one way in here is enough.
                if ssh.profiles.isEmpty {
                    Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus", action: sshUI.presentNew)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("addSSHHostSidebar")
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) { openSelection() ? .handled : .ignored }
        .searchable(text: $search, prompt: String(localized: "Search Sessions and Hosts", bundle: .main))
        // Native selection: the row fills with the tint behind white text, so
        // the sidebar keeps the system accent rather than the app's ink.
        .tint(Color.accentColor)
        .navigationTitle("Witerm")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Only while remote access is on: then whether this Mac is
            // reachable is worth a glance. Setup lives in the Continue sheet.
            if footerRemoteState != nil { serverFooter }
        }
        .task { remoteAccess.load() }
        .onChange(of: terminal.relays) { remoteAccess.load() }
    }

    @ViewBuilder
    private var localRows: some View {
        if service.state == .ready, terminal.tmuxAvailable {
            ForEach(terminal.sessions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { session in
                let attached = terminal.selectedID == session.id && terminal.attachment != nil
                let shared = session.sharing?.shared == true
                let keptPrivate = session.sharing?.keepPrivate == true
                // Who else has this session open right now, at a glance.
                let elsewhere = session.remoteDeviceNames
                let doing = terminal.activity(for: session.id).summary(home: NSHomeDirectory())
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(session.name).lineLimit(1)
                            if keptPrivate {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help(String(localized: "Kept private from every paired device", bundle: .main))
                                    .accessibilityHidden(true)
                            } else if shared {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help(String(localized: "Shared with paired devices", bundle: .main))
                                    .accessibilityHidden(true)
                            }
                            if !elsewhere.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "laptopcomputer.and.iphone")
                                    if elsewhere.count > 1 { Text(verbatim: "\(elsewhere.count)").monospacedDigit() }
                                }
                                .font(.caption)
                                .foregroundStyle(WitermTheme.positive)
                                .help(String(localized: "Open on \(ListFormatter.localizedString(byJoining: elsewhere))", bundle: .main))
                                .accessibilityHidden(true)
                            }
                        }
                        // What it was doing when last shown here.
                        if let doing {
                            Text(verbatim: doing)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } icon: {
                    Image(systemName: attached ? "terminal.fill" : "terminal")
                        .foregroundStyle(attached ? WitermTheme.positive : .secondary)
                }
                .tag(MacDestination.local(session.id))
                .accessibilityLabel(session.name)
                .accessibilityValue([attached ? String(localized: "Connected", bundle: .main) : nil,
                                     keptPrivate ? String(localized: "Kept private", bundle: .main)
                                        : shared ? String(localized: "Shared", bundle: .main) : nil,
                                     elsewhere.isEmpty ? nil
                                        : String(localized: "Open on \(ListFormatter.localizedString(byJoining: elsewhere))", bundle: .main),
                                     doing]
                    .compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier("localSession-\(session.id)")
                .contextMenu {
                    if let client = service.client {
                        Button(String(localized: "Connect", bundle: .main)) { terminal.attach(session, using: client, mode: .control) }
                        Button(String(localized: "View Only", bundle: .main)) { terminal.attach(session, using: client, mode: .view) }
                        Divider()
                        Button(String(localized: "Continue on Another Device…", bundle: .main)) { continuing = ContinueRequest(sessionID: session.id) }
                            .accessibilityIdentifier("continueOnDeviceMenu")
                        if shared {
                            Button(String(localized: "Stop Sharing", bundle: .main)) { terminal.setShared(session, false, using: client) }
                        }
                        RemoteAccessMenuItems(session: session) { keepPrivate, typing in
                            terminal.configure(session, keepPrivate: keepPrivate, remoteTyping: typing, using: client)
                        }
                        Divider()
                        Button(String(localized: "Rename…", bundle: .main)) { renamingSession = session }
                        Button(String(localized: "End Session", bundle: .main), role: .destructive) { endingSession = session }
                            .accessibilityIdentifier("endSessionMenu")
                    }
                }
                .disabled(terminal.isWorking)
            }
            if terminal.sessions.isEmpty {
                Button(String(localized: "New Terminal Session", bundle: .main), systemImage: "plus", action: newSession)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!canCreateSession)
                    .accessibilityIdentifier("newLocalSessionSidebar")
            }
        } else {
            Text(localStatusSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }

    private var localStatusSummary: String {
        if service.state == .ready { return String(localized: "tmux Required", bundle: .main) }
        switch service.state {
        case .starting: return String(localized: "Enabling local terminal…", bundle: .main)
        case .requiresApproval: return String(localized: "Waiting for background approval", bundle: .main)
        case .notRegistered: return String(localized: "Local terminal is off", bundle: .main)
        case .unavailable, .ready: return String(localized: "Local Terminal Unavailable", bundle: .main)
        }
    }

    private var serverFooter: some View {
        SettingsLink {
            HStack(spacing: 10) {
                Image(systemName: footerSymbol)
                    .foregroundStyle(footerTint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(footerStatus)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { settingsTab = SettingsTab.devices.rawValue })
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help(footerTitle)
        .accessibilityLabel(String(localized: "Continuation server: \(footerTitle), \(footerStatus)", bundle: .main))
        .accessibilityHint(String(localized: "Opens Settings", bundle: .main))
        .accessibilityIdentifier("serverStatusFooter")
    }

    /// The server new pairings go through, the same one Settings → Devices shows.
    private var footerTitle: String {
        servers.selected?.displayName ?? String(localized: "No Continuation Server", bundle: .main)
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

    private var footerStatus: String {
        if let server = servers.selected, case .failed = server.phase { return server.statusTitle }
        switch footerRemoteState {
        case .serviceOff?: return String(localized: "Remote access on · Local terminal off", bundle: .main)
        case .ready?: return String(localized: "Remote access on · Online", bundle: .main)
        case .connecting?, .off?, nil: return String(localized: "Remote access on · Connecting…", bundle: .main)
        }
    }

    private var footerSymbol: String {
        if let server = servers.selected, case .failed = server.phase { return server.statusSymbol }
        return footerRemoteState?.systemImage ?? "antenna.radiowaves.left.and.right"
    }

    private var footerTint: Color {
        if let server = servers.selected, case .failed = server.phase { return WitermTheme.warning }
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
