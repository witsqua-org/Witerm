#if os(iOS)
import SwiftUI
import WitermCore
import WitermSSH

/// Everything a person can open, organized by intent rather than transport:
/// live and recently closed terminals first, each showing what runs there,
/// then every machine, paired Macs and SSH hosts alike, most recent first.
struct TerminalsHome: View {
    let ssh: SSHWorkspaceModel
    let ui: SSHWorkspaceUI
    let macs: RemoteModels
    /// Opens a paired Mac's sessions.
    let openMac: (ConnectionModel, DeviceGrant) -> Void
    /// Opens Add Device.
    let continueFromDevice: () -> Void
    @Environment(ServerList.self) private var servers
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var search = ""
    @State private var favoritesOnly = false

    /// Search and filters appear once there are enough hosts to need them.
    private var showsFilters: Bool { ssh.profiles.count >= Self.filterThreshold }
    static let filterThreshold = 8

    /// Live sessions, then hosts whose session ended while the app was open.
    private var open: [SSHProfile] {
        ssh.orderedProfiles().filter { ssh.session(for: $0.id) != nil || ssh.disconnected[$0.id] != nil }
    }

    private var hosts: [SSHProfile] {
        let openIDs = Set(open.map(\.id))
        return ssh.orderedProfiles(search: search, favoritesOnly: favoritesOnly).filter { !openIDs.contains($0.id) }
    }

    /// One row per device and relay server, however many pairings it has.
    private var pairedMacs: [(server: ConnectionModel, grant: DeviceGrant)] {
        servers.relayServers.flatMap { server in
            macs.model(for: server).devices.map { (server: server, grant: $0) }
        }
        .filter { search.isEmpty || $0.grant.host.name.localizedCaseInsensitiveContains(search) }
    }

    /// Devices whose pairing ended while open here: their terminal closed at
    /// once, so the reason stays until dismissed.
    private var unpaired: [RemoteTerminalModel] {
        servers.relayServers.compactMap { macs.existing(for: $0) }.filter { $0.unpairedName != nil }
    }

    private var isFirstUse: Bool { ssh.profiles.isEmpty && pairedMacs.isEmpty && search.isEmpty && unpaired.isEmpty }

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
            if isFirstUse {
                firstUse
            }
            if !open.isEmpty {
                Section(String(localized: "Open", bundle: .main)) {
                    ForEach(open) { profile in hostRow(profile) }
                }
            }
            // The tab already says what these are; the section needs no title.
            if !pairedMacs.isEmpty || !hosts.isEmpty || favoritesOnly {
                Section {
                    if showsFilters, ssh.profiles.contains(where: ssh.isFavorite) {
                        Toggle(String(localized: "Favorites Only", bundle: .main), isOn: $favoritesOnly)
                            .accessibilityIdentifier("sshFavoritesOnly")
                    }
                    if !favoritesOnly {
                        ForEach(pairedMacs, id: \.grant.id) { mac in macRow(mac.server, mac.grant) }
                    }
                    ForEach(hosts) { profile in hostRow(profile) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(HostSearch(enabled: showsFilters, text: $search))
        .onChange(of: showsFilters) { _, shown in if !shown { search = ""; favoritesOnly = false } }
        .overlay {
            if !isFirstUse, open.isEmpty, hosts.isEmpty, pairedMacs.isEmpty, unpaired.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Matching Terminals", bundle: .main), systemImage: "magnifyingglass")
                } actions: {
                    Button(String(localized: "Show All", bundle: .main)) { search = ""; favoritesOnly = false }
                }
            }
        }
        .overlay(alignment: .bottom) { SSHUndoRemovalBar(model: ssh) }
    }

