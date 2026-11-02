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

    private var pairedMacs: [(server: ConnectionModel, grant: DeviceGrant)] {
        servers.relayServers.flatMap { server in
            macs.model(for: server).grants.map { (server: server, grant: $0) }
        }
        .filter { search.isEmpty || $0.grant.host.name.localizedCaseInsensitiveContains(search) }
    }

    /// Devices whose pairing ended while open here: their terminal closed at
    /// once, so the reason stays until dismissed.
    private var unpaired: [RemoteTerminalModel] {
        servers.relayServers.compactMap { macs.existing(for: $0) }.filter { $0.unpairedName != nil }
    }

    var body: some View {
        List {
            ForEach(unpaired, id: \.serverAddress) { model in
                IssueBanner(String(localized: "No Longer Paired with \(model.unpairedName ?? "")", bundle: .main),
                            message: RemoteTerminalIssue(RelayError.revoked).recovery, systemImage: "exclamationmark.shield.fill") {
                    Button(String(localized: "OK", bundle: .main), action: model.dismissUnpaired)
                        .font(.subheadline).touchTarget()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("remoteUnpaired")
            }
            if !open.isEmpty {
                Section(String(localized: "Open", bundle: .main)) {
                    ForEach(open) { profile in hostRow(profile) }
                }
            }
            if !pairedMacs.isEmpty || !hosts.isEmpty || favoritesOnly {
                Section(String(localized: "Devices", bundle: .main)) {
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
        .scrollContentBackground(.hidden)
        .background(WitermTheme.canvas)
        .overlay {
            if ssh.profiles.isEmpty, pairedMacs.isEmpty, search.isEmpty, unpaired.isEmpty {
                firstUse
            } else if open.isEmpty, hosts.isEmpty, pairedMacs.isEmpty, unpaired.isEmpty {
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
        return HStack(spacing: 4) {
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
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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
        .listRowInsets(session != nil || ended != nil ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8) : nil)
        .listRowBackground(sizeClass == .regular && ui.shownID == profile.id ? profile.identityHue.opacity(0.12) : nil)
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
            HStack(spacing: 14) {
                IconTile(systemImage: grant.host.platform == .macos ? "laptopcomputer" : "iphone", tint: grant.host.identityHue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(grant.host.name).foregroundStyle(WitermTheme.ink)
                    // Typing is the norm, so only its absence is stated here;
                    // Devices → Device Details states either.
                    let detail = [grant.permission == .view ? String(localized: "Can only watch", bundle: .main) : nil,
                                  servers.servers.count > 1 ? server.displayName : nil].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(WitermTheme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
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
        .disabled(model?.busy != nil)
        .accessibilityIdentifier("remoteMac-\(grant.id)")
        .accessibilityHint(String(localized: "Shows this device’s terminals.", bundle: .main))
    }

    // MARK: First use

    /// Three ways in, each saying what it needs. The Welcome Tour explains;
    /// this screen only acts.
    private var firstUse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BrandEmblem(size: 56).accessibilityHidden(true)
                VStack(spacing: 0) {
                    FirstUseRow(title: String(localized: "Connect to an SSH Host", bundle: .main),
                                detail: String(localized: "Needs an address and a login", bundle: .main),
                                symbol: "terminal", hue: IdentityHue.rose, action: ui.presentNew)
                        .accessibilityIdentifier("sshAddFirstHost")
                    Divider().padding(.leading, 60)
                    FirstUseRow(title: String(localized: "Add Device", bundle: .main),
                                detail: String(localized: "Scan or paste an invitation", bundle: .main),
                                symbol: "laptopcomputer.and.iphone", hue: IdentityHue.sky, action: continueFromDevice)
                        .accessibilityIdentifier("firstUseContinue")
                    Divider().padding(.leading, 60)
                    FirstUseRow(title: String(localized: "Import SSH Hosts", bundle: .main),
                                detail: String(localized: "From an SSH config file", bundle: .main),
                                symbol: "square.and.arrow.down", hue: IdentityHue.violet, action: ui.presentImport)
                        .accessibilityIdentifier("sshImportHosts")
                }
                .witermCard(padding: 0)
            }
            .readableContent()
            .padding(.vertical, 24)
        }
        .background(WitermTheme.canvas)
    }
}

/// One way in on the first-use screen.
private struct FirstUseRow: View {
    let title: String
    let detail: String
    let symbol: String
    let hue: Color
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if !typeSize.isAccessibilitySize { IconTile(systemImage: symbol, tint: hue) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(WitermTheme.ink)
                    Text(detail).font(.subheadline).foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WitermTheme.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Button(String(localized: "Disconnect", bundle: .main), systemImage: "xmark.circle", role: .destructive) { ssh.disconnect(session) }
            }
            Button(String(localized: "Delete Host", bundle: .main), systemImage: "trash", role: .destructive) { ui.remove(profile) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .accessibilityLabel(String(localized: "Actions for \(String(profile.name))", bundle: .main))
        .accessibilityIdentifier("sshProfileActions-\(profile.id.uuidString)")
    }
}
#endif
