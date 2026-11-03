#if os(iOS)
import SwiftUI
import WitermCore
import WitermSSH

private enum MobileTab: Hashable {
    case terminals, devices, settings
}

/// Terminals to open, the devices they run on, and Settings. Terminals are
/// organized by what a person wants to reopen, not by how it is reached.
struct MobileWorkspaceView: View {
    @State private var tab = MobileTab.terminals
    @State private var ssh = SSHWorkspaceModel()
    @State private var sshUI = SSHWorkspaceUI()
    @State private var macs = RemoteModels()
    /// The server whose selected Mac fills the Terminals tab.
    @State private var activeServerID: ConnectionModel.ID?
    @State private var loaded = false
    @State private var continuing: ContinueFlowRequest?
    /// The Welcome Tour: shown once on first launch, again from Settings → Help.
    @State private var touring = false
    @Environment(ServerList.self) private var servers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// A Mac chosen in Terminals, while its sessions or terminal are shown.
    private var activeMac: RemoteTerminalModel? {
        guard let server = servers.server(id: activeServerID), server.supportsRelay,
              let model = macs.existing(for: server),
              model.selectedGrant != nil || model.displayAttachment != nil else { return nil }
        return model
    }

    var body: some View {
        Group {
            if loaded { workspace } else { ProgressView() }
        }
        .task {
            await ssh.load()
            guard !Task.isCancelled else { return }
            loaded = true
        }
    }

    private func continueFromDevice() { continuing = ContinueFlowRequest() }

    /// `openingSole` attaches at once when the device allows one session.
    private func openMac(_ server: ConnectionModel, _ grant: DeviceGrant, openingSole: Bool = false) {
        let model = macs.model(for: server)
        // Just approved: a device listing that started meanwhile mustn't keep
        // the session from opening.
        if openingSole, model.busy != nil { model.cancelWork() }
        guard model.busy == nil else { return }
        sshUI.show(nil)
        model.select(grant, openingSole: openingSole)
        activeServerID = server.id
        tab = .terminals
    }

    private func openHost(_ profile: SSHProfile) {
        tab = .terminals
        activeServerID = nil
        if ssh.session(for: profile.id) != nil { sshUI.show(profile.id) } else { sshUI.open(profile, model: ssh) }
    }

    private var home: some View {
        TerminalsHome(ssh: ssh, ui: sshUI, macs: macs, openMac: { openMac($0, $1, openingSole: true) },
                      continueFromDevice: continueFromDevice)
    }

    /// On iPhone a stack that the terminal replaces; on a regular width the
    /// split view is the tab's root and any terminal, SSH or paired, sits
    /// beside the list.
    @ViewBuilder private var terminalsTab: some View {
        if sizeClass == .regular {
            SSHWorkspaceView(model: ssh, ui: sshUI, remote: activeMac.map { AnyView(RemoteTerminalWorkspace(model: $0)) }) { home }
        } else {
            NavigationStack {
                if let activeMac {
                    RemoteTerminalWorkspace(model: activeMac)
                } else {
                    SSHWorkspaceView(model: ssh, ui: sshUI) { home }
                }
            }
        }
    }

    /// The shown terminal's own commands for the hardware keyboard.
    private var shownSSH: SSHSession? { activeMac == nil ? sshUI.shownID.flatMap(ssh.session(for:)) : nil }
    private var shownMac: RemoteTerminalModel? { activeMac.flatMap { $0.isInteractive ? $0 : nil } }

    /// What ⌘1–⌘9 and ⇧⌘] / ⇧⌘[ step through, in the Terminal menu's order:
    /// the terminals of the paired device open here, then connected SSH hosts.
    private enum OpenTerminal: Equatable {
        case paired(String)
        case ssh(UUID)
    }

