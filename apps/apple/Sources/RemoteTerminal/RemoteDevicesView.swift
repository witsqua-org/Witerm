#if os(iOS)
import SwiftUI
import WitermCore

/// One remote-terminal model per saved server, kept across view updates. A
/// server whose address changes gets a fresh model, because grants and
/// identities belong to an address.
@MainActor
final class RemoteModels {
    private var models: [ConnectionModel.ID: RemoteTerminalModel] = [:]

    func model(for server: ConnectionModel) -> RemoteTerminalModel {
        if let model = models[server.id], model.serverAddress == server.address { return model }
        models[server.id]?.suspend()
        let model = RemoteTerminalModel(serverAddress: server.address)
        models[server.id] = model
        return model
    }

    func existing(for server: ConnectionModel) -> RemoteTerminalModel? {
        models[server.id].flatMap { $0.serverAddress == server.address ? $0 : nil }
    }

    /// Stops and forgets models whose server was removed.
    func prune(keeping servers: [ConnectionModel]) {
        let kept = Set(servers.map(\.id))
        for (id, model) in models where !kept.contains(id) {
            model.suspend()
            models[id] = nil
        }
    }
}

/// The Devices tab once servers are set up: paired devices from every saved
/// server, grouped by server. Selecting a device opens its sessions.
struct RemoteDevicesView: View {
    @Environment(ServerList.self) private var servers
    @Environment(\.scenePhase) private var scenePhase
    @State private var models = RemoteModels()
    @State private var activeServerID: ConnectionModel.ID?
    @State private var pairingServer: ConnectionModel?

    private var active: RemoteTerminalModel? {
        guard let server = servers.server(id: activeServerID), server.supportsRelay,
              let model = models.existing(for: server),
              model.selectedGrant != nil || model.displayAttachment != nil else { return nil }
        return model
    }

    var body: some View {
        Group {
            if let active {
                RemoteTerminalWorkspace(model: active)
            } else {
                home
            }
        }
        .onChange(of: servers.servers.map(\.id)) { models.prune(keeping: servers.servers) }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(servers.servers) { server in
                    ServerDevicesSection(server: server, model: server.supportsRelay ? models.model(for: server) : nil,
                                         showsHeader: servers.servers.count > 1,
                                         open: { activeServerID = server.id },
                                         pair: { pairingServer = server })
                }
            }
            .padding(.horizontal, WitermMetrics.pagePadding)
            .padding(.vertical, 12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(WitermTheme.canvas)
        .navigationTitle(String(localized: "Devices", bundle: .main))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Refresh", bundle: .main), systemImage: "arrow.clockwise", action: refreshAll)
                    .accessibilityIdentifier("refreshRemoteSessions")
            }
        }
        .task(id: servers.relayServers.map(\.id)) { loadNew() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loadNew() }
            else { servers.relayServers.forEach { models.existing(for: $0)?.suspend() } }
        }
        .sheet(item: $pairingServer, onDismiss: refreshAll) { server in
            DevicePairingView(serverAddress: server.address).id(server.address)
        }
    }

    /// Loads devices for relay servers that have not been listed yet, or
    /// whose listing was cancelled.
    private func loadNew() {
        for server in servers.relayServers {
            let model = models.model(for: server)
            if !model.loaded, model.busy == nil { model.loadDevices() }
        }
    }

    private func refreshAll() {
        servers.servers.forEach { $0.check() }
        for server in servers.relayServers { models.model(for: server).loadDevices() }
    }
}

/// One server's devices, or why there are none yet.
private struct ServerDevicesSection: View {
    let server: ConnectionModel
    let model: RemoteTerminalModel?
    let showsHeader: Bool
    let open: () -> Void
    let pair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader { header }
            if let model {
                devices(model)
            } else {
                unavailable
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(WitermTheme.secondary)
                .accessibilityHidden(true)
            Text(server.displayName)
                .font(.headline)
                .foregroundStyle(WitermTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func devices(_ model: RemoteTerminalModel) -> some View {
        if let busy = model.busy {
            ActivityRow(busy) { model.cancelWork() }
                .accessibilityIdentifier("remoteTerminalActivity")
        }
        if let issue = model.issue {
            IssueBanner(issue.title, message: issue.recovery, systemImage: "exclamationmark.shield.fill")
                .accessibilityIdentifier("remoteTerminalError")
        }
        ForEach(model.grants) { grant in
            Button {
                model.select(grant)
                open()
            } label: {
                HStack(spacing: 14) {
                    IconTile(systemImage: "desktopcomputer", tint: grant.host.identityHue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(grant.host.name).font(.headline).foregroundStyle(WitermTheme.ink)
                        StatusBadge(grant.permission == .view ? String(localized: "Read-Only Permission", bundle: .main) : String(localized: "Control Permission", bundle: .main),
                                    systemImage: grant.permission == .view ? "eye" : "keyboard")
                        Text(PairingFingerprint.display(publicKey: grant.host.publicKey))
                            .font(.caption.monospaced())
                            .foregroundStyle(WitermTheme.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(WitermTheme.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .witermCard(padding: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy != nil)
            .accessibilityIdentifier("remoteMac-\(grant.id)")
        }
        if model.loaded, model.grants.isEmpty, model.busy == nil {
            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "No Paired Devices Yet", bundle: .main), systemImage: "desktopcomputer")
                    .font(.headline)
                Text(String(localized: "Pair with another device to open its terminal sessions here.", bundle: .main))
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(String(localized: "Pair a Device", bundle: .main), systemImage: "link", action: pair)
                    .accessibilityIdentifier("devicePairing")
            }
            .witermCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("remoteDevicesEmpty")
        }
    }

    @ViewBuilder
    private var unavailable: some View {
        switch server.phase {
        case .available:
            Text(String(localized: "This server does not offer remote terminals.", bundle: .main))
                .font(.subheadline)
                .foregroundStyle(WitermTheme.secondary)
                .witermCard()
        case .checking, .idle, .failed:
            VStack(alignment: .leading, spacing: 12) {
                ConnectionFeedback(server: server)
                if !server.phase.isChecking {
                    Button(String(localized: "Check Again", bundle: .main), action: server.check)
                        .touchTarget()
                }
            }
            .witermCard()
        }
    }
}
#endif
