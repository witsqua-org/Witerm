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
    @Environment(ServerList.self) private var servers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

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

    private var workspace: some View {
        TabView(selection: $tab) {
            NavigationStack {
                if let activeMac {
                    RemoteTerminalWorkspace(model: activeMac)
                } else {
                    SSHWorkspaceView(model: ssh, ui: sshUI) {
                        TerminalsHome(ssh: ssh, ui: sshUI, macs: macs, openMac: { openMac($0, $1) },
                                      continueFromDevice: continueFromDevice)
                    }
                }
            }
            .tabItem { Label(String(localized: "Terminals", bundle: .main), systemImage: "terminal") }
            .tag(MobileTab.terminals)
            DevicesView(ssh: ssh, ui: sshUI, macs: macs, openMac: { openMac($0, $1) }, openHost: openHost,
                        continueFromDevice: continueFromDevice)
                .tabItem { Label(String(localized: "Devices", bundle: .main), systemImage: "laptopcomputer.and.iphone") }
                .tag(MobileTab.devices)
            MobileSettingsView()
                .tabItem { Label(String(localized: "Settings", bundle: .main), systemImage: "gearshape") }
                .tag(MobileTab.settings)
        }
        .witermTint()
        .modifier(SSHPresentations(model: ssh, ui: sshUI, showsUndo: false))
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
            terminalNames: ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil }.map(\.name),
            showTerminal: { index in
                let open = ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil }
                guard open.indices.contains(index) else { return }
                tab = .terminals
                activeServerID = nil
                sshUI.requestedSession = open[index].id
            }
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

                Section(String(localized: "Typing", bundle: .main)) {
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Continuation Servers", bundle: .main))
                                Text(servers.servers.count == 1 ? servers.servers[0].displayName : servers.summaryTitle).font(.caption).foregroundStyle(WitermTheme.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("settingsServers")
                } header: {
                    Text(String(localized: "Connections", bundle: .main))
                } footer: {
                    Text(String(localized: "Your devices reach each other through these servers. SSH hosts connect directly.", bundle: .main))
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
    @State private var editing: ServerEditRequest?

    var body: some View {
        Form {
            Section {
                ForEach(Array(servers.servers.enumerated()), id: \.element.id) { index, server in
                    NavigationLink {
                        ServerSettingsPage(server: server, edit: { editing = .edit(server) })
                    } label: {
                        LabeledContent {
                            StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                        } label: {
                            Text(server.displayName).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .accessibilityIdentifier("settingsServerRow-\(index)")
                }
                Button(String(localized: "Add Server", bundle: .main), systemImage: "plus") { editing = .add }
                    .disabled(servers.isFull)
                    .accessibilityIdentifier(servers.servers.isEmpty ? "settingsEditServer" : "settingsAddServer")
            } footer: {
                Text(servers.isFull
                     ? ServerList.Failure.full.message
                     : String(localized: "Your devices reach each other through these servers, all at once. SSH hosts connect directly.", bundle: .main))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Continuation Servers", bundle: .main))
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
            .alert(String(localized: "Remove Server?", bundle: .main), isPresented: $confirmingRemoval) {
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
                Button(String(localized: "Remove", bundle: .main), role: .destructive) { servers.remove(server) }
            } message: {
                Text(String(localized: "Devices paired through this server stop appearing here. Pairings on the server are not revoked.", bundle: .main))
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
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(WitermTheme.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            ConnectionFeedback(server: server)
                .accessibilityIdentifier("settingsConnectionFeedback")
            if server.phase.isChecking {
                Button(String(localized: "Cancel Check", bundle: .main), action: server.cancel)
                    .accessibilityIdentifier("cancelConnection")
            } else {
                Button(String(localized: "Check Connection", bundle: .main), action: server.check)
                    .accessibilityIdentifier("settingsCheckConnection")
            }
        }
        Section {
            Button(String(localized: "Edit Address", bundle: .main), action: edit)
                .accessibilityIdentifier("settingsEditServer")
        }
        Section {
            Button(String(localized: "Remove Server", bundle: .main), role: .destructive, action: remove)
                .accessibilityIdentifier("settingsRemoveServer")
        }
    }
}
#endif