    private var openTerminals: [(terminal: OpenTerminal, name: String)] {
        let paired = activeMac.map { model in model.sessions.map { (OpenTerminal.paired($0.id), $0.name) } } ?? []
        let hosts = ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil }.map { (OpenTerminal.ssh($0.id), $0.name) }
        return paired + hosts
    }

    private var currentTerminal: OpenTerminal? {
        if let model = activeMac { return model.displayAttachment.map { .paired($0.session.id) } }
        return sshUI.shownID.flatMap { ssh.session(for: $0) != nil ? .ssh($0) : nil }
    }

    /// A paired terminal switches through the same detach-then-attach as the
    /// title's switcher; an SSH host is shown as it is.
    private func show(_ terminal: OpenTerminal) {
        guard terminal != currentTerminal else { return }
        tab = .terminals
        switch terminal {
        case .paired(let id):
            guard let model = activeMac, model.busy == nil, let session = model.sessions.first(where: { $0.id == id }) else { return }
            model.attach(session)
        case .ssh(let id):
            activeServerID = nil
            sshUI.requestedSession = id
        }
    }

    private var workspace: some View {
        TabView(selection: $tab) {
            terminalsTab
            .tabItem { Label(String(localized: "Terminals", bundle: .main), systemImage: WitermSymbols.sshHost) }
            .tag(MobileTab.terminals)
            DevicesView(ssh: ssh, ui: sshUI, macs: macs, openMac: { openMac($0, $1) }, openHost: openHost,
                        continueFromDevice: continueFromDevice)
                .tabItem { Label(String(localized: "Devices", bundle: .main), systemImage: WitermSymbols.openOn) }
                .tag(MobileTab.devices)
            MobileSettingsView(showTour: { touring = true })
                .tabItem { Label(String(localized: "Settings", bundle: .main), systemImage: "gearshape") }
                .tag(MobileTab.settings)
        }
        .witermTint()
        .modifier(SSHPresentations(model: ssh, ui: sshUI, showsUndo: false))
        // Finishing lands on Terminals, where the first connection starts.
        .modifier(IOSWelcomeTourPresentation(touring: $touring) { tab = .terminals })
        .sheet(item: $continuing) { request in
            ContinueFromDeviceFlow(invitation: request.invitation) { server, grant in
                openMac(server, grant, openingSole: true)
            }
        }
        // From a server address that turned out to be an SSH login, or an invitation.
        .onReceive(NotificationCenter.default.publisher(for: .witermAddSSHHost)) { note in
            tab = .terminals
            activeServerID = nil
            sshUI.presentNewWhenVisible(address: note.object as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .witermUseInvitation)) { note in
            continuing = ContinueFlowRequest(invitation: note.object as? String)
        }
        // Hardware-keyboard commands; the iPad lists them while ⌘ is held.
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            newSSHConnection: { sshUI.presentNewWhenVisible() },
            importSSHHosts: { sshUI.importing = true },
            refresh: {
                servers.servers.forEach { $0.check() }
                Task { await ssh.load() }
            },
            terminalNames: openTerminals.map(\.name),
            showTerminal: { index in
                let open = openTerminals
                guard open.indices.contains(index) else { return }
                show(open[index].terminal)
            },
            // ⇧⌘] and ⇧⌘[ step through open terminals, wrapping around.
            showAdjacentTerminal: { step in
                let open = openTerminals
                guard !open.isEmpty else { return }
                let current = open.firstIndex { $0.terminal == currentTerminal } ?? (step > 0 ? -1 : 0)
                show(open[(current + step + open.count) % open.count].terminal)
            },
            // A paired terminal this device may type in: ⇧⌘T switches, as on the Mac.
            typingHere: shownMac.flatMap { $0.canRequestControl ? $0.mode == .control : nil },
            setTyping: shownMac.flatMap { model in model.canRequestControl ? { _ in model.switchMode() } : nil },
            leave: shownMac.map { model in { model.showSessions() } },
            disconnect: shownSSH.map { session in { ssh.disconnect(session) } },
            find: shownSSH != nil || shownMac != nil ? { NotificationCenter.default.post(name: .witermFindInTerminal, object: nil) } : nil,
            findStep: shownSSH != nil || shownMac != nil ? { NotificationCenter.default.post(name: .witermFindStep, object: $0) } : nil
        ))
        // A connection someone just started is shown in Terminals, from any tab.
        .onChange(of: ssh.connectingProfile?.id) { _, id in
            guard id != nil else { return }
            activeServerID = nil
            tab = .terminals
        }
        // Paired Macs are listed in both Terminals and Machines.
        .task(id: servers.relayServers.map(\.id)) { macs.loadNew(servers.relayServers) }
        .onChange(of: servers.servers.map(\.id)) { macs.prune(keeping: servers.servers) }
        // Only the background interrupts a terminal. Control Center, the app
        // switcher, and system prompts make the app briefly inactive, and
        // must not cost the connection.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                macs.enterForeground()
                macs.loadNew(servers.relayServers)
            } else if phase == .background {
                macs.enterBackground()
            }
            // SSH sessions survive tab switches but never the background.
            if phase == .background { ssh.disconnectAll(forBackground: true) }
        }
    }
}

