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
    @State private var creatingSession = false
    @State private var endingSession: LocalSessionInfo?
    @State private var renamingSession: LocalSessionInfo?
    /// Continuing a session on another device, or pairing one without a session.
    @State private var continuing: ContinueRequest?
    @State private var search = ""
    @State private var remoteAccess = MacRemoteAccessModel()
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.general.rawValue

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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "New Terminal Session", bundle: .main), systemImage: "terminal") { creatingSession = true }
                        .disabled(!canCreateSession)
                        .accessibilityIdentifier("newLocalSession")
                    Button(String(localized: "New SSH Connection", bundle: .main), systemImage: "network", action: sshUI.presentNew)
                        .disabled(ssh.connecting)
                        .accessibilityIdentifier("newSSHProfile")
                } label: {
                    Label(String(localized: "New", bundle: .main), systemImage: "plus")
                }
                .accessibilityIdentifier("newMenu")
                .help(String(localized: "New terminal session or SSH connection", bundle: .main))
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Refresh", bundle: .main), systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(service.state == .starting || terminal.isWorking)
                    .accessibilityIdentifier("refreshLocalSessions")
                    .help(String(localized: "Refresh sessions and hosts", bundle: .main))
            }
        }
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            newSession: canCreateSession ? { creatingSession = true } : nil,
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
        ))
        .modifier(SSHPresentations(model: ssh, ui: sshUI))
        .sheet(isPresented: $creatingSession) {
            NewLocalSessionSheet { name in
                guard let client = service.client else { return }
                terminal.create(name: name, using: client)
            }
        }
        .sheet(item: $renamingSession) { session in
            NewLocalSessionSheet(renaming: session.name) { name in
                guard let client = service.client, name != session.name else { return }
                terminal.rename(session, to: name, using: client)
            }
        }
        .sheet(item: $continuing) { request in
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
        .task { await refresh() }
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
        // SSH sessions own their renderers and stay connected across selection.
        guard case .local(let id) = new, let client = service.client else { return }
        terminal.select(id, using: client)
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
                if ssh.profiles.isEmpty {
                    Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus", action: sshUI.presentNew)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("addSSHHostSidebar")
                    Button(String(localized: "Import from SSH Config…", bundle: .main), systemImage: "square.and.arrow.down", action: sshUI.presentImport)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sshImportHosts")
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, prompt: String(localized: "Search Sessions and Hosts", bundle: .main))
        // Native selection: the row fills with the tint behind white text, so
        // the sidebar keeps the system accent rather than the app's ink.
        .tint(Color.accentColor)
        .navigationTitle("Witerm")
        .safeAreaInset(edge: .bottom, spacing: 0) { serverFooter }
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
                    }
                }
                .disabled(terminal.isWorking)
            }
            if terminal.sessions.isEmpty {
                Button(String(localized: "New Terminal Session…", bundle: .main), systemImage: "plus") { creatingSession = true }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(footerTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(footerStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        .task { remoteAccess.load() }
        .onChange(of: terminal.relays) { remoteAccess.load() }
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
    private var footerRemoteState: MacRemoteAccessState? {
        guard let server = servers.selected, server.phase.isAvailable else { return nil }
        return MacRemoteAccessState(enabled: remoteAccess.isEnabled(for: server.address),
                                    serviceReady: service.state == .ready, relays: terminal.relays,
                                    address: server.address)
    }

    private var footerStatus: String {
        guard let server = servers.selected else { return String(localized: "Not Set Up", bundle: .main) }
        switch footerRemoteState {
        case nil: return server.statusTitle
        case .off?: return String(localized: "Remote access off · Reachable", bundle: .main)
        case .serviceOff?: return String(localized: "Remote access on · Local terminal off", bundle: .main)
        case .connecting?: return String(localized: "Remote access on · Connecting…", bundle: .main)
        case .ready?: return String(localized: "Remote access on · Online", bundle: .main)
        }
    }

    private var footerSymbol: String {
        switch footerRemoteState {
        case .serviceOff?, .connecting?: footerRemoteState?.systemImage ?? "server.rack"
        default: servers.selected?.statusSymbol ?? "server.rack"
        }
    }

    private var footerTint: Color {
        if let state = footerRemoteState, state == .serviceOff || state == .connecting {
            return state == .serviceOff ? WitermTheme.warning : .secondary
        }
        switch servers.selected?.statusTone ?? .neutral {
        case .positive: return WitermTheme.positive
        case .warning: return WitermTheme.warning
        case .neutral: return .secondary
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .local?:
            LocalTerminalDetail(service: service, model: terminal, endSession: { endingSession = $0 },
                                renameSession: { renamingSession = $0 })
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
                      newSession: { creatingSession = true }, newSSHConnection: sshUI.presentNew)
    }
}
#endif