    // MARK: Rows

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
    }

    private func accessibilityValue(_ profile: SSHProfile, session: SSHSession?, ended: Bool) -> String {
        var value = profile.accessibilitySummary
        if let doing = session?.activity.summary(home: nil) { value += String(localized: ", \(doing)", bundle: .main) }
        if session != nil { value += String(localized: ", connected", bundle: .main) }
        if ended { value += String(localized: ", disconnected", bundle: .main) }
        if ssh.isFavorite(profile) { value += String(localized: ", favorite", bundle: .main) }
        return value
    }

    private func macRow(_ server: ConnectionModel, _ grant: DeviceGrant) -> some View {
        let model = macs.existing(for: server)
        return Button { openMac(server, grant) } label: {
            HStack(spacing: WitermMetrics.Space.m) {
                IconTile(systemImage: grant.host.platform == .macos ? "laptopcomputer" : "iphone", tint: grant.host.identityHue)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(grant.host.name).font(WitermType.rowTitle).foregroundStyle(WitermTheme.ink)
                    // Typing is the norm, so only its absence is stated here;
                    // the device's page in Devices states either.
                    let detail = [grant.permission == .view ? String(localized: "Can only watch", bundle: .main) : nil,
                                  servers.servers.count > 1 ? server.displayName : nil].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(WitermType.rowDetail)
                            .foregroundStyle(WitermTheme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
        .disabled(model?.busy != nil)
        .accessibilityIdentifier("remoteMac-\(grant.id)")
        .accessibilityHint(String(localized: "Shows this device’s terminals.", bundle: .main))
    }

    // MARK: First use

    /// Three ways in, each saying what it needs, as one list section. The
    /// Welcome Tour explains; this screen only acts. Colors stay neutral:
    /// hues belong to machines.
    private var firstUse: some View {
        Section {
            FirstUseRow(title: String(localized: "Add SSH Host…", bundle: .main),
                        detail: String(localized: "Needs an address and a login", bundle: .main),
                        symbol: WitermSymbols.sshHost, action: ui.presentNew)
                .accessibilityIdentifier("sshAddFirstHost")
            FirstUseRow(title: String(localized: "Add Device", bundle: .main),
                        detail: String(localized: "Scan or paste an invitation", bundle: .main),
                        symbol: WitermSymbols.openOn, action: continueFromDevice)
                .accessibilityIdentifier("firstUseContinue")
            FirstUseRow(title: String(localized: "Import SSH Hosts…", bundle: .main),
                        detail: String(localized: "From an SSH config file", bundle: .main),
                        symbol: "square.and.arrow.down", action: ui.presentImport)
                .accessibilityIdentifier("sshImportHosts")
        }
    }
}

/// One way in on the first-use screen.
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
/// Delete Host trailing (deleting is undoable).
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
            .swipeActions(edge: .trailing) {
                if let session {
                    Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect, role: .destructive) {
                        ssh.disconnect(session)
                    }
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
        let session = ssh.session(for: profile.id)
        // Favorite shows its state with a checkmark; what ends something comes last.
        Menu {
            Toggle(String(localized: "Favorite", bundle: .main), systemImage: "star", isOn: Binding(
                get: { ssh.isFavorite(profile) }, set: { _ in ssh.toggleFavorite(profile) }))
            if session == nil {
                Button(String(localized: "Edit Host", bundle: .main), systemImage: "pencil") { ui.open(profile, model: ssh, editing: true) }
            }
            Button(String(localized: "Host Keys", bundle: .main), systemImage: "key") { ui.inspectKeys(profile) }
            Divider()
            if let session {
                Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect, role: .destructive) { ssh.disconnect(session) }
            }
            Button(String(localized: "Delete Host", bundle: .main), systemImage: "trash", role: .destructive) { ui.remove(profile) }
        } label: {
            Image(systemName: WitermSymbols.more).touchTarget(square: true)
        }
        .accessibilityLabel(String(localized: "Actions for \(String(profile.name))", bundle: .main))
        .accessibilityIdentifier("sshProfileActions-\(profile.id.uuidString)")
    }
}
#endif
