#if os(iOS)
import SwiftUI
import WitermCore
import WitermSSH

enum MachinesRoute: Hashable { case macSetup }

/// Managing the machines terminals run on: paired Macs and pairing, and saved
/// SSH hosts. Opening a machine's terminal happens in Terminals.
struct MachinesView: View {
    let ssh: SSHWorkspaceModel
    let ui: SSHWorkspaceUI
    let macs: RemoteModels
    @Binding var path: [MachinesRoute]
    let openMac: (ConnectionModel, DeviceGrant) -> Void
    let openHost: (SSHProfile) -> Void
    @Environment(ServerList.self) private var servers
    @State private var placeholder = ConnectionModel(address: "")
    @State private var pairingServer: ConnectionModel?
    @State private var inspected: Inspected?
    @State private var search = ""
    @State private var joiningSession = false

    private struct Inspected: Identifiable {
        let server: ConnectionModel
        let grant: DeviceGrant
        var id: String { grant.id }
    }

    /// Mac access needs a server that offers remote terminals; until one is
    /// checked, the Macs section leads to setup.
    static func needsSetup(_ servers: ServerList) -> Bool {
        servers.servers.isEmpty || (servers.servers.count == 1 && !servers.servers[0].supportsRelay)
    }

    private var showsSearch: Bool { ssh.profiles.count >= TerminalsHome.filterThreshold }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if Self.needsSetup(servers) {
                    Section(String(localized: "Macs", bundle: .main)) {
                        NavigationLink(value: MachinesRoute.macSetup) {
                            rowLabel(String(localized: "Set Up Mac Access", bundle: .main),
                                     detail: String(localized: "Needs Witerm on the Mac and a Witerm server", bundle: .main),
                                     symbol: "desktopcomputer")
                        }
                        .accessibilityIdentifier("machinesMacSetup")
                        openSharedSessionButton
                    }
                } else {
                    ForEach(servers.servers) { server in
                        Section {
                            macRows(server)
                        } header: {
                            if servers.servers.count > 1 {
                                HStack(spacing: 8) {
                                    Text(server.displayName).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                                        .textCase(nil)
                                }
                                .accessibilityElement(children: .combine)
                            } else {
                                Text(String(localized: "Macs", bundle: .main))
                            }
                        }
                    }
                }
                Section(String(localized: "SSH Hosts", bundle: .main)) {
                    ForEach(ssh.orderedProfiles(search: search)) { profile in hostRow(profile) }
                    Button(String(localized: "Add Host", bundle: .main), systemImage: "plus", action: ui.presentNew)
                        .disabled(ssh.connecting)
                        .accessibilityIdentifier("machinesAddHost")
                    Button(String(localized: "Import from SSH Config…", bundle: .main), systemImage: "square.and.arrow.down", action: ui.presentImport)
                        .accessibilityIdentifier("machinesImportHosts")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(WitermTheme.canvas)
            .modifier(HostSearch(enabled: showsSearch, text: $search))
            // Pull down to check servers and list paired Macs again.
            .refreshable {
                refreshAll()
                while servers.relayServers.contains(where: { macs.existing(for: $0)?.busy != nil }), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            .navigationTitle(String(localized: "Machines", bundle: .main))
            .navigationDestination(for: MachinesRoute.self) { route in
                switch route {
                case .macSetup:
                    ServerSetupView(model: servers.servers.first ?? placeholder) {
                        path = []
                        ui.presentNew()
                    }
                }
            }
            .overlay(alignment: .bottom) { SSHUndoRemovalBar(model: ssh) }
        }
        // Setup is done once a server offers remote terminals; its Macs show here.
        .onChange(of: Self.needsSetup(servers)) { _, needed in if !needed { path = [] } }
        .sheet(item: $pairingServer, onDismiss: refreshAll) { server in
            DevicePairingView(serverAddress: server.address).id(server.address)
        }
        .sheet(isPresented: $joiningSession) {
            JoinSessionView { server, grant in openMac(server, grant) }
        }
        .sheet(item: $inspected) { item in
            MacDeviceDetails(server: item.server, grant: item.grant) { inspected = nil }
        }
    }

