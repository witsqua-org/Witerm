#if os(macOS)
import SwiftUI
import WitermCore

/// Settings → Devices: the continuation server, remote access through it,
/// the devices paired with this Mac and what each may open, and invitations
/// still in effect. Pairing itself goes through `ContinueOnDeviceSheet`.
struct MacDevicesView: View {
    let service: LocalAgentService
    @Environment(ServerList.self) private var servers
    @Environment(\.localAgent) private var agent
    @Environment(\.scenePhase) private var scenePhase
    @State private var remoteAccess = MacRemoteAccessModel()
    @State private var pairing: DevicePairingModel?
    @State private var accesses: [String: LocalDeviceAccess] = [:]
    @State private var guests: [LocalGuestInvite] = []
    @State private var sessions: [LocalSessionInfo] = []
    @State private var managingServers = false
    @State private var pairingDevice = false
    @State private var editingDevice: PairedDevice?
    @State private var editing: ServerEditRequest?

    private var server: ConnectionModel? { servers.selected }

    var body: some View {
        Group {
            if let server {
                Form {
                    serverSection(server)
                    if server.supportsPairing {
                        devicesSection
                        if !guests.isEmpty { invitationsSection(server) }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "Add a Continuation Server", bundle: .main), systemImage: "server.rack")
                } description: {
                    Text(String(localized: "Your devices reach each other through a continuation server, such as witerm.example.com.", bundle: .main))
                } actions: {
                    Button(String(localized: "Add Server…", bundle: .main)) { editing = .add }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("serverSettings")
                }
            }
        }
        .serverEditor($editing)
        .sheet(isPresented: $managingServers) { ManageServersSheet() }
        .sheet(isPresented: $pairingDevice, onDismiss: refresh) { ContinueOnDeviceSheet(service: service, sessionID: nil) }
        .sheet(item: $editingDevice, onDismiss: refresh) { device in
            if let pairing, let grant = pairing.grants.first(where: { $0.client.id == device.id }) {
                MacDeviceEditSheet(pairing: pairing, grant: grant, sessions: sessions,
                                   access: accesses[device.id] ?? .default(for: device.id)) { accesses[device.id] = $0 }
            }
        }
        .task(id: server?.address) {
            remoteAccess.load()
            await service.refresh()
            connectPairing()
            await reload()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: pairing?.grants.map(\.id)) { _, _ in Task { await reload() } }
    }

    // MARK: Server

    @ViewBuilder private func serverSection(_ server: ConnectionModel) -> some View {
        Section {
            ContinuationServerPicker()
            LabeledContent(String(localized: "Status", bundle: .main)) {
                HStack(spacing: 10) {
                    StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                    if case .available(let date) = server.phase {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    if server.phase.isChecking {
                        Button(String(localized: "Cancel Check", bundle: .main), action: server.cancel)
                            .accessibilityIdentifier("cancelConnection")
                    } else {
                        Button(String(localized: "Check Now", bundle: .main), action: server.check)
                            .accessibilityIdentifier("primaryAction")
                    }
                }
            }
            .accessibilityIdentifier("connectionFeedback")
            if case .failed(let issue) = server.phase {
                Text(issue.recovery).font(.subheadline).foregroundStyle(WitermTheme.secondary)
            }
            Toggle(isOn: Binding(get: { remoteAccess.isEnabled(for: server.address) },
                                 set: { remoteAccess.setEnabled($0, address: server.address) })) {
                Text(String(localized: "Allow Remote Access", bundle: .main))
                Text(String(localized: "Paired devices reach only the sessions you allow, through this server.", bundle: .main))
            }
            .toggleStyle(.switch)
            .disabled(!remoteAccess.loaded || (service.state != .ready && !remoteAccess.isEnabled(for: server.address)))
            .accessibilityIdentifier("allowRemoteConnections")
            if service.state != .ready {
                HStack {
                    Text(String(localized: "Turn on the local terminal service first.", bundle: .main))
                        .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                    Spacer()
                    if service.state == .requiresApproval {
                        Button(String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
                    } else {
                        Button(String(localized: "Enable Local Terminal", bundle: .main)) {
                            Task { await service.start(); remoteAccess.load() }
                        }
                        .disabled(service.state == .starting)
                    }
                }
            }
            if let issue = remoteAccess.issue {
                Text(issue).font(.subheadline).foregroundStyle(WitermTheme.warning)
                    .accessibilityIdentifier("remoteAccessSettingsError")
            }
        } header: {
            Text(String(localized: "Continuation Server", bundle: .main))
        } footer: {
            HStack {
                if server.phase.isAvailable, !server.supportsPairing {
                    Text(String(localized: "This server doesn’t offer device pairing.", bundle: .main))
                } else {
                    Text(String(localized: "Witerm relays only end-to-end encrypted data through it.", bundle: .main))
                }
                Spacer()
                Button(String(localized: "Manage Servers…", bundle: .main)) { managingServers = true }
                    .accessibilityIdentifier("manageServers")
            }
            .foregroundStyle(WitermTheme.secondary)
        }
    }

    // MARK: Devices

    private var pairedGrants: [DeviceGrant] {
        guard let pairing, let me = pairing.device else { return [] }
        let invited = Set(guests.map(\.pairingID))
        return pairing.grants.filter { $0.host.id == me.id && !invited.contains($0.pairingID) }
    }

    private var devicesSection: some View {
        Section {
            if let issue = pairing?.issue {
                Text(issue.title + " " + issue.recovery).font(.subheadline).foregroundStyle(WitermTheme.warning)
                    .accessibilityIdentifier("pairingError")
            } else if pairing?.device == nil {
                ActivityRow(pairing?.busy ?? String(localized: "Loading paired devices…", bundle: .main))
            }
            ForEach(pairedGrants) { grant in
                let device = grant.client
                HStack(spacing: 12) {
                    IconTile(systemImage: device.platform == .macos ? "laptopcomputer" : "iphone", tint: device.identityHue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(summary(grant)).font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Edit…", bundle: .main)) { editingDevice = device }
                        .accessibilityLabel(String(localized: "Edit \(device.name)", bundle: .main))
                        .accessibilityIdentifier("editDevice-\(device.id)")
                }
                .accessibilityElement(children: .combine)
            }
            if pairing?.device != nil, pairedGrants.isEmpty {
                Text(String(localized: "No paired devices yet.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
            }
            Button(String(localized: "Pair a Device…", bundle: .main), systemImage: "plus") { pairingDevice = true }
                .buttonStyle(.link)
                .disabled(agent == nil)
                .accessibilityIdentifier("createPairingInvitation")
        } header: {
            Text(String(localized: "Paired Devices", bundle: .main))
        }
        .accessibilityIdentifier("pairedDevices")
    }

    private func summary(_ grant: DeviceGrant) -> String {
        let access = accesses[grant.client.id] ?? .default(for: grant.client.id)
        let typing = grant.permission == .control && access.permission == .control
        let mode = typing ? String(localized: "Can type", bundle: .main) : String(localized: "View only", bundle: .main)
        return "\(mode) · \(Self.reachSummary(access, sessions: sessions))"
    }

    /// What a device may open, in words: all, one named session, or a count.
    static func reachSummary(_ access: LocalDeviceAccess, sessions: [LocalSessionInfo]) -> String {
        if access.scope == .all { return String(localized: "All sessions", bundle: .main) }
        let shared = sessions.filter { $0.sharing?.shared == true }.map(\.id)
        let reached = Set(access.sessionIDs + shared)
        switch reached.count {
        case 0: return String(localized: "No sessions yet", bundle: .main)
        case 1:
            let name = sessions.first { reached.contains($0.id) }?.name ?? ""
            return String(localized: "Only “\(name)”", bundle: .main)
        default: return String(localized: "\(reached.count) sessions", bundle: .main)
        }
    }

    // MARK: Invitations

    private func invitationsSection(_ server: ConnectionModel) -> some View {
        Section(String(localized: "Invitations", bundle: .main)) {
            ForEach(guests) { invite in
                HStack {
                    Image(systemName: invite.permission == .control ? "keyboard" : "eye")
                        .foregroundStyle(WitermTheme.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        let name = sessions.first { $0.id == invite.sessionID }?.name ?? ""
                        Text(invite.permission == .control ? String(localized: "\(name) · Can type", bundle: .main)
                             : String(localized: "\(name) · View only", bundle: .main))
                        Text(invite.redeemed ? String(localized: "In use · until \(String(invite.expiresAt.formatted(date: .omitted, time: .shortened)))", bundle: .main)
                             : String(localized: "Not used yet", bundle: .main))
                            .font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    Spacer()
                    Button(String(localized: "End Access", bundle: .main), role: .destructive) {
                        guard let agent else { return }
                        let model = SessionInviteModel(serverAddress: server.address, sessionID: invite.sessionID)
                        model.end(invite, agent: agent)
                        guests.removeAll { $0.pairingID == invite.pairingID }
                    }
                    .accessibilityIdentifier("endInvite-\(invite.pairingID)")
                }
            }
        }
    }

    // MARK: Loading

    private func connectPairing() {
        guard let server, server.supportsPairing else { pairing = nil; return }
        if pairing?.serverAddress != server.address {
            pairing?.suspend()
            pairing = DevicePairingModel(serverAddress: server.address)
        }
        pairing?.connect()
    }

    private func refresh() {
        remoteAccess.load()
        if pairing?.device == nil { connectPairing() } else { pairing?.refresh() }
        Task { await reload() }
    }

    private func reload() async {
        guard let agent else { return }
        if let list = try? await agent.sessions() { sessions = list }
        if let stored = try? await agent.deviceAccess() {
            accesses = Dictionary(stored.map { ($0.deviceID, $0) }, uniquingKeysWith: { $1 })
        }
        if let invites = try? await agent.guests() { guests = invites.filter { $0.expiresAt > Date() } }
    }
}

/// One paired device: what it may open and do on this Mac, its code, and
/// revoking it. Each change is stored at once and can only narrow the grant.
struct MacDeviceEditSheet: View {
    let pairing: DevicePairingModel
    let grant: DeviceGrant
    let sessions: [LocalSessionInfo]
    let stored: (LocalDeviceAccess) -> Void
    @Environment(\.localAgent) private var agent
    @Environment(\.dismiss) private var dismiss
    @State private var access: LocalDeviceAccess
    @State private var reach: ContinueOnDeviceSheet.Reach
    @State private var chosen: Set<String>
    @State private var revoking = false
    @State private var problem: String?

    init(pairing: DevicePairingModel, grant: DeviceGrant, sessions: [LocalSessionInfo], access: LocalDeviceAccess,
         stored: @escaping (LocalDeviceAccess) -> Void) {
        self.pairing = pairing
        self.grant = grant
        self.sessions = sessions
        self.stored = stored
        _access = State(initialValue: access)
        _reach = State(initialValue: access.scope == .all ? .all : .chosen)
        _chosen = State(initialValue: Set(access.sessionIDs))
    }

    private var device: PairedDevice { grant.client }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(systemImage: device.platform == .macos ? "laptopcomputer" : "iphone", tint: device.identityHue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    if let server = URL(string: pairing.serverAddress)?.host {
                        Text(String(localized: "Paired through \(server)", bundle: .main)).font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let problem { IssueBanner(problem).padding(.horizontal, 24) }
                    SessionReachPicker(reach: $reach, chosen: $chosen, sessions: sessions.filter { $0.sharing?.keepPrivate != true },
                                       startingSession: nil)
                        .padding(.horizontal, 24)
                    Form {
                        if grant.permission == .control {
                            Section {
                                Toggle(String(localized: "Can Type", bundle: .main), isOn: Binding(
                                    get: { access.permission == .control },
                                    set: { save(permission: $0 ? .control : .view) }))
                                    .accessibilityIdentifier("deviceCanType-\(device.id)")
                                Toggle(String(localized: "Type While This Mac Is Attached", bundle: .main), isOn: Binding(
                                    get: { access.coTyping }, set: { save(coTyping: $0) }))
                                    .disabled(access.permission != .control)
                                    .accessibilityIdentifier("deviceCoTyping-\(device.id)")
                            }
                        } else {
                            Section { Text(String(localized: "This device was paired as view only. Pair it again to let it type.", bundle: .main)) }
                        }
                        Section {
                            LabeledContent(String(localized: "Device Code", bundle: .main)) {
                                Text(PairingFingerprint.display(publicKey: device.publicKey))
                                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(height: grant.permission == .control ? 190 : 150)
                    .padding(.horizontal, 4)
                }
            }
            Divider()
            HStack {
                Button(String(localized: "Revoke Access…", bundle: .main), role: .destructive) { revoking = true }
                    .accessibilityIdentifier("revokeGrant-\(grant.id)")
                Spacer()
                Button(String(localized: "Done", bundle: .main)) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 480, height: 520)
        .background(WitermTheme.surface)
        .witermTint()
        .onChange(of: reach) { _, _ in save() }
        .onChange(of: chosen) { _, _ in save() }
        .alert(String(localized: "Revoke Device Access?", bundle: .main), isPresented: $revoking) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Revoke Access", bundle: .main), role: .destructive) {
                pairing.revoke(grant)
                dismiss()
            }
        } message: {
            Text(String(localized: "This device will need to pair again to regain access.", bundle: .main))
        }
    }

    private func save(permission: LocalAttachmentMode? = nil, coTyping: Bool? = nil) {
        guard let agent else { return }
        let live = Set(sessions.map(\.id))
        let next = LocalDeviceAccess(deviceID: device.id, scope: reach == .all ? .all : .shared,
                                     permission: permission ?? access.permission, coTyping: coTyping ?? access.coTyping,
                                     sessionIDs: reach == .all ? [] : chosen.filter(live.contains).sorted())
        guard next != access else { return }
        let previous = access
        access = next
        Task {
            do {
                _ = try await agent.deviceAccess(next)
                problem = nil
                stored(next)
            } catch {
                access = previous
                problem = String(localized: "This Mac couldn’t save the change. Try again.", bundle: .main)
            }
        }
    }
}

/// Every saved continuation server: add, edit, check and remove. The one in
/// use for new pairings is chosen in Devices.
struct ManageServersSheet: View {
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ServerEditRequest?
    @State private var removing: ConnectionModel?
    @State private var removalBlocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Continuation Servers", bundle: .main)).font(.title2.weight(.semibold))
                Text(String(localized: "Up to 8. Your devices use all of them at once. New pairings use the one chosen in Devices.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 20)
            Form {
                Section {
                    ForEach(servers.servers) { server in
                        HStack(spacing: 10) {
                            Image(systemName: server.statusSymbol)
                                .foregroundStyle(server.statusTone == .positive ? WitermTheme.positive
                                                 : server.statusTone == .warning ? WitermTheme.warning : WitermTheme.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName)
                                Text(server.address).font(.caption.monospaced()).foregroundStyle(WitermTheme.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            if servers.selected?.id == server.id {
                                StatusBadge(String(localized: "In Use", bundle: .main), systemImage: "checkmark")
                            }
                            Button(String(localized: "Edit…", bundle: .main)) { editing = .edit(server) }
                                .accessibilityIdentifier("serverSettings")
                            Button(String(localized: "Remove…", bundle: .main), role: .destructive) { removing = server }
                                .accessibilityIdentifier("removeServer")
                        }
                        .accessibilityElement(children: .contain)
                    }
                } footer: {
                    if servers.isFull { Text(ServerList.Failure.full.message) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(String(localized: "Add Server…", bundle: .main)) { editing = .add }
                    .disabled(servers.isFull)
                    .accessibilityIdentifier("addServer")
                Spacer()
                Button(String(localized: "Done", bundle: .main)) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: 420)
        .background(WitermTheme.surface)
        .witermTint()
        .serverEditor($editing)
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
    }
}
#endif
