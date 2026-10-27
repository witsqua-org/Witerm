#if os(macOS)
import SwiftUI

/// The selected Settings tab. Other views set it before opening Settings to
/// land on a specific tab.
enum SettingsTab: String {
    case general, terminal, commandLine
    static let key = "witerm.settingsTab"
}

struct MacSettingsView: View {
    let service: LocalAgentService
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            MacGeneralSettings(service: service)
                .frame(width: 560, height: 560)
                .tabItem { Label(String(localized: "General", bundle: .main), systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            Form { TerminalAppearanceSections() }
                .formStyle(.grouped)
                .frame(width: 560, height: 580)
                .tabItem { Label(String(localized: "Terminal", bundle: .main), systemImage: "terminal") }
                .tag(SettingsTab.terminal.rawValue)
            CommandLineToolSettings()
                .frame(width: 560, height: 560)
                .tabItem { Label(String(localized: "Command Line", bundle: .main), systemImage: "apple.terminal") }
                .tag(SettingsTab.commandLine.rawValue)
        }
        .witermTint()
    }
}

private struct MacGeneralSettings: View {
    let service: LocalAgentService
    @Environment(ServerList.self) private var servers
    @State private var editing: ServerEditRequest?
    @State private var removing: ConnectionModel?
    @State private var removalBlocked = false
    @State private var stopping = false

    var body: some View {
        Form {
            ForEach(servers.servers) { server in
                MacServerSection(server: server, titled: servers.servers.count > 1,
                                 edit: { editing = .edit(server) }, remove: { removing = server })
            }

            Section {
                HStack {
                    Button(String(localized: "Add Server…", bundle: .main)) { editing = .add }
                        .disabled(servers.isFull)
                        .accessibilityIdentifier(servers.servers.isEmpty ? "serverSettings" : "addServer")
                    Spacer()
                }
            } header: {
                if servers.servers.isEmpty { Text(String(localized: "Server", bundle: .main)) }
            } footer: {
                Text(servers.isFull
                     ? ServerList.Failure.full.message
                     : String(localized: "Pairing and remote access use these servers, all at once. Direct SSH does not.", bundle: .main))
                    .foregroundStyle(WitermTheme.secondary)
            }

            Section(String(localized: "Local Terminal", bundle: .main)) {
                LabeledContent(String(localized: "Background Service", bundle: .main), value: serviceStatus)
                HStack {
                    switch service.state {
                    case .ready:
                        Button(String(localized: "Disable Local Terminal…", bundle: .main), role: .destructive) { stopping = true }
                    case .requiresApproval:
                        Button(String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
                    case .starting:
                        ProgressView().controlSize(.small)
                    case .notRegistered, .unavailable:
                        Button(String(localized: "Enable Local Terminal", bundle: .main)) { Task { await service.start() } }
                    }
                    Spacer()
                    if service.state != .requiresApproval {
                        Button(String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
                    }
                }
                if let issue = service.issue {
                    Text(issue).font(.subheadline).foregroundStyle(WitermTheme.warning)
                }
            }
        }
        .formStyle(.grouped)
        .serverEditor($editing)
        .task { await service.refresh() }
        .alert(String(localized: "Remove Server?", bundle: .main), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Remove", bundle: .main), role: .destructive) {
                guard let server = removing else { return }
                do {
                    try MacRemoteAccessModel.forget(serverAddress: server.address)
                    servers.remove(server)
                } catch { removalBlocked = true }
            }
        } message: {
            Text(String(localized: "This Mac stops accepting remote access through this server. Pairings on the server are not revoked.", bundle: .main))
        }
        .alert(String(localized: "Unable to Remove Server", bundle: .main), isPresented: $removalBlocked) {
            Button(String(localized: "OK", bundle: .main), role: .cancel) {}
        } message: {
            Text(String(localized: "Remote access settings could not be updated. Try again.", bundle: .main))
        }
        .alert(String(localized: "Disable Local Terminal?", bundle: .main), isPresented: $stopping) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Disable", bundle: .main), role: .destructive) {
                Task { await service.stop() }
            }
        } message: {
            Text(String(localized: "The current terminal connection will be disconnected.", bundle: .main))
        }
    }

    private var serviceStatus: String {
        switch service.state {
        case .ready: String(localized: "On", bundle: .main)
        case .starting: String(localized: "Enabling local terminal…", bundle: .main)
        case .requiresApproval: String(localized: "Waiting for background approval", bundle: .main)
        case .notRegistered: String(localized: "Off", bundle: .main)
        case .unavailable: String(localized: "Local Terminal Unavailable", bundle: .main)
        }
    }
}
#endif

#if os(macOS)
/// One saved server: where it is, whether it answers, and its actions.
private struct MacServerSection: View {
    let server: ConnectionModel
    let titled: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        Section {
            LabeledContent(String(localized: "Address", bundle: .main)) {
                Text(server.address)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(WitermTheme.ink)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(String(localized: "Status", bundle: .main)) {
                StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                    .accessibilityIdentifier("connectionStatus")
            }
            ConnectionFeedback(server: server)
                .accessibilityIdentifier("connectionFeedback")
            HStack {
                Button(String(localized: "Edit Address…", bundle: .main), action: edit)
                    .accessibilityIdentifier("serverSettings")
                Button(String(localized: "Remove…", bundle: .main), role: .destructive, action: remove)
                    .accessibilityIdentifier("removeServer")
                Spacer()
                if server.phase.isChecking {
                    Button(String(localized: "Cancel Check", bundle: .main), action: server.cancel)
                        .accessibilityIdentifier("cancelConnection")
                } else {
                    Button(String(localized: "Check Connection", bundle: .main), action: server.check)
                        .accessibilityIdentifier("primaryAction")
                }
            }
        } header: {
            Text(titled ? server.displayName : String(localized: "Server", bundle: .main))
        }
    }
}
#endif