    private var openSharedSessionButton: some View {
        Button(String(localized: "Open Shared Session…", bundle: .main), systemImage: "qrcode.viewfinder") { joiningSession = true }
            .accessibilityIdentifier("openSharedSession")
    }

    private func refreshAll() {
        servers.servers.forEach { $0.check() }
        for server in servers.relayServers { macs.model(for: server).loadDevices() }
    }

    // MARK: Macs

    @ViewBuilder
    private func macRows(_ server: ConnectionModel) -> some View {
        if server.supportsRelay {
            let model = macs.model(for: server)
            if let busy = model.busy {
                ActivityRow(busy) { model.cancelWork() }
                    .accessibilityIdentifier("remoteTerminalActivity")
            }
            if let issue = model.issue {
                IssueBanner(issue.title, message: issue.recovery, systemImage: "exclamationmark.shield.fill")
                    .accessibilityIdentifier("remoteTerminalError")
            }
            ForEach(model.grants) { grant in
                HStack(spacing: 4) {
                    Button { openMac(server, grant) } label: {
                        HStack(spacing: 14) {
                            IconTile(systemImage: "desktopcomputer", tint: grant.host.identityHue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(grant.host.name).foregroundStyle(WitermTheme.ink)
                                StatusBadge(grant.permission == .view ? String(localized: "View Only", bundle: .main) : String(localized: "Can Type", bundle: .main),
                                            systemImage: grant.permission == .view ? "eye" : "keyboard")
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy != nil)
                    .accessibilityHint(String(localized: "Shows this Mac's terminal sessions.", bundle: .main))
                    Button(String(localized: "Device Details", bundle: .main), systemImage: "info.circle") {
                        inspected = Inspected(server: server, grant: grant)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .touchTarget(square: true)
                    .accessibilityLabel(String(localized: "Details for \(grant.host.name)", bundle: .main))
                }
            }
            if model.loaded, model.grants.isEmpty, model.busy == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "No Macs Yet", bundle: .main)).font(.headline)
                    Text(String(localized: "Pair with your Mac to open its terminals here, or open one session someone shares with you.", bundle: .main))
                        .font(.subheadline)
                        .foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("remoteDevicesEmpty")
            }
            Button(model.grants.isEmpty ? String(localized: "Pair a Mac", bundle: .main) : String(localized: "Pair Another Mac", bundle: .main),
                   systemImage: "link") { pairingServer = server }
                .accessibilityIdentifier("devicePairing")
            // Joining one shared session sits with the Macs; it needs no pairing.
            if server.id == servers.relayServers.first?.id { openSharedSessionButton }
        } else {
            switch server.phase {
            case .available:
                Text(String(localized: "This server does not offer remote terminals.", bundle: .main))
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
            case .checking, .idle, .failed:
                ConnectionFeedback(server: server)
                if !server.phase.isChecking {
                    Button(String(localized: "Check Again", bundle: .main), action: server.check)
                }
            }
        }
    }

    // MARK: SSH hosts

    private func hostRow(_ profile: SSHProfile) -> some View {
        let session = ssh.session(for: profile.id)
        return HStack(spacing: 4) {
            Button { openHost(profile) } label: {
                SSHHostRowContent(profile: profile, active: session != nil, expanded: true, favorite: ssh.isFavorite(profile),
                                  activity: session?.activity)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("machineHost-\(profile.id.uuidString)")
            .accessibilityLabel(profile.name)
            .accessibilityValue(profile.accessibilitySummary
                + (session == nil ? "" : String(localized: ", connected", bundle: .main))
                + (ssh.isFavorite(profile) ? String(localized: ", favorite", bundle: .main) : ""))
            .accessibilityHint(String(localized: "Opens its terminal in Terminals.", bundle: .main))
            SSHHostActions(profile: profile, ssh: ssh, ui: ui)
                .accessibilityIdentifier("machineHostActions-\(profile.id.uuidString)")
        }
    }

    private func rowLabel(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            IconTile(systemImage: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(WitermTheme.ink)
                Text(detail).font(.caption).foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