/// A short index in three groups: how the terminal looks, how you type, and
/// where connections go. Details and actions live one tap away.
private struct MobileSettingsView: View {
    /// Reopens the Welcome Tour.
    let showTour: () -> Void
    @Environment(ServerList.self) private var servers
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system
    @AppStorage(MobileKey.key) private var keys = ""
    @AppStorage(CommandSnippets.key) private var snippets = Data()
    @AppStorage(TerminalBell.key) private var bell = true

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Appearance", bundle: .main)) {
                    NavigationLink {
                        Form { TerminalDisplaySections() }
                            .formStyle(.grouped)
                            .navigationTitle(String(localized: "Text and Colors", bundle: .main))
                    } label: {
                        LabeledContent(String(localized: "Text and Colors", bundle: .main),
                                       value: String(localized: "\(Int(fontSize)) pt · \(palette.title)", bundle: .main))
                    }
                    .accessibilityIdentifier("settingsDisplay")
                    NavigationLink {
                        Form { TerminalFeedbackSections() }
                            .formStyle(.grouped)
                            .navigationTitle(String(localized: "Bell and VoiceOver", bundle: .main))
                    } label: {
                        LabeledContent(String(localized: "Bell and VoiceOver", bundle: .main),
                                       value: bell ? String(localized: "Bell On", bundle: .main) : String(localized: "Bell Off", bundle: .main))
                    }
                    .accessibilityIdentifier("settingsFeedback")
                }

                Section(String(localized: "Keyboard", bundle: .main)) {
                    NavigationLink { MobileKeyRowSettings() } label: {
                        LabeledContent(String(localized: "Keyboard Row", bundle: .main),
                                       value: String(localized: "\(MobileKey.decode(keys).count) keys", bundle: .main))
                    }
                    .accessibilityIdentifier("mobileKeyRowSettings")
                    NavigationLink { SnippetSettingsView() } label: {
                        LabeledContent(String(localized: "Snippets", bundle: .main),
                                       value: String(localized: "\(CommandSnippets.decode(snippets).count) saved", bundle: .main))
                    }
                    .accessibilityIdentifier("snippetSettings")
                }

                Section {
                    NavigationLink { ServersPage() } label: {
                        LabeledContent {
                            if !servers.servers.isEmpty {
                                StatusBadge(servers.summaryStatus, systemImage: servers.summarySymbol, tone: servers.summaryTone)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                                Text(String(localized: "Relay Servers", bundle: .main))
                                Text(servers.servers.count == 1 ? servers.servers[0].displayName : servers.summaryTitle)
                                    .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("settingsServers")
                } header: {
                    Text(String(localized: "Connections", bundle: .main))
                }

                Section(String(localized: "Help", bundle: .main)) {
                    Button(action: showTour) {
                        ContentActionLabel(String(localized: "Welcome Tour", bundle: .main), systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("settingsWelcomeTour")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Settings", bundle: .main))
        }
    }
}

/// Every saved server, one row each with its status; each opens its own page.
private struct ServersPage: View {
    @Environment(ServerList.self) private var servers
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editing: ServerEditRequest?

    var body: some View {
        Form {
            Section {
                ForEach(Array(servers.servers.enumerated()), id: \.element.id) { index, server in
                    NavigationLink {
                        ServerSettingsPage(server: server, edit: { editing = .edit(server) })
                    } label: {
                        let badge = StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                        if typeSize.isAccessibilitySize {
                            // The name, which identifies the server, wraps
                            // whole; the status goes under it.
                            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                                AddressText(server.displayName, lines: 0, style: .body, monospaced: false,
                                            color: UIColor(named: "Ink") ?? .label)
                                badge
                            }
                        } else {
                            LabeledContent {
                                badge
                            } label: {
                                Text(server.displayName).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .accessibilityIdentifier("settingsServerRow-\(index)")
                }
                Button { editing = .add } label: {
                    ContentActionLabel(String(localized: "Add Relay Server", bundle: .main), systemImage: "plus")
                }
                    .disabled(servers.isFull)
                    .accessibilityIdentifier(servers.servers.isEmpty ? "settingsEditServer" : "settingsAddServer")
            } footer: {
                if servers.isFull { Text(ServerList.Failure.full.message) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Relay Servers", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .serverEditor($editing)
    }
}

/// One server's status and actions. Confirms its own removal, since an alert
/// can only come from the page on screen, and leaves once the server is gone.
private struct ServerSettingsPage: View {
    let server: ConnectionModel
    let edit: () -> Void
    @State private var confirmingRemoval = false
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form { ServerSettingsSection(server: server, edit: edit, remove: { confirmingRemoval = true }) }
            .formStyle(.grouped)
            .alert(String(localized: "Remove Relay Server?", bundle: .main), isPresented: $confirmingRemoval) {
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
                Button(String(localized: "Remove", bundle: .main), role: .destructive) { servers.remove(server) }
            } message: {
                Text(String(localized: "Devices paired through this relay server stop appearing here. They stay paired.", bundle: .main))
            }
            .navigationTitle(server.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: servers.servers.map(\.id)) { _, ids in
                if !ids.contains(server.id) { dismiss() }
            }
    }
}

/// One saved server: where it is, whether it answers, and its actions.
/// The status is stated once, by the feedback row; removal sits apart.
private struct ServerSettingsSection: View {
    let server: ConnectionModel
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        Section {
            LabeledContent(String(localized: "Address", bundle: .main)) {
                Text(server.address)
                    .font(WitermType.code)
                    .foregroundStyle(WitermTheme.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            ConnectionFeedback(server: server)
                .accessibilityIdentifier("settingsConnectionFeedback")
            if server.phase.isChecking {
                Button(action: server.cancel) {
                    ContentActionLabel(String(localized: "Cancel Check", bundle: .main), systemImage: "xmark")
                }
                .accessibilityIdentifier("cancelConnection")
            } else {
                Button(action: server.check) {
                    ContentActionLabel(String(localized: "Check Connection", bundle: .main), systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("settingsCheckConnection")
            }
        }
        Section {
            Button(action: edit) {
                ContentActionLabel(String(localized: "Edit Address", bundle: .main), systemImage: "pencil")
            }
            .accessibilityIdentifier("settingsEditServer")
        }
        Section {
            Button(role: .destructive, action: remove) {
                Label(String(localized: "Remove Relay Server…", bundle: .main), systemImage: "trash").fontWeight(.semibold)
            }
            .accessibilityIdentifier("settingsRemoveServer")
        }
    }
}
#endif
