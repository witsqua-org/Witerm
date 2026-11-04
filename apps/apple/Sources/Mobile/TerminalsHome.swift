#if os(iOS)
import SwiftUI
import WitermCore
import WitermSSH

/// Everything a person can open, as one list in three kinds of section:
/// each paired device with its terminals, terminals shared with you through
/// an invitation, then SSH hosts. Paired terminals are sessions you open;
/// SSH hosts are destinations you connect to, so they never share a
/// section. Nothing needs a tap into a device to be seen.
struct TerminalsHome: View {
    let ssh: SSHWorkspaceModel
    let ui: SSHWorkspaceUI
    let macs: RemoteModels
    /// Opens one of a device's terminals; a nil mode types when allowed.
    let openTerminal: (ConnectionModel, DeviceGrant, LocalSessionInfo, LocalAttachmentMode?) -> Void
    @Environment(ServerList.self) private var servers
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var search = ""
    @State private var favoritesOnly = false
    @Environment(NetworkStatus.self) private var network: NetworkStatus?
    @Environment(\.scenePhase) private var scenePhase
    /// A Shared with You terminal whose End Invitation… was chosen, while
    /// its confirmation shows.
    @State private var endingInvitation: EndingInvitation?
    @State private var endInvitationFailure: String?

    struct EndingInvitation: Identifiable {
        let section: DeviceSection
        let name: String
        var id: String { section.id }
    }

    /// Search appears once the list is long enough to need it, and covers
    /// every section.
    private var showsFilters: Bool {
        let sections = Self.sections(servers: servers, macs: macs)
        let terminals = (sections.paired + sections.shared).reduce(0) { $0 + $1.terminals.count }
        return ssh.profiles.count + terminals >= Self.filterThreshold
    }
    static let filterThreshold = 8
    #if DEBUG
    private static let layoutProbe = ProcessInfo.processInfo.arguments.contains("--witerm-ui-test-layout-probe")
    #endif

    /// One device's place in the list.
    @MainActor struct DeviceSection: Identifiable {
        let server: ConnectionModel
        let grant: DeviceGrant
        let model: RemoteTerminalModel
        let id: String
        init(server: ConnectionModel, grant: DeviceGrant, model: RemoteTerminalModel) {
            self.server = server
            self.grant = grant
            self.model = model
            id = "\(server.id.uuidString)-\(grant.id)"
        }
        var terminals: [LocalSessionInfo] { model.terminals[grant.id] ?? [] }
        var listing: TerminalListing? { model.listing[grant.id] }
    }

