#if os(macOS)
import SwiftUI

/// Remote access and device pairing for this Mac through one server.
struct MacDevicesView: View {
    let service: LocalAgentService
    /// Nil when no server is saved yet.
    let server: ConnectionModel?
    @Environment(ServerList.self) private var servers

    var body: some View {
        Group {
            if let connection = server {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(String(localized: "Pair iPhone and iPad, choose what they may do, and revoke access at any time.", bundle: .main))
                            .font(.subheadline)
                            .foregroundStyle(WitermTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        MacRemoteAccessCard(serverAddress: connection.address, service: service)
                            .id(connection.address)
                        if connection.supportsPairing {
                            DevicePairingView(serverAddress: connection.address, presentation: .embedded)
                                .id(connection.address)
                        } else {
                            pairingUnavailable(connection)
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
#endif
