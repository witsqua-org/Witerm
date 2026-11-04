#if os(iOS)
import SwiftUI
import WitermCore
import WitermSSH

private enum MobileTab: Hashable {
    case terminals, devices, settings
}

/// Terminals to open, the devices they run on, and Settings. Every function
/// has one place: terminals and SSH hosts in Terminals, devices and relay
/// servers in Devices, preferences in Settings.
struct MobileWorkspaceView: View {
    @State private var tab = MobileTab.terminals
    @State private var ssh = SSHWorkspaceModel()
    @State private var sshUI = SSHWorkspaceUI()
    @State private var macs = RemoteModels()
    /// The server whose paired terminal fills the Terminals tab.
    @State private var activeServerID: ConnectionModel.ID?
    @State private var loaded = false
    @State private var continuing: ContinueFlowRequest?
    /// The Welcome Tour: shown once on first launch, again from Settings → Help.
    @State private var touring = false
    @Environment(ServerList.self) private var servers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The relay server whose paired terminal is on screen. Terminals lists
    /// every device's terminals itself, so the paired workspace shows only
    /// while a terminal (or its kept last frame) is displayed.
    private var activeMac: RemoteTerminalModel? {
        guard let server = servers.server(id: activeServerID), server.supportsRelay,
              let model = macs.existing(for: server), model.displayAttachment != nil else { return nil }
        return model
    }

    var body: some View {
        Group {
            if loaded { workspace } else { ProgressView() }
        }
        .task {
            #if DEBUG
            RemoteFixture.cleanUpIfAsked()
            if RemoteFixture.isActive { _ = FixtureMac.shared }
            #endif
            await ssh.load()
            guard !Task.isCancelled else { return }
            loaded = true
        }
    }

    private func continueFromDevice() { continuing = ContinueFlowRequest() }

    /// After Add Device: attaches at once when the device allows one
    /// terminal; otherwise its terminals are listed in its section.
    private func openApproved(_ server: ConnectionModel, _ grant: DeviceGrant) {
        let model = macs.model(for: server)
        // Just approved: a device listing that started meanwhile mustn't keep
        // the terminal from opening.
        if model.busy != nil { model.cancelWork() }
        leaveOtherServer(than: server)
        sshUI.show(nil)
        model.select(grant, openingSole: true)
        activeServerID = server.id
        tab = .terminals
    }

    /// Opens one of a device's terminals from the list. Within one relay
    /// server, the model detaches any open terminal and waits for that ACK
    /// before attaching.
    private func openTerminal(_ server: ConnectionModel, _ grant: DeviceGrant, _ session: LocalSessionInfo,
                              mode: LocalAttachmentMode?) {
        let model = macs.model(for: server)
        guard model.busy == nil else { return }
        tab = .terminals
        if activeServerID == server.id, model.selectedGrant?.id == grant.id,
           model.displayAttachment?.session.id == session.id, mode == nil {
            sshUI.show(nil)
            return
        }
        leaveOtherServer(than: server)
        sshUI.show(nil)
        model.open(session, on: grant, mode: mode)
        activeServerID = server.id
    }

    /// A paired terminal through another relay server stays connected, off
    /// screen (Round 18), before this one is shown.
    private func leaveOtherServer(than server: ConnectionModel) {
        guard let id = activeServerID, id != server.id, let other = servers.server(id: id),
              let model = macs.existing(for: other), model.displayAttachment != nil else { return }
        model.leaveKeepingConnection()
    }

    /// Something else takes the Terminals tab (an SSH host): the paired
    /// terminal on screen stays connected, as after Back.
    private func setPairedTerminalAside() {
        activeMac?.leaveKeepingConnection()
        activeServerID = nil
    }

