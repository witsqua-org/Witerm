#if os(iOS)
import SwiftUI
import WitermCore

/// Devices and the relay servers they pair through, and nothing else:
/// Add Device first, then paired devices, then relay servers. Their
/// terminals open from Terminals; SSH hosts live there too.
struct DevicesView: View {
    let macs: RemoteModels
    /// Opens Add Device.
    let continueFromDevice: () -> Void
    @Environment(ServerList.self) private var servers
    @Environment(NetworkStatus.self) private var network: NetworkStatus?
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A confirmation after unpairing, since the row just disappears. It
    /// stays until the next visit to this tab.
    @State private var unpairedNote: String?
    /// A device whose Unpair… was chosen by swipe or long press, while its
    /// confirmation shows.
    @State private var confirmingUnpair: DeviceRow?
    @State private var unpairFailure: String?
    @State private var removingServer: ConnectionModel?
    @State private var editing: ServerEditRequest?

    /// One paired device on one relay server.
    struct DeviceRow: Identifiable {
        let server: ConnectionModel
        let grant: DeviceGrant
        let model: RemoteTerminalModel
        var id: String { "\(server.id.uuidString)-\(grant.id)" }
    }

    private var rows: [DeviceRow] {
        servers.relayServers.flatMap { server in
            let model = macs.model(for: server)
            return model.pairedDevices.map { DeviceRow(server: server, grant: $0, model: model) }
        }
    }

    /// Relay servers listing their devices, or that couldn't.
    private var serverWork: [RemoteTerminalModel] {
        servers.relayServers.compactMap { macs.existing(for: $0) }.filter { $0.busy != nil || $0.issue != nil }
    }

    private var offline: Bool { network?.online == false }

