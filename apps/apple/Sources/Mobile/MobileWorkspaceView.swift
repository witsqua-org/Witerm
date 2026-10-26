#if os(iOS)
import SwiftUI

private enum MobileTab: Hashable {
    case devices, ssh, settings
}

struct MobileWorkspaceView: View {
    @State private var tab = MobileTab.devices
    @State private var ssh = SSHWorkspaceModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            DevicesTab(openSSH: { tab = .ssh })
                .tabItem { Label(String(localized: "Devices", bundle: .main), systemImage: "desktopcomputer") }
                .tag(MobileTab.devices)
            NavigationStack { SSHWorkspaceView(model: ssh) }
                .tabItem { Label("SSH", systemImage: "terminal") }
                .tag(MobileTab.ssh)
            MobileSettingsView()
                .tabItem { Label(String(localized: "Settings", bundle: .main), systemImage: "gearshape") }
                .tag(MobileTab.settings)
        }
        .witermTint()
        // SSH sessions survive tab switches but never the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { ssh.disconnectAll() }
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

private struct MobileSettingsView: View {
    @Environment(ServerList.self) private var servers
    @State private var editing: ServerEditRequest?
    @State private var pairingServer: ConnectionModel?
    @State private var removing: ConnectionModel?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(servers.servers) { server in
                    ServerSettingsSection(server: server, titled: servers.servers.count > 1,
                                          edit: { editing = .edit(server) },
                                          pair: { pairingServer = server },
                                          remove: { removing = server })
                }

                Section {
                    Button(String(localized: "Add Server", bundle: .main), systemImage: "plus") { editing = .add }
                        .disabled(servers.isFull)
                        .accessibilityIdentifier(servers.servers.isEmpty ? "settingsEditServer" : "settingsAddServer")
                } header: {
                    if servers.servers.isEmpty { Text(String(localized: "Server", bundle: .main)) }
                } footer: {
                    Text(servers.isFull
                         ? ServerList.Failure.full.message
                         : String(localized: "Pairing and remote terminals use these servers, all at once. Direct SSH does not.", bundle: .main))
                }

                TerminalAppearanceSections()
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Settings", bundle: .main))
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
}

/// One saved server: where it is, whether it answers, and its actions.
private struct ServerSettingsSection: View {
    let server: ConnectionModel
    let titled: Bool
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
            LabeledContent(String(localized: "Status", bundle: .main)) {
                StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
            }
            ConnectionFeedback(server: server)
                .accessibilityIdentifier("settingsConnectionFeedback")
            if server.phase.isChecking {
                Button(String(localized: "Cancel Check", bundle: .main), action: server.cancel)
            } else {
                Button(String(localized: "Check Connection", bundle: .main), action: server.check)
                    .accessibilityIdentifier("settingsCheckConnection")
            }
            Button(String(localized: "Edit Address", bundle: .main), action: edit)
                .accessibilityIdentifier("settingsEditServer")
            Button(action: pair) {
                Label(String(localized: "Device Pairing", bundle: .main), systemImage: "link")
            }
            .disabled(!server.supportsPairing)
            .accessibilityIdentifier("settingsDevicePairing")
            Button(String(localized: "Remove Server", bundle: .main), role: .destructive, action: remove)
                .accessibilityIdentifier("settingsRemoveServer")
        } header: {
            Text(titled ? server.displayName : String(localized: "Server", bundle: .main))
        } footer: {
            if !server.supportsPairing {
                Text(String(localized: "Check a server that supports pairing to pair devices.", bundle: .main))
            }
        }
    }
}
#endif