    private var home: some View {
        TerminalsHome(ssh: ssh, ui: sshUI, macs: macs, openTerminal: { openTerminal($0, $1, $2, mode: $3) })
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

    /// What ⌘1–⌘9 and ⇧⌘] / ⇧⌘[ step through, in the list's order: each
    /// paired device's terminals, terminals shared with you, then connected
    /// SSH hosts.
    private enum OpenTerminal: Equatable {
        case paired(server: ConnectionModel.ID, grant: String, session: String)
        case ssh(UUID)
    }

    private var openTerminals: [(terminal: OpenTerminal, name: String)] {
        let sections = TerminalsHome.sections(servers: servers, macs: macs)
        let paired = (sections.paired + sections.shared).flatMap { section in
            section.terminals.map { (OpenTerminal.paired(server: section.server.id, grant: section.grant.id, session: $0.id), $0.name) }
        }
        let hosts = ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil }.map { (OpenTerminal.ssh($0.id), $0.name) }
        return paired + hosts
    }

    private var currentTerminal: OpenTerminal? {
        if let model = activeMac, let id = activeServerID, let grant = model.selectedGrant {
            return model.displayAttachment.map { .paired(server: id, grant: grant.id, session: $0.session.id) }
        }
        return sshUI.shownID.flatMap { ssh.session(for: $0) != nil ? .ssh($0) : nil }
    }

    /// A paired terminal opens through the same detach-then-attach as any
    /// switch; an SSH host is shown as it is.
    private func show(_ terminal: OpenTerminal) {
        guard terminal != currentTerminal else { return }
        tab = .terminals
        switch terminal {
        case .paired(let serverID, let grantID, let sessionID):
            let sections = TerminalsHome.sections(servers: servers, macs: macs)
            guard let section = (sections.paired + sections.shared).first(where: { $0.server.id == serverID && $0.grant.id == grantID }),
                  let session = section.terminals.first(where: { $0.id == sessionID }) else { return }
            openTerminal(section.server, section.grant, session, mode: nil)
        case .ssh(let id):
            setPairedTerminalAside()
            sshUI.requestedSession = id
        }
    }

    private var workspace: some View {
        TabView(selection: $tab) {
            terminalsTab
            .tabItem { Label(String(localized: "Terminals", bundle: .main), systemImage: WitermSymbols.sshHost) }
            .tag(MobileTab.terminals)
            DevicesView(macs: macs, continueFromDevice: continueFromDevice)
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
                openApproved(server, grant)
            }
        }
        // From a server address that turned out to be an SSH login, or an invitation.
        .onReceive(NotificationCenter.default.publisher(for: .witermAddSSHHost)) { note in
            tab = .terminals
            setPairedTerminalAside()
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
                servers.relayServers.forEach { macs.existing(for: $0)?.listTerminals() }
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
            // No Start or Stop Typing (⇧⌘T) on iPhone and iPad: the keyboard
            // button and Hide Keyboard are the switch. One Disconnect for
            // paired and SSH terminals alike (Round 18); no Leave.
            disconnect: shownMac.map { model in { model.disconnect() } } ?? shownSSH.map { session in { ssh.disconnect(session) } },
            find: shownSSH != nil || shownMac != nil ? { NotificationCenter.default.post(name: .witermFindInTerminal, object: nil) } : nil,
            findStep: shownSSH != nil || shownMac != nil ? { NotificationCenter.default.post(name: .witermFindStep, object: $0) } : nil
        ))
        // A connection someone just started is shown in Terminals, from any tab.
        .onChange(of: ssh.connectingProfile?.id) { _, id in
            guard id != nil else { return }
            setPairedTerminalAside()
            tab = .terminals
        }
        // An SSH terminal chosen beside a paired one (iPad) takes its place;
        // the paired one stays connected.
        .onChange(of: sshUI.shownID) { _, id in
            if id != nil, activeMac != nil { setPairedTerminalAside() }
        }
        // Back from a paired terminal: its device's list may have changed.
        .onChange(of: activeMac == nil) { _, none in
            if none { servers.relayServers.forEach { macs.existing(for: $0)?.listTerminals() } }
        }
        // Paired devices are listed in both Terminals and Devices.
        .task(id: servers.relayServers.map(\.id)) { macs.loadNew(servers.relayServers) }
        .onChange(of: servers.servers.map(\.id)) { macs.prune(keeping: servers.servers) }
        // Only the background interrupts a terminal. Control Center, the app
        // switcher, and system prompts make the app briefly inactive, and
        // must not cost the connection.
        .onChange(of: scenePhase) { _, phase in
            // Paired and SSH terminals are kept for 3 minutes in the
            // background, then let go (Round 17).
            if phase == .active {
                macs.enterForeground()
                macs.loadNew(servers.relayServers)
                ssh.enterForeground()
            } else if phase == .background {
                macs.enterBackground()
                ssh.enterBackground()
            }
        }
    }
}