    /// Paired devices, once per device and relay server, then grants from an
    /// invitation, in the order relay servers and devices are listed.
    /// ⌘1–⌘9 follow the same order.
    static func sections(servers: ServerList, macs: RemoteModels) -> (paired: [DeviceSection], shared: [DeviceSection]) {
        var paired: [DeviceSection] = [], shared: [DeviceSection] = []
        for server in servers.relayServers {
            let model = macs.model(for: server)
            paired += model.pairedDevices.map { DeviceSection(server: server, grant: $0, model: model) }
            shared += model.sharedGrants.map { DeviceSection(server: server, grant: $0, model: model) }
        }
        return (paired, shared)
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A device's terminals that match the search: all of them when the
    /// device's name matches.
    private func matching(_ section: DeviceSection) -> [LocalSessionInfo] {
        guard !query.isEmpty, !section.grant.host.name.localizedCaseInsensitiveContains(query) else { return section.terminals }
        return section.terminals.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var pairedSections: [DeviceSection] {
        let all = Self.sections(servers: servers, macs: macs).paired
        return query.isEmpty ? all : all.filter { !matching($0).isEmpty }
    }

    private var sharedSections: [DeviceSection] {
        Self.sections(servers: servers, macs: macs).shared.filter { !matching($0).isEmpty || isOpening($0) }
    }

    private func isOpening(_ section: DeviceSection) -> Bool {
        section.model.selectedGrant?.id == section.grant.id && section.model.displayAttachment == nil
            && (section.model.busy != nil || section.model.issue != nil)
    }

    /// Live sessions, then hosts whose session ended while the app was open.
    private var open: [SSHProfile] {
        ssh.orderedProfiles(search: search, favoritesOnly: favoritesOnly)
            .filter { ssh.session(for: $0.id) != nil || ssh.disconnected[$0.id] != nil }
    }

    private var hosts: [SSHProfile] {
        let openIDs = Set(open.map(\.id))
        return ssh.orderedProfiles(search: search, favoritesOnly: favoritesOnly).filter { !openIDs.contains($0.id) }
    }

    /// Devices whose pairing ended while open here: their terminal closed at
    /// once, so the reason stays until dismissed.
    private var unpaired: [RemoteTerminalModel] {
        servers.relayServers.compactMap { macs.existing(for: $0) }.filter { $0.unpairedName != nil }
    }

    /// Relay servers still listing their devices, or that couldn't.
    private var serverWork: [RemoteTerminalModel] {
        servers.relayServers.compactMap { macs.existing(for: $0) }
            .filter { $0.selectedGrant == nil && $0.unpairedName == nil && ($0.busy != nil || $0.issue != nil) }
    }

    private var hasDevices: Bool {
        let sections = Self.sections(servers: servers, macs: macs)
        return !sections.paired.isEmpty || !sections.shared.isEmpty
    }

    var body: some View {
        List {
            ForEach(unpaired, id: \.serverAddress) { model in
                IssueBanner(String(localized: "No Longer Paired with \(model.unpairedName ?? "")", bundle: .main),
                            message: RemoteTerminalIssue(RelayError.revoked).recovery, systemImage: WitermSymbols.unpaired) {
                    Button(String(localized: "OK", bundle: .main), action: model.dismissUnpaired)
                        .font(WitermType.rowDetail.weight(.semibold)).touchTarget()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("remoteUnpaired")
            }
            ForEach(serverWork, id: \.serverAddress) { model in
                if let busy = model.busy {
                    ActivityRow(busy) { model.cancelWork() }
                        .accessibilityIdentifier("remoteTerminalActivity")
                } else if let issue = model.issue {
                    IssueBanner(issue.title, message: issue.recovery, systemImage: WitermSymbols.unpaired)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("remoteTerminalError")
                }
            }
            ForEach(pairedSections) { section in deviceSection(section) }
            if !sharedSections.isEmpty {
                Section {
                    ForEach(sharedSections) { section in
                        sectionStatus(section)
                        ForEach(matching(section)) { session in
                            terminalRow(session, in: section, shared: true)
                                .modifier(PairedTerminalRowActions(
                                    disconnect: disconnectAction(session, in: section),
                                    endInvitation: { endingInvitation = EndingInvitation(section: section, name: session.name) },
                                    ending: section.model.unpairingID == section.grant.id, offline: network?.online == false))
                        }
                    }
                } header: {
                    Text(String(localized: "Shared with You", bundle: .main))
                } footer: {
                    if let endInvitationFailure {
                        Text(endInvitationFailure).foregroundStyle(WitermTheme.warning)
                            .accessibilityIdentifier("endInvitationFailure")
                    }
                }
            }
            sshSection
        }
        .listStyle(.insetGrouped)
        .modifier(HostSearch(enabled: showsFilters, text: $search, prompt: String(localized: "Search Terminals", bundle: .main)))
        .onChange(of: showsFilters) { _, shown in if !shown { search = ""; favoritesOnly = false } }
        .overlay {
            if !query.isEmpty || favoritesOnly, open.isEmpty, hosts.isEmpty, pairedSections.isEmpty, sharedSections.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Matching Terminals", bundle: .main), systemImage: "magnifyingglass")
                } actions: {
                    Button(String(localized: "Show All", bundle: .main)) { search = ""; favoritesOnly = false }
                }
            }
        }
        // Every device's terminals, each time the list appears.
        .task { listAll() }
        // Round 18: Online and Offline stay current while the list is on
        // screen and the app is active, and again at once when the network
        // comes back.
        .task(id: PresenceTrigger(active: scenePhase == .active, online: network?.online != false)) {
            guard scenePhase == .active, network?.online != false else { return }
            listAll()
            await followPresence(servers: servers, macs: macs)
        }
        // Pull down to check the relay servers and list every device again.
        .refreshable {
            servers.servers.forEach { $0.check() }
            listAll()
            while servers.relayServers.contains(where: { server in
                macs.existing(for: server).map { $0.listing.values.contains(.listing) } ?? false
            }), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .overlay(alignment: .bottom) { SSHUndoRemovalBar(model: ssh) }
        // Ending an invitation can't be undone, so it always asks first.
        .alert(String(localized: "End Invitation to “\(endingInvitation?.name ?? "")”?", bundle: .main),
               isPresented: Binding(get: { endingInvitation != nil }, set: { if !$0 { endingInvitation = nil } }),
               presenting: endingInvitation) { ending in
            Button(String(localized: "End Invitation", bundle: .main), role: .destructive) { endInvitation(ending) }
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
        } message: { ending in
            Text(String(localized: "\(thisDevice) can no longer open it. This can’t be undone: to open it again, \(ending.section.grant.host.name) must invite you again.", bundle: .main))
        }
    }

    /// Names the device the app runs on, as the vocabulary allows.
    private var thisDevice: String {
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad", bundle: .main)
            : String(localized: "This iPhone", bundle: .main)
    }

    private func endInvitation(_ ending: EndingInvitation) {
        endInvitationFailure = nil
        Task {
            do { try await ending.section.model.endInvitation(ending.section.grant) } catch {
                let failure = PairingIssue(error)
                endInvitationFailure = String(localized: "\(failure.title). The invitation is still in effect. Try again.", bundle: .main)
            }
        }
    }

    private func listAll() {
        servers.relayServers.forEach { macs.existing(for: $0)?.listTerminals() }
    }

    // MARK: Paired devices

    private func deviceSection(_ section: DeviceSection) -> some View {
        Section {
            sectionStatus(section)
            let terminals = matching(section)
            switch section.listing {
            case .offline:
                // Round 18: a plain row with a system label, as Settings
                // says a thing is unavailable; no box of its own.
                Label(String(localized: "Offline. Its terminals appear here when it’s back online.", bundle: .main),
                      systemImage: WitermSymbols.disconnected)
                    .font(WitermType.rowDetail)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("deviceOffline-\(section.grant.host.id)")
            case .failed(let title, let recovery) where terminals.isEmpty:
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(title).font(WitermType.rowTitle).foregroundStyle(WitermTheme.ink)
                    Text(recovery).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                }
                .accessibilityElement(children: .combine)
            case .listing where terminals.isEmpty, nil where terminals.isEmpty:
                HStack(spacing: WitermMetrics.Space.s) {
                    ProgressView().accessibilityHidden(true)
                    Text(String(localized: "Loading terminals…", bundle: .main))
                        .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                }
                .accessibilityElement(children: .combine)
            default:
                if terminals.isEmpty {
                    note(String(localized: "On the other device, choose Open On ▸ \(PairingDeviceName.current).", bundle: .main))
                        .accessibilityIdentifier("remoteSessionsEmpty")
                }
                ForEach(terminals) { session in
                    terminalRow(session, in: section, shared: false)
                        .modifier(PairedTerminalRowActions(disconnect: disconnectAction(session, in: section)))
                }
            }
        } header: {
            deviceHeader(section)
        }
    }

    /// The device's name, its relay server when there are several, and
    /// whether it answered.
    private func deviceHeader(_ section: DeviceSection) -> some View {
        HStack(spacing: WitermMetrics.Space.s) {
            Text(verbatim: servers.servers.count > 1 ? "\(section.grant.host.name) · \(section.server.displayName)" : section.grant.host.name)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: WitermMetrics.Space.s)
            switch section.listing {
            case .online:
                StatusBadge(String(localized: "Online", bundle: .main), systemImage: WitermSymbols.connected, tone: .positive)
            case .offline:
                StatusBadge(String(localized: "Offline", bundle: .main), systemImage: WitermSymbols.disconnected)
            case .listing, nil:
                StatusBadge(String(localized: "Checking…", bundle: .main), systemImage: "arrow.triangle.2.circlepath")
            case .failed:
                EmptyView()
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("deviceSection-\(section.grant.host.id)")
        #if DEBUG
        // For tests that time how soon Offline shows (Round 18).
        .accessibilityValue(Self.layoutProbe ? FixtureMac.shared.wentOffline[section.grant.id]
            .map { String(format: "offlineAt=%.3f", $0.timeIntervalSince1970) } ?? "" : "")
        #endif
    }

    /// Opening one of this device's terminals, or why it didn't open, beside
    /// its terminals.
    @ViewBuilder private func sectionStatus(_ section: DeviceSection) -> some View {
        let model = section.model
        if model.selectedGrant?.id == section.grant.id, model.displayAttachment == nil {
            if let busy = model.busy {
                ActivityRow(busy) { model.cancelWork() }
                    .accessibilityIdentifier("remoteTerminalActivity")
            } else {
                if let issue = model.issue {
                    IssueBanner(issue.title,
                                message: issue.recovery, systemImage: WitermSymbols.unpaired)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("remoteTerminalError")
                }
                // A terminal that didn't open, or whose opening was
                // cancelled: it never connected, so try again.
                if model.canReconnect, let session = model.selectedSession {
                    Button { model.reconnect() } label: {
                        ContentActionLabel(String(localized: "Try Again", bundle: .main), systemImage: "arrow.clockwise")
                    }
                    .accessibilityValue(session.name)
                    .accessibilityIdentifier("reconnectRemoteTerminal")
                }
            }
        }
    }

    /// Disconnect, while the terminal is connected here (on screen or kept
    /// after Back); nil otherwise.
    private func disconnectAction(_ session: LocalSessionInfo, in section: DeviceSection) -> (() -> Void)? {
        guard section.model.isConnected(session, on: section.grant) else { return nil }
        return { section.model.disconnect(session, on: section.grant) }
    }

    private func terminalRow(_ session: LocalSessionInfo, in section: DeviceSection, shared: Bool) -> some View {
        let grant = section.grant, model = section.model
        let access = RemoteTerminalModel.access(for: session, on: grant)
        let shown = model.selectedGrant?.id == grant.id && model.displayAttachment?.session.id == session.id
        // Connected here (on screen, or kept after Back): the same badge as
        // a connected SSH host.
        let connected = model.isConnected(session, on: grant)
        // Whose it is and that access ends with the invitation; or Can only
        // watch, since typing is the norm, then how many devices are
        // connected when that's two or more (Round 21: as the title counts
        // them, never who types).
        let detail = shared
            ? [String(localized: "\(grant.host.name) · Until the invitation ends", bundle: .main)]
            : [access == .view ? String(localized: "Can only watch", bundle: .main) : nil,
               ConnectedDevices.rowCount(session.attached, connectedHere: connected)].compactMap { $0 }
        // VoiceOver: the Mac (a shared row's detail names it), whether it's
        // connected here, then the rest, so "connected" never follows "2
        // devices connected".
        let lead: [String] = shared ? detail : [grant.host.name]
        let rest: [String] = shared ? [] : detail
        let spoken = lead.joined(separator: ", ")
            + (connected ? String(localized: ", connected", bundle: .main) : "")
            + rest.map { ", " + $0 }.joined()
        return Button { openTerminal(section.server, grant, session, nil) } label: {
            HStack(spacing: WitermMetrics.Space.m) {
                IconTile(systemImage: WitermSymbols.sshHost, tint: grant.host.identityHue)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(session.name).font(WitermType.rowTitle).foregroundStyle(WitermTheme.ink)
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                    }
                    if connected {
                        StatusBadge(String(localized: "Connected", bundle: .main), systemImage: WitermSymbols.connected, tone: .positive)
                            .accessibilityIdentifier("remoteSessionConnected-\(session.id)")
                    }
                }
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
        .disabled(model.busy != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.name)
        .accessibilityValue(spoken)
        .accessibilityAddTraits(shown ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("remoteSession-\(session.id)")
        .listRowBackground(sizeClass == .regular && shown ? WitermTheme.tint(grant.host.identityHue) : nil)
        // No delete swipe: ending a terminal is the other device's decision
        // (a Shared with You row gets End Invitation…, which ends access).
        // Disconnect only ends this device's connection.
    }

    private func note(_ text: String) -> some View {
        Text(text).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
    }

    // MARK: SSH hosts

    /// Saved hosts, the connected ones first, then Add SSH Host… and Import
    /// SSH Hosts…, their only place. With no hosts yet, the two rows say
    /// what each needs.
    private var sshSection: some View {
        Section {
            if showsFilters, ssh.profiles.contains(where: ssh.isFavorite) {
                Toggle(String(localized: "Favorites Only", bundle: .main), isOn: $favoritesOnly)
                    .accessibilityIdentifier("sshFavoritesOnly")
            }
            ForEach(open) { profile in hostRow(profile) }
            ForEach(hosts) { profile in hostRow(profile) }
            if ssh.profiles.isEmpty {
                FirstUseRow(title: String(localized: "Add SSH Host…", bundle: .main),
                            detail: String(localized: "Needs an address and a login", bundle: .main),
                            symbol: WitermSymbols.sshHost, action: ui.presentNew)
                    .disabled(ssh.connecting)
                    .accessibilityIdentifier("newSSHProfile")
                FirstUseRow(title: String(localized: "Import SSH Hosts…", bundle: .main),
                            detail: String(localized: "From an SSH config file", bundle: .main),
                            symbol: "square.and.arrow.down", action: ui.presentImport)
                    .accessibilityIdentifier("sshImportHosts")
            } else if query.isEmpty, !favoritesOnly {
                Button(action: ui.presentNew) {
                    ContentActionLabel(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus")
                }
                .disabled(ssh.connecting)
                .accessibilityIdentifier("newSSHProfile")
                Button(action: ui.presentImport) {
                    ContentActionLabel(String(localized: "Import SSH Hosts…", bundle: .main), systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("sshImportHosts")
            }
        } header: {
            Text(String(localized: "SSH Hosts", bundle: .main))
        } footer: {
            // Words, not a second Add Device: pairing lives in Devices.
            if !hasDevices, serverWork.isEmpty {
                Text(String(localized: "To open another device’s terminals here, add it in Devices.", bundle: .main))
                    .accessibilityIdentifier("terminalsDevicesPointer")
            }
        }
    }

    private func hostRow(_ profile: SSHProfile) -> some View {
        let session = ssh.session(for: profile.id)
        let ended = session == nil ? ssh.disconnected[profile.id] : nil
        return HStack(spacing: WitermMetrics.Space.xs) {
            Button {
                if session != nil { ui.show(profile.id) } else { ui.open(profile, model: ssh) }
            } label: {
                Group {
                    if session != nil || ended != nil {
                        TerminalActivityCard(name: profile.name, location: profile.endpointSummary,
                                             activity: session?.activity, hue: profile.identityHue,
                                             status: ended == nil ? nil : String(localized: "Disconnected", bundle: .main))
                    } else {
                        SSHHostRowContent(profile: profile, active: false, expanded: true, favorite: ssh.isFavorite(profile))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sshProfileRow-\(profile.id.uuidString)")
            .accessibilityLabel(profile.name)
            .accessibilityValue(accessibilityValue(profile, session: session, ended: ended != nil))
            .accessibilityHint(session == nil
                ? (ended != nil ? String(localized: "Reconnects.", bundle: .main)
                   : String(localized: "Connects, or asks for credentials that are not saved.", bundle: .main))
                : String(localized: "Shows the connected terminal.", bundle: .main))
            .accessibilityAddTraits(ui.shownID == profile.id ? .isSelected : [])
            SSHHostActions(profile: profile, ssh: ssh, ui: ui)
        }
        .listRowInsets(session != nil || ended != nil ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: WitermMetrics.Space.s) : nil)
        .listRowBackground(sizeClass == .regular && ui.shownID == profile.id ? WitermTheme.tint(profile.identityHue) : nil)
        .modifier(SSHHostSwipeActions(profile: profile, ssh: ssh, ui: ui))
        .contextMenu { SSHHostMenuItems(profile: profile, ssh: ssh, ui: ui) }
    }

    private func accessibilityValue(_ profile: SSHProfile, session: SSHSession?, ended: Bool) -> String {
        var value = profile.accessibilitySummary
        if let doing = session?.activity.summary(home: nil) { value += String(localized: ", \(doing)", bundle: .main) }
        if session != nil { value += String(localized: ", connected", bundle: .main) }
        if ended { value += String(localized: ", disconnected", bundle: .main) }
        if ssh.isFavorite(profile) { value += String(localized: ", favorite", bundle: .main) }
        return value
    }
}

/// What restarts following devices' status: the app becoming active, the
/// network coming back.
struct PresenceTrigger: Equatable {
    let active: Bool
    let online: Bool
}

/// Follows every relay server's devices' status until cancelled (the list
/// leaving the screen, the app going inactive).
@MainActor func followPresence(servers: ServerList, macs: RemoteModels) async {
    let followers = servers.relayServers.map { server in
        let model = macs.model(for: server)
        return Task { await model.followPresence() }
    }
    await withTaskCancellationHandler {
        for follower in followers { await follower.value }
    } onCancel: {
        followers.forEach { $0.cancel() }
    }
}

/// A paired terminal's row actions (Round 18). **Disconnect** while it's
/// connected here: a trailing swipe and the long-press menu, gray and not
/// destructive (the terminal keeps running on its Mac, and reopening it
/// connects again), never a full swipe, so one swipe can't do it by
/// accident and a swipe works the same on every connected row, SSH ones
/// included. A Shared with You terminal also has **End Invitation…**, red
/// and confirmed (it can't be undone), after Disconnect; not offered
/// offline, when the relay server can't be told.
struct PairedTerminalRowActions: ViewModifier {
    let disconnect: (() -> Void)?
    var endInvitation: (() -> Void)? = nil
    var ending = false
    var offline = false

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let disconnect {
                    Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect, action: disconnect)
                        .tint(.gray)
                        .accessibilityHint(String(localized: "The terminal keeps running on the other device.", bundle: .main))
                }
                if let endInvitation, !offline, !ending {
                    Button(String(localized: "End Invitation…", bundle: .main), systemImage: "xmark.circle", action: endInvitation)
                        .tint(.red)
                }
            }
            .contextMenu {
                if let disconnect {
                    Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect, action: disconnect)
                        .accessibilityHint(String(localized: "The terminal keeps running on the other device.", bundle: .main))
                }
                if let endInvitation {
                    if disconnect != nil { Divider() }
                    Button(String(localized: "End Invitation…", bundle: .main), systemImage: "xmark.circle", role: .destructive, action: endInvitation)
                        .disabled(offline || ending)
                }
            }
    }
}

/// One way in while there are no SSH hosts: what it is and what it needs.
private struct FirstUseRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: WitermMetrics.Space.m) {
                if !typeSize.isAccessibilitySize { IconTile(systemImage: symbol) }
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(title).font(WitermType.rowTitle.weight(.semibold)).foregroundStyle(WitermTheme.ink)
                    Text(detail).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WitermTheme.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The host menu's main items as swipes: Favorite leading; Disconnect or
/// Delete Host trailing. Disconnect (while connected) is gray and never a
/// full swipe, as on a paired terminal's row (Round 18); Delete Host (when
/// not connected) is red, and a full swipe deletes, because Undo restores it.
struct SSHHostSwipeActions: ViewModifier {
    let profile: SSHProfile
    let ssh: SSHWorkspaceModel
    let ui: SSHWorkspaceUI

    func body(content: Content) -> some View {
        let session = ssh.session(for: profile.id)
        content
            .swipeActions(edge: .leading) {
                Button(ssh.isFavorite(profile) ? String(localized: "Unfavorite", bundle: .main) : String(localized: "Favorite", bundle: .main),
                       systemImage: ssh.isFavorite(profile) ? "star.slash" : "star") { ssh.toggleFavorite(profile) }
                    .tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: session == nil) {
                if let session {
                    Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect) {
                        ssh.disconnect(session)
                    }
                    .tint(.gray)
                } else {
                    Button(String(localized: "Delete Host", bundle: .main), systemImage: "trash", role: .destructive) { ui.remove(profile) }
                }
            }
    }
}

/// The actions for one saved host, as a menu beside its row.
struct SSHHostActions: View {
    let profile: SSHProfile
    let ssh: SSHWorkspaceModel
    let ui: SSHWorkspaceUI

    var body: some View {
        Menu {
            SSHHostMenuItems(profile: profile, ssh: ssh, ui: ui)
        } label: {
            Image(systemName: WitermSymbols.more).touchTarget(square: true)
        }
        .accessibilityLabel(String(localized: "Actions for \(String(profile.name))", bundle: .main))
        .accessibilityIdentifier("sshProfileActions-\(profile.id.uuidString)")
    }
}

/// One host's actions, for its ••• menu and its long press alike. Favorite
/// shows its state with a checkmark; what ends something comes last.
struct SSHHostMenuItems: View {
    let profile: SSHProfile
    let ssh: SSHWorkspaceModel
    let ui: SSHWorkspaceUI

    var body: some View {
        let session = ssh.session(for: profile.id)
        Toggle(String(localized: "Favorite", bundle: .main), systemImage: "star", isOn: Binding(
            get: { ssh.isFavorite(profile) }, set: { _ in ssh.toggleFavorite(profile) }))
        if session == nil {
            Button(String(localized: "Edit Host", bundle: .main), systemImage: "pencil") { ui.open(profile, model: ssh, editing: true) }
        }
        Button(String(localized: "Host Keys", bundle: .main), systemImage: "key") { ui.inspectKeys(profile) }
        Divider()
        // Disconnect ends a connection and isn't destructive; Delete Host,
        // red and last, removes the saved host (with Undo).
        if let session {
            Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect) { ssh.disconnect(session) }
            Divider()
        }
        Button(String(localized: "Delete Host", bundle: .main), systemImage: "trash", role: .destructive) { ui.remove(profile) }
    }
}
#endif
