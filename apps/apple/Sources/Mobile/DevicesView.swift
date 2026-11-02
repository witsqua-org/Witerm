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
    /// Opens Continue from Another Device.
    let continueFromDevice: () -> Void
    @Environment(ServerList.self) private var servers
    @State private var inspected: Inspected?
    @State private var search = ""

    private struct Inspected: Identifiable {
        let server: ConnectionModel
        let grant: DeviceGrant
        var id: String { grant.id }
    }

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
                        HStack(spacing: 14) {
                            IconTile(systemImage: "laptopcomputer.and.iphone", tint: IdentityHue.sky)
                            Text(String(localized: "Continue from Another Device", bundle: .main))
                                .font(.headline).foregroundStyle(WitermTheme.ink)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(WitermTheme.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("continueFromDevice")
                }
                if deviceServers.isEmpty {
                    Section(String(localized: "Paired Devices", bundle: .main)) {
                        Text(String(localized: "Devices you continue from appear here.", bundle: .main))
                            .font(.subheadline)
                            .foregroundStyle(WitermTheme.secondary)
                            .accessibilityIdentifier("remoteDevicesEmpty")
                    }
                } else {
                    ForEach(deviceServers) { server in
                        Section {
                            deviceRows(server)
                        } header: {
                            if servers.servers.count > 1 {
                                HStack(spacing: 8) {
                                    Text(String(localized: "Paired Devices · \(server.displayName)", bundle: .main))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
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
        .sheet(item: $inspected) { item in
            MacDeviceDetails(server: item.server, grant: item.grant) { inspected = nil }
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
                IssueBanner(issue.title, message: issue.recovery, systemImage: "exclamationmark.shield.fill")
                    .accessibilityIdentifier("remoteTerminalError")
            }
            ForEach(model.grants) { grant in
                HStack(spacing: 4) {
                    Button { openMac(server, grant) } label: {
                        HStack(spacing: 14) {
                            IconTile(systemImage: grant.host.platform == .macos ? "laptopcomputer" : "iphone", tint: grant.host.identityHue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(grant.host.name).foregroundStyle(WitermTheme.ink)
                                // The section names the server when there are several.
                                Text(grant.permission == .view ? String(localized: "View Only", bundle: .main) : String(localized: "Can Type", bundle: .main))
                                    .font(.caption).foregroundStyle(WitermTheme.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy != nil)
                    .accessibilityHint(String(localized: "Shows this device’s terminal sessions.", bundle: .main))
                    Button(String(localized: "Device Details", bundle: .main), systemImage: "info.circle") {
                        inspected = Inspected(server: server, grant: grant)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .touchTarget(square: true)
                    .accessibilityLabel(String(localized: "Details for \(grant.host.name)", bundle: .main))
                }
            }
        } else {
            ConnectionFeedback(server: server)
            if !server.phase.isChecking {
                Button(String(localized: "Check Again", bundle: .main), action: server.check)
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
}
#endif
