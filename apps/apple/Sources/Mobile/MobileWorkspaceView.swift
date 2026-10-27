#if os(iOS)
import SwiftUI

private enum MobileTab: Hashable {
    case devices, ssh, settings
}

struct MobileWorkspaceView: View {
    @State private var tab = MobileTab.devices
    @State private var ssh = SSHWorkspaceModel()
    @State private var sshUI = SSHWorkspaceUI()
    @State private var loaded = false
    @State private var choosingTask = false
    @AppStorage("witerm.startTask") private var startTask = ""
    @Environment(ServerList.self) private var servers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if choosingTask {
                taskChoice
            } else {
                workspace
            }
        }
        .task {
            await ssh.load()
            guard !Task.isCancelled else { return }
            choosingTask = startTask.isEmpty && servers.servers.isEmpty && ssh.profiles.isEmpty
            if startTask == "ssh" || (startTask.isEmpty && servers.servers.isEmpty && !ssh.profiles.isEmpty) {
                tab = .ssh
            }
            loaded = true
        }
    }

    private var taskChoice: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(String(localized: "What would you like to connect to?", bundle: .main))
                        .font(.title2.weight(.semibold))
                    taskButton(String(localized: "Connect to an SSH Host", bundle: .main),
                               detail: String(localized: "Open a terminal using a host address and your credentials.", bundle: .main),
                               symbol: "terminal", id: "chooseSSH") {
                        startTask = "ssh"
                        tab = .ssh
                        choosingTask = false
                    }
                    taskButton(String(localized: "Continue from My Mac", bundle: .main),
                               detail: String(localized: "Pair with your Mac to open a terminal session it shares.", bundle: .main),
                               symbol: "desktopcomputer", id: "chooseMac") {
                        startTask = "mac"
                        tab = .devices
                        choosingTask = false
                    }
                }
                .readableContent()
            }
            .background(WitermTheme.canvas)
            .navigationTitle("Witerm")
        }
        .witermTint()
    }

    private func taskButton(_ title: String, detail: String, symbol: String, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                if !typeSize.isAccessibilitySize { IconTile(systemImage: symbol) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(WitermTheme.ink)
                    Text(detail).font(.subheadline).foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
            }
            .witermCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var workspace: some View {
        TabView(selection: $tab) {
            DevicesTab(openSSH: { tab = .ssh })
                .tabItem { Label(String(localized: "Devices", bundle: .main), systemImage: "desktopcomputer") }
                .tag(MobileTab.devices)
            NavigationStack { SSHWorkspaceView(model: ssh, ui: sshUI) }
                .tabItem { Label("SSH", systemImage: "terminal") }
                .tag(MobileTab.ssh)
            MobileSettingsView()
                .tabItem { Label(String(localized: "Settings", bundle: .main), systemImage: "gearshape") }
                .tag(MobileTab.settings)
        }
        .witermTint()
        // Hardware-keyboard commands; the iPad lists them while ⌘ is held.
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            newSSHConnection: { tab = .ssh; sshUI.presentNewWhenVisible() },
            importSSHHosts: { tab = .ssh; sshUI.importing = true },
            refresh: {
                servers.servers.forEach { $0.check() }
                Task { await ssh.load() }
            },
            terminalNames: ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil }.map(\.name),
            showTerminal: { index in
                let open = ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil }
                guard open.indices.contains(index) else { return }
                tab = .ssh
                sshUI.requestedSession = open[index].id
            }
        ))
        .onChange(of: tab) { _, tab in
            if tab == .ssh { startTask = "ssh" }
            if tab == .devices { startTask = "mac" }
        }
        // SSH sessions survive tab switches but never the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { ssh.disconnectAll(forBackground: true) }
        }
    }
}

/// Setup while there is no server, or while the only server has not been
/// verified to offer remote terminals; devices from every server after that.
private struct DevicesTab: View {
    let openSSH: () -> Void
    @Environment(ServerList.self) private var servers
    @State private var placeholder = ConnectionModel(address: "")

    var body: some View {
        NavigationStack {
            if servers.servers.isEmpty {
                ServerSetupView(model: placeholder, openSSH: openSSH)
            } else if servers.servers.count == 1, let only = servers.servers.first, !only.supportsRelay {
                ServerSetupView(model: only, openSSH: openSSH)
            } else {
                RemoteDevicesView()
            }
        }
    }
}

/// A short index: servers first, one row each, then terminal preferences.
/// Details and actions live one tap away.
private struct MobileSettingsView: View {
    @Environment(ServerList.self) private var servers
    @State private var editing: ServerEditRequest?
    @State private var pairingServer: ConnectionModel?
    @State private var removing: ConnectionModel?
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system
    @AppStorage(MobileKey.key) private var keys = ""
    @AppStorage(CommandSnippets.key) private var snippets = Data()
    @AppStorage(TerminalBell.key) private var bell = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(servers.servers.enumerated()), id: \.element.id) { index, server in
                        NavigationLink {
                            ServerSettingsPage(server: server, edit: { editing = .edit(server) },
                                               pair: { pairingServer = server }, remove: { removing = server })
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
                } header: {
                    Text(String(localized: "Servers and Pairing", bundle: .main))
                } footer: {
                    Text(servers.isFull
                         ? ServerList.Failure.full.message
                         : String(localized: "Pairing and remote terminals use these servers, all at once. Direct SSH does not.", bundle: .main))
                }

                Section(String(localized: "Terminal", bundle: .main)) {
                    NavigationLink {
                        Form { TerminalDisplaySections() }
                            .formStyle(.grouped)
                            .navigationTitle(String(localized: "Display", bundle: .main))
                    } label: {
                        LabeledContent(String(localized: "Display", bundle: .main),
                                       value: String(localized: "\(Int(fontSize)) pt · \(palette.title)", bundle: .main))
                    }
                    .accessibilityIdentifier("settingsDisplay")
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
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Settings", bundle: .main))
        }
        .serverEditor($editing)
        .sheet(item: $pairingServer) { server in
            DevicePairingView(serverAddress: server.address).id(server.address)
        }
        .alert(String(localized: "Remove Server?", bundle: .main), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Remove", bundle: .main), role: .destructive) {
                if let removing { servers.remove(removing) }
            }
        } message: {
            Text(String(localized: "Devices paired through this server stop appearing here. Pairings on the server are not revoked.", bundle: .main))
        }
    }
}

/// One server's status and actions. Leaves itself once the server is removed.
private struct ServerSettingsPage: View {
    let server: ConnectionModel
    let edit: () -> Void
    let pair: () -> Void
    let remove: () -> Void
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form { ServerSettingsSection(server: server, edit: edit, pair: pair, remove: remove) }
            .formStyle(.grouped)
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
    let pair: () -> Void
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
            } else {
                Button(String(localized: "Check Connection", bundle: .main), action: server.check)
                    .accessibilityIdentifier("settingsCheckConnection")
            }
        }
        Section {
            Button(action: pair) {
                Label(String(localized: "Device Pairing", bundle: .main), systemImage: "link")
            }
            .disabled(!server.supportsPairing)
            .accessibilityIdentifier("settingsDevicePairing")
            Button(String(localized: "Edit Address", bundle: .main), action: edit)
                .accessibilityIdentifier("settingsEditServer")
        } footer: {
            if !server.supportsPairing {
                Text(String(localized: "Check a server that supports pairing to pair devices.", bundle: .main))
            }
        }
        Section {
            Button(String(localized: "Remove Server", bundle: .main), role: .destructive, action: remove)
                .accessibilityIdentifier("settingsRemoveServer")
        }
    }
}
#endif