    /// Names the device the app runs on, as the vocabulary allows.
    private var thisDevice: String {
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad", bundle: .main)
            : String(localized: "This iPhone", bundle: .main)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: continueFromDevice) {
                        HStack(spacing: WitermMetrics.Space.m) {
                            IconTile(systemImage: WitermSymbols.openOn)
                            Text(String(localized: "Add Device", bundle: .main))
                                .font(WitermType.rowTitle.weight(.semibold)).foregroundStyle(WitermTheme.ink)
                            Spacer(minLength: WitermMetrics.Space.s)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(WitermTheme.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("continueFromDevice")
                }
                if let unpairedNote {
                    Section {
                        Label(unpairedNote, systemImage: "checkmark.circle")
                            .font(WitermType.rowDetail)
                            .foregroundStyle(WitermTheme.secondary)
                            .accessibilityIdentifier("unpairedNote")
                    }
                }
                pairedDevices
                relayServers
            }
            .listStyle(.insetGrouped)
            .onDisappear { unpairedNote = nil; unpairFailure = nil }
            // Pull down to check servers and list paired devices again.
            .refreshable {
                refreshAll()
                while servers.relayServers.contains(where: { macs.existing(for: $0)?.busy != nil }), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            .navigationTitle(String(localized: "Devices", bundle: .main))
            .serverEditor($editing)
            .alert(String(localized: "Unpair from “\(confirmingUnpair?.grant.host.name ?? "")”?", bundle: .main),
                   isPresented: Binding(get: { confirmingUnpair != nil }, set: { if !$0 { confirmingUnpair = nil } }),
                   presenting: confirmingUnpair) { row in
                Button(String(localized: "Unpair", bundle: .main), role: .destructive) { unpair(row) }
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "\(thisDevice) can no longer open its terminals. To use them again, pair again.", bundle: .main))
            }
            .alert(String(localized: "Remove Relay Server?", bundle: .main),
                   isPresented: Binding(get: { removingServer != nil }, set: { if !$0 { removingServer = nil } }),
                   presenting: removingServer) { server in
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
                Button(String(localized: "Remove", bundle: .main), role: .destructive) { servers.remove(server) }
            } message: { _ in
                Text(String(localized: "Devices paired through this relay server stop appearing here. They stay paired.", bundle: .main))
            }
        }
    }

    private func refreshAll() {
        servers.servers.forEach { $0.check() }
        for server in servers.relayServers { macs.model(for: server).loadDevices() }
    }

    // MARK: Paired devices

    /// One row per device and relay server, however many pairings it has.
    /// A row opens the device's page; its terminals open in Terminals.
    private var pairedDevices: some View {
        Section {
            ForEach(serverWork, id: \.serverAddress) { model in
                if let busy = model.busy {
                    ActivityRow(busy) { model.cancelWork() }
                        .accessibilityIdentifier("remoteTerminalActivity")
                }
                if let issue = model.issue {
                    IssueBanner(issue.title, message: issue.recovery, systemImage: WitermSymbols.unpaired)
                        .accessibilityIdentifier("remoteTerminalError")
                }
            }
            if rows.isEmpty, serverWork.isEmpty {
                Text(String(localized: "Devices you add appear here.", bundle: .main))
                    .font(WitermType.rowDetail)
                    .foregroundStyle(WitermTheme.secondary)
                    .accessibilityIdentifier("remoteDevicesEmpty")
            }
            ForEach(rows) { row in deviceRow(row) }
        } header: {
            Text(String(localized: "Paired Devices", bundle: .main))
        } footer: {
            if let unpairFailure {
                Text(unpairFailure).foregroundStyle(WitermTheme.warning)
                    .accessibilityIdentifier("unpairFailure")
            }
        }
    }

    private func deviceRow(_ row: DeviceRow) -> some View {
        let unpairing = row.model.unpairingID == row.grant.id
        return NavigationLink {
            MacDeviceDetails(server: row.server, grant: row.grant, model: row.model) {
                unpairedNote = String(localized: "Unpaired from \(row.grant.host.name)", bundle: .main)
            }
        } label: {
            HStack(spacing: WitermMetrics.Space.m) {
                IconTile(systemImage: row.grant.host.platform == .macos ? "laptopcomputer" : "iphone", tint: row.grant.host.identityHue)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(row.grant.host.name).font(WitermType.rowTitle).foregroundStyle(WitermTheme.ink)
                    // What this device may do there, and through which
                    // relay server when there are several.
                    let access = row.grant.permission == .view ? String(localized: "Can only watch", bundle: .main)
                        : String(localized: "Can watch and type", bundle: .main)
                    Text(unpairing ? String(localized: "Unpairing…", bundle: .main)
                         : servers.servers.count > 1 ? "\(access) · \(row.server.displayName)" : access)
                        .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1).truncationMode(.middle)
                }
            }
        }
        .disabled(row.model.busy != nil || unpairing)
        .accessibilityIdentifier("deviceDetails-\(row.grant.host.id)")
        // Unpairing can't be undone, so a swipe only asks: never a full
        // swipe, and never while offline, when it can't reach the server.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !offline, !unpairing {
                Button(String(localized: "Unpair…", bundle: .main), systemImage: WitermSymbols.pair) { confirmingUnpair = row }
                    .tint(.red)
            }
        }
        .contextMenu {
            Button(String(localized: "Unpair…", bundle: .main), systemImage: WitermSymbols.pair, role: .destructive) { confirmingUnpair = row }
                .disabled(offline || unpairing)
        }
    }

    private func unpair(_ row: DeviceRow) {
        unpairFailure = nil
        Task {
            do {
                try await row.model.unpair(row.grant)
                unpairedNote = String(localized: "Unpaired from \(row.grant.host.name)", bundle: .main)
            } catch {
                let failure = PairingIssue(error)
                unpairFailure = String(localized: "\(failure.title). \(thisDevice) no longer opens its terminals, but the relay server wasn’t told. Try again, or unpair on the other device.", bundle: .main)
            }
        }
    }

    // MARK: Relay servers

    /// Every saved relay server with its status; each opens its own page.
    private var relayServers: some View {
        Section {
            ForEach(Array(servers.servers.enumerated()), id: \.element.id) { index, server in
                NavigationLink {
                    ServerSettingsPage(server: server, edit: { editing = .edit(server) })
                } label: {
                    serverLabel(server)
                }
                .accessibilityIdentifier("settingsServerRow-\(index)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(String(localized: "Remove…", bundle: .main), systemImage: "trash") { removingServer = server }
                        .tint(.red)
                }
                .contextMenu {
                    Button(String(localized: "Check Connection", bundle: .main), systemImage: "arrow.clockwise", action: server.check)
                        .disabled(server.phase.isChecking)
                    Button(String(localized: "Edit Address", bundle: .main), systemImage: "pencil") { editing = .edit(server) }
                    Divider()
                    Button(String(localized: "Remove Relay Server…", bundle: .main), systemImage: "trash", role: .destructive) {
                        removingServer = server
                    }
                }
            }
            Button { editing = .add } label: {
                ContentActionLabel(String(localized: "Add Relay Server", bundle: .main), systemImage: "plus")
            }
            .disabled(servers.isFull)
            .accessibilityIdentifier(servers.servers.isEmpty ? "settingsEditServer" : "settingsAddServer")
        } header: {
            Text(String(localized: "Relay Servers", bundle: .main))
        } footer: {
            if servers.isFull { Text(ServerList.Failure.full.message) }
        }
    }

    @ViewBuilder private func serverLabel(_ server: ConnectionModel) -> some View {
        let badge = StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
        if typeSize.isAccessibilitySize {
            // The name, which identifies the server, wraps whole; the
            // status goes under it.
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                AddressText(server.displayName, lines: 0, style: .body, monospaced: false,
                            color: UIColor(named: "Ink") ?? .label)
                badge
            }
        } else {
            HStack(spacing: WitermMetrics.Space.m) {
                IconTile(systemImage: WitermSymbols.relayServer)
                LabeledContent {
                    badge
                } label: {
                    Text(server.displayName).lineLimit(1).truncationMode(.middle)
                }
            }
        }
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