/// Frequent preferences first, by category, then Advanced for what is set
/// once if ever. Relay servers live in Devices.
private struct MobileSettingsView: View {
    /// Reopens the Welcome Tour.
    let showTour: () -> Void
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system
    @AppStorage(CommandSnippets.key) private var snippets = Data()
    @AppStorage(TerminalAnnounceOutput.key) private var announceOutput = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var textAndColorsShown = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Terminal", bundle: .main)) {
                    // Text size and colors together, collapsed to their
                    // current values until opened.
                    DisclosureGroup(isExpanded: $textAndColorsShown) {
                        TerminalTextAndColorsRows()
                    } label: {
                        // On the label: on the group it would replace the
                        // rows' own identifiers.
                        LabeledContent(String(localized: "Text and Colors", bundle: .main),
                                       value: String(localized: "\(Int(fontSize)) pt · \(palette.title)", bundle: .main))
                            .accessibilityIdentifier("settingsDisplay")
                    }
                    NavigationLink { SnippetSettingsView() } label: {
                        LabeledContent(String(localized: "Snippets", bundle: .main),
                                       value: String(localized: "\(CommandSnippets.decode(snippets).count) saved", bundle: .main))
                    }
                    .accessibilityIdentifier("snippetSettings")
                    // While VoiceOver runs, here rather than in Advanced.
                    if TerminalAnnounceOutput.inMainList(voiceOver: voiceOver) {
                        Toggle(String(localized: "Announce New Output", bundle: .main), isOn: $announceOutput).witermSwitchTint()
                            .accessibilityIdentifier("terminalAnnounceOutput")
                    }
                }

                Section(String(localized: "Help", bundle: .main)) {
                    Button(action: showTour) {
                        ContentActionLabel(String(localized: "Welcome Tour", bundle: .main), systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("settingsWelcomeTour")
                }

                Section {
                    NavigationLink { AdvancedSettingsView() } label: {
                        Text(String(localized: "Advanced", bundle: .main))
                    }
                    .accessibilityIdentifier("settingsAdvanced")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Settings", bundle: .main))
        }
    }
}

/// What most people set once, if ever: terminal contrast (which also
/// follows the system's Increase Contrast), the key row, the bell, and
/// VoiceOver announcements. Each keeps its own header to stay findable.
private struct AdvancedSettingsView: View {
    @AppStorage("witerm.terminalHighContrast") private var highContrast = false
    @AppStorage(MobileKey.key) private var keys = ""
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        Form {
            Section(String(localized: "Appearance", bundle: .main)) {
                Toggle(String(localized: "Increase Terminal Contrast", bundle: .main), isOn: $highContrast).witermSwitchTint()
                    .accessibilityIdentifier("terminalHighContrast")
            }
            Section(String(localized: "Keyboard", bundle: .main)) {
                NavigationLink { MobileKeyRowSettings() } label: {
                    LabeledContent(String(localized: "Keyboard Row", bundle: .main),
                                   value: String(localized: "\(MobileKey.decode(keys).count) keys", bundle: .main))
                }
                .accessibilityIdentifier("mobileKeyRowSettings")
            }
            TerminalFeedbackSections(includesAnnounce: !TerminalAnnounceOutput.inMainList(voiceOver: voiceOver))
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Advanced", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
