#if os(iOS)
import SwiftUI
import WitermCore
import WitermSSH

/// Managing the devices terminals run on: devices paired through a
/// continuation server, and saved SSH hosts. Continuing from another device
/// starts here, and opening a device's terminal happens in Terminals.
struct DevicesView: View {
    let ssh: SSHWorkspaceModel
    let ui: SSHWorkspaceUI
    let macs: RemoteModels
    let openMac: (ConnectionModel, DeviceGrant) -> Void
    let openHost: (SSHProfile) -> Void
    /// Opens Add Device.
    let continueFromDevice: () -> Void
    @Environment(ServerList.self) private var servers
    /// A confirmation after unpairing, since the row just disappears. It
    /// stays until the next visit to this tab.
    @State private var unpairedNote: String?
    @State private var search = ""

    private var showsSearch: Bool { ssh.profiles.count >= TerminalsHome.filterThreshold }

    /// Servers with paired devices or something to say about them.
    private var deviceServers: [ConnectionModel] {
        servers.servers.filter { server in
            guard server.supportsRelay else { return server.statusTone == .warning }
            let model = macs.existing(for: server)
            return !(model?.grants.isEmpty ?? true) || model?.issue != nil || model?.busy != nil
        }
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
                if deviceServers.isEmpty {
                    Section(String(localized: "Paired Devices", bundle: .main)) {
                        Text(String(localized: "Devices you add appear here.", bundle: .main))
                            .font(WitermType.rowDetail)
                            .foregroundStyle(WitermTheme.secondary)
                            .accessibilityIdentifier("remoteDevicesEmpty")
                    }
                } else {
                    ForEach(deviceServers) { server in
                        Section {
                            deviceRows(server)
                        } header: {
                            if servers.servers.count > 1 {
                                HStack(spacing: WitermMetrics.Space.s) {
                                    Text(String(localized: "Paired Devices · \(server.displayName)", bundle: .main))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: WitermMetrics.Space.s)
                                    StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                                        .textCase(nil)
                                }
                                .accessibilityElement(children: .combine)
                            } else {
                                Text(String(localized: "Paired Devices", bundle: .main))
                            }
                        }
                    }
                }
                Section(String(localized: "SSH Hosts", bundle: .main)) {
                    ForEach(ssh.orderedProfiles(search: search)) { profile in hostRow(profile) }
                    Button(action: ui.presentNew) {
                        ContentActionLabel(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus")
                    }
                    .disabled(ssh.connecting)
                    .accessibilityIdentifier("machinesAddHost")
                    Button(action: ui.presentImport) {
                        ContentActionLabel(String(localized: "Import SSH Hosts…", bundle: .main), systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("machinesImportHosts")
                }
            }
            .listStyle(.insetGrouped)
            .modifier(HostSearch(enabled: showsSearch, text: $search))
            .onDisappear { unpairedNote = nil }
            // Pull down to check servers and list paired devices again.
            .refreshable {
                refreshAll()
                while servers.relayServers.contains(where: { macs.existing(for: $0)?.busy != nil }), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            .navigationTitle(String(localized: "Devices", bundle: .main))
            .overlay(alignment: .bottom) { SSHUndoRemovalBar(model: ssh) }
        }
    }

    private func refreshAll() {
        servers.servers.forEach { $0.check() }
        for server in servers.relayServers { macs.model(for: server).loadDevices() }
    }

    // MARK: Paired devices

    @ViewBuilder
    private func deviceRows(_ server: ConnectionModel) -> some View {
        if server.supportsRelay {
            let model = macs.model(for: server)
            if let busy = model.busy {
                ActivityRow(busy) { model.cancelWork() }
                    .accessibilityIdentifier("remoteTerminalActivity")
            }
            if let issue = model.issue {
                IssueBanner(issue.title, message: issue.recovery, systemImage: WitermSymbols.unpaired)
                    .accessibilityIdentifier("remoteTerminalError")
            }
            // One row per device, however many pairings it has. The row opens
            // the device's page in this tab; its terminals open in Terminals.
            ForEach(model.devices) { grant in
                NavigationLink {
                    MacDeviceDetails(server: server, grant: grant, model: model, openTerminals: { openMac(server, grant) }) {
                        unpairedNote = String(localized: "Unpaired from \(grant.host.name)", bundle: .main)
                    }
                } label: {
                    HStack(spacing: WitermMetrics.Space.m) {
                        IconTile(systemImage: grant.host.platform == .macos ? "laptopcomputer" : "iphone", tint: grant.host.identityHue)
                        VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                            Text(grant.host.name).font(WitermType.rowTitle).foregroundStyle(WitermTheme.ink)
                            // What this device may do there. The section
                            // names the server when there are several.
                            Text(grant.permission == .view ? String(localized: "Can only watch", bundle: .main) : String(localized: "Can watch and type", bundle: .main))
                                .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                        }
                    }
                }
                .disabled(model.busy != nil)
                .accessibilityIdentifier("deviceDetails-\(grant.host.id)")
            }
        } else {
            ConnectionFeedback(server: server)
            if !server.phase.isChecking {
                Button(action: server.check) {
                    ContentActionLabel(String(localized: "Check Again", bundle: .main), systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: SSH hosts

    private func hostRow(_ profile: SSHProfile) -> some View {
        let session = ssh.session(for: profile.id)
        return HStack(spacing: WitermMetrics.Space.xs) {
            Button { openHost(profile) } label: {
                SSHHostRowContent(profile: profile, active: session != nil, expanded: true, favorite: ssh.isFavorite(profile),
                                  activity: session?.activity)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .modifier(SSHHostSwipeActions(profile: profile, ssh: ssh, ui: ui))
    }
}
#endif
