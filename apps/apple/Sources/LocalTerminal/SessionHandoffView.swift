#if os(macOS)
import SwiftUI
import WitermCore

/// Preparation for one existing session. Every grant, relay and sharing state
/// belongs to the selected server or the live session; no permission is implied.
struct SessionHandoffView: View {
    let service: LocalAgentService
    @Bindable var terminal: LocalTerminalModel
    let sessionID: String
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var serverID: ConnectionModel.ID?
    @State private var editing: ServerEditRequest?
    @State private var remoteAccess = MacRemoteAccessModel()
    @State private var grants: [DeviceGrant] = []

    private var server: ConnectionModel? { servers.server(id: serverID) }
    private var session: LocalSessionInfo? { terminal.sessions.first { $0.id == sessionID } }
    private var paired: Bool { !grants.isEmpty }
    private var relayReady: Bool {
        guard let server, remoteAccess.isEnabled(for: server.address) else { return false }
        return terminal.relays.contains { ServerAddressKey($0.server) == ServerAddressKey(server.address) && $0.state == .ready }
    }
    private var serverReady: Bool { server?.phase.isAvailable == true && server?.supportsRelay == true }
    private var ready: Bool { serverReady && paired && relayReady && session?.sharing?.shared == true && service.state == .ready }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session {
                        Text(session.name).font(.title2.weight(.semibold))
                        readiness
                        serverSetup
                        if let server {
                            MacRemoteAccessCard(serverAddress: server.address, service: service, model: remoteAccess)
                                .id(server.address)
                            if server.supportsRelay && server.supportsPairing {
                                DisclosureGroup(String(localized: "Pair or Manage Devices", bundle: .main), isExpanded: Binding(
                                    get: { !paired || pairingExpanded }, set: { pairingExpanded = $0 })) {
                                    DevicePairingView(serverAddress: server.address, presentation: .embedded) { grants = $0 }
                                        .id(server.address)
                                        .padding(.top, 12)
                                }
                                sharing(session)
                            }
                        }
                        if let issue = terminal.issue { IssueBanner(issue.title, message: issue.recovery) }
                    } else {
                        ContentUnavailableView(String(localized: "Session Ended", bundle: .main), systemImage: "terminal")
                    }
                }
                .readableContent()
            }
            .background(WitermTheme.canvas)
            .navigationTitle(String(localized: "Continue on iPhone", bundle: .main))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", bundle: .main)) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .serverEditor($editing)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 700)
        .task { serverID = servers.servers.first?.id }
        .onChange(of: servers.servers.map(\.id)) { _, _ in
            if server == nil { serverID = servers.servers.first?.id }
        }
        .onChange(of: server?.address) { _, _ in grants = []; pairingExpanded = false; remoteAccess.load() }
    }

    @State private var pairingExpanded = false

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(ready ? String(localized: "Ready to Open on iPhone", bundle: .main) : String(localized: "Prepare This Session", bundle: .main),
                  systemImage: ready ? "checkmark.circle.fill" : "iphone.and.arrow.forward")
                .font(.headline)
                .accessibilityIdentifier("handoffReadiness")
            step(String(localized: "Server connection", bundle: .main), complete: serverReady)
            step(String(localized: "Device paired", bundle: .main), complete: paired)
            step(String(localized: "Remote access ready", bundle: .main), complete: relayReady)
            step(String(localized: "Session shared", bundle: .main), complete: session?.sharing?.shared == true)
            if ready {
                Text(String(localized: "On your iPhone or iPad, open Devices, choose this Mac, then choose this session.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .witermCard()
    }

    private func step(_ title: String, complete: Bool) -> some View {
        HStack {
            Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
            Spacer()
            Text(complete ? String(localized: "Ready", bundle: .main) : String(localized: "Not Ready", bundle: .main))
                .foregroundStyle(WitermTheme.secondary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var serverSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !servers.servers.isEmpty {
                Picker(String(localized: "Server", bundle: .main), selection: $serverID) {
                    ForEach(servers.servers) { server in Text(server.displayName).tag(Optional(server.id)) }
                }
            }
            if let server {
                ConnectionFeedback(server: server)
                if !server.phase.isAvailable || !server.supportsRelay {
                    if server.phase.isAvailable {
                        Text(String(localized: "This server does not offer remote terminals.", bundle: .main))
                    }
                    HStack {
                        Button(String(localized: "Edit Address", bundle: .main)) { editing = .edit(server) }
                        Button(String(localized: "Check Connection", bundle: .main), action: server.check)
                            .disabled(server.phase.isChecking)
                    }
                }
            } else {
                Text(String(localized: "Add the same Witerm server on this Mac and your iPhone or iPad.", bundle: .main))
                PrimaryButton(String(localized: "Add Server", bundle: .main)) { editing = .add }
            }
        }
        .witermCard()
    }

    private func sharing(_ session: LocalSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(String(localized: "Share This Session", bundle: .main), isOn: Binding(
                get: { self.session?.sharing?.shared == true },
                set: { shared in
                    if let client = service.client { terminal.setShared(session, shared, using: client) }
                }))
                .disabled(service.state != .ready)
                .accessibilityIdentifier("handoffShareSession")
            Text(String(localized: "Paired devices use the view or control access you approved. Stopping sharing disconnects them.", bundle: .main))
                .font(.subheadline).foregroundStyle(WitermTheme.secondary)
            if ready, grants.contains(where: { $0.permission == .control }),
               terminal.selectedID == session.id, terminal.attachment != nil, terminal.mode == .control {
                Text(String(localized: "This Mac currently has control. Release it before typing from your iPhone or iPad.", bundle: .main))
                    .font(.subheadline)
                Button(String(localized: "Release This Mac’s Control", bundle: .main)) {
                    if let client = service.client { terminal.attach(session, using: client, mode: .view) }
                }
                .disabled(terminal.isWorking)
                .accessibilityIdentifier("handoffReleaseControl")
            }
        }
        .witermCard()
    }
}
#endif
