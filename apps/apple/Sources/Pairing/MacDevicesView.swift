#if os(macOS)
import SwiftUI

/// Remote access and device pairing for this Mac through one server.
struct MacDevicesView: View {
    let service: LocalAgentService
    /// Nil when no server is saved yet.
    let server: ConnectionModel?
    /// Opens with a fresh invitation, as the main window's Pair command does.
    var startsInvitation = false
    @Environment(ServerList.self) private var servers

    var body: some View {
        Group {
            if let connection = server {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !startsInvitation {
                            Text(String(localized: "Pair iPhone and iPad, choose what they may do, and revoke access at any time.", bundle: .main))
                                .font(.subheadline)
                                .foregroundStyle(WitermTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            MacRemoteAccessCard(serverAddress: connection.address, service: service)
                                .id(connection.address)
                        }
                        if connection.supportsPairing {
                            DevicePairingView(serverAddress: connection.address, presentation: .embedded, startsInvitation: startsInvitation)
                                .id(connection.address)
                        } else {
                            pairingUnavailable(connection)
                        }
                        // Pairing first; remote access is what makes it useful.
                        if startsInvitation {
                            MacRemoteAccessCard(serverAddress: connection.address, service: service)
                                .id(connection.address)
                        }
                    }
                    .readableContent(padding: 32)
                }
            } else {
                ContentUnavailableView {
                    Label(String(localized: "Set Up a Server", bundle: .main), systemImage: "server.rack")
                } description: {
                    Text(String(localized: "Pairing and remote access use your Witerm server. Add its address in Settings.", bundle: .main))
                } actions: {
                    SettingsLink {
                        Text(String(localized: "Open Settings", bundle: .main))
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .witermControl()
                    .accessibilityIdentifier("openServerSettings")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WitermTheme.canvas)
        .navigationTitle(title)
    }

    private var title: String {
        if startsInvitation { return String(localized: "Pair iPhone or iPad", bundle: .main) }
        guard let server, servers.servers.count > 1 else { return String(localized: "Paired Devices", bundle: .main) }
        return String(localized: "Paired Devices, \(server.displayName)", bundle: .main)
    }

    @ViewBuilder
    private func pairingUnavailable(_ connection: ConnectionModel) -> some View {
        switch connection.phase {
        case .checking:
            ActivityRow(String(localized: "Checking connection…", bundle: .main), cancel: connection.cancel)
                .witermCard(padding: 16)
        case .failed(let issue):
            IssueBanner(issue.title, message: issue.recovery) {
                HStack(spacing: 12) {
                    Button(String(localized: "Check Again", bundle: .main), action: connection.check)
                    SettingsLink { Text(String(localized: "Open Settings", bundle: .main)) }
                }
            }
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Check the server connection to pair devices.", bundle: .main))
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
                PrimaryButton(String(localized: "Check Connection", bundle: .main), action: connection.check)
            }
            .witermCard()
        case .available:
            Text(String(localized: "This server does not offer device pairing.", bundle: .main))
                .font(.subheadline)
                .foregroundStyle(WitermTheme.secondary)
                .witermCard()
        }
    }
}

/// Pairing from the main window: opens straight to a new invitation's QR
/// code, with remote access and paired devices on the same page.
struct MacPairDeviceSheet: View {
    let service: LocalAgentService
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var serverID: ConnectionModel.ID?

    private var server: ConnectionModel? { servers.server(id: serverID) ?? servers.servers.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if servers.servers.count > 1 {
                    Picker(String(localized: "Server", bundle: .main), selection: Binding(
                        get: { server?.id }, set: { serverID = $0 })) {
                        ForEach(servers.servers) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                }
                MacDevicesView(service: service, server: server, startsInvitation: true)
                    .id(server?.id)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", bundle: .main)) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("closePairing")
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 680)
    }
}
#endif
