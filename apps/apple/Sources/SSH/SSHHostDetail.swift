#if os(macOS)
import SwiftUI
import WitermSSH

/// A saved SSH host: its route and actions, or its live terminal. Leaving
/// this page keeps the session connected; Disconnect is explicit. Once
/// connected, the window title and subtitle name the host and where typing
/// goes, the toolbar holds its tools, and a line in the host's hue tops the
/// terminal.
struct SSHHostDetail: View {
    let profile: SSHProfile
    @Bindable var model: SSHWorkspaceModel
    let ui: SSHWorkspaceUI
    /// A Disconnect waiting for confirmation, because a program is running.
    @State private var confirmingDisconnect: SSHSession?

    private var isConnecting: Bool { model.connectingProfile?.id == profile.id }

    var body: some View {
        Group {
            if let session = model.session(for: profile.id) {
                SSHTerminalSurface(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Rectangle().fill(profile.identityHue).frame(height: 2).accessibilityHidden(true)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(String(localized: "SFTP Files", bundle: .main), systemImage: "folder") { ui.files = session }
                                .help(String(localized: "Browse and transfer files on \(String(profile.name))", bundle: .main))
                                .accessibilityIdentifier("sshFiles")
                            Button(String(localized: "Port Forwarding", bundle: .main), systemImage: "arrow.left.arrow.right") { ui.forwarding = session }
                                .help(String(localized: "Forward a port through \(String(profile.name))", bundle: .main))
                                .accessibilityIdentifier("sshForwarding")
                            Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect) { disconnect(session) }
                                .help(String(localized: "Disconnect; the remote shell ends", bundle: .main))
                                .accessibilityIdentifier("sshDisconnect")
                        }
                    }
            } else {
                // Round 28: the host as one centered summary (its tile, name,
                // address and actions) rather than a row pinned to the top.
                ScrollView {
                    overview
                        .frame(maxWidth: 520)
                        .padding(WitermMetrics.Space.xxl)
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WitermTheme.canvas)
        .navigationTitle(profile.name)
        // The address while not connected; where typing goes while it does.
        .navigationSubtitle(profile.endpointSummary)
        // Terminal ▸ Disconnect, with the same confirmation as the toolbar.
        .onReceive(NotificationCenter.default.publisher(for: .witermDisconnectSSH)) { note in
            if note.object as? UUID == profile.id, let session = model.session(for: profile.id) { disconnect(session) }
        }
        .alert(String(localized: "Disconnect from “\(String(profile.name))”?", bundle: .main),
               isPresented: Binding(get: { confirmingDisconnect != nil }, set: { if !$0 { confirmingDisconnect = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Disconnect", bundle: .main), role: .destructive) {
                if let session = confirmingDisconnect { model.disconnectChosen(session) }
            }
            .accessibilityIdentifier("sshConfirmDisconnect")
        } message: {
            Text(String(localized: "The program running there stops, with the remote shell.", bundle: .main))
        }
    }

    /// At a shell prompt, disconnect at once; with a program running (the
    /// last line isn't a prompt), confirm first, because it can't be undone.
    private func disconnect(_ session: SSHSession) {
        if Self.atPrompt(session.activity.lastLine) {
            model.disconnectChosen(session)
        } else {
            confirmingDisconnect = session
        }
    }

    static func atPrompt(_ line: String?) -> Bool {
        guard let line = line?.trimmingCharacters(in: .whitespaces), let last = line.last else { return true }
        return "$#%>❯".contains(last)
    }

    /// The host in its hue, then its actions; problems and the route around them.
    private var overview: some View {
        VStack(alignment: .center, spacing: WitermMetrics.Space.l) {
            VStack(spacing: WitermMetrics.Space.s) {
                Image(systemName: WitermSymbols.sshHost)
                    .font(.system(size: 28))
                    .foregroundStyle(profile.identityHue)
                    .frame(width: 64, height: 64)
                    .background(WitermTheme.tint(profile.identityHue), in: .rect(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
                Text(profile.name)
                    .font(WitermType.pageTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let address = profile.distinctAddress {
                    Text(verbatim: address)
                        .font(WitermType.codeInline)
                        .foregroundStyle(WitermTheme.secondary)
                        .textSelection(.enabled)
                }
            }
            if model.issueProfileID == profile.id || model.issueProfileID == nil {
                SSHIssueBanner(model: model, ui: ui, profile: profile)
            }

            if isConnecting {
                ActivityRow(String(localized: "Connecting to \(String(profile.name))…", bundle: .main), cancel: model.cancelConnecting)
                    .witermCard(padding: WitermMetrics.Space.l)
            } else {
                if let reason = model.disconnected[profile.id] {
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                        Label(String(localized: "Disconnected", bundle: .main), systemImage: WitermSymbols.disconnected)
                            .font(WitermType.cardTitle)
                        Text(reason).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: WitermMetrics.Space.m) {
                    PrimaryButton(model.disconnected[profile.id] == nil ? String(localized: "Connect", bundle: .main) : String(localized: "Reconnect", bundle: .main), tint: profile.identityHue) {
                        ui.open(profile, model: model)
                    }
                    .disabled(model.connecting)
                    .help(String(localized: "Sign in to \(profile.endpointSummary)", bundle: .main))
                    .accessibilityIdentifier("sshConnectProfile")
                    SecondaryButton(String(localized: "Edit…", bundle: .main)) { ui.open(profile, model: model, editing: true) }
                        .disabled(model.connecting)
                        .accessibilityIdentifier("sshEditProfile")
                    actionsMenu
                }
            }

            // A direct route is already the address in the subtitle.
            if !profile.jumpHosts.isEmpty { route.frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Toggle(String(localized: "Favorite", bundle: .main),
                   isOn: Binding(get: { model.isFavorite(profile) }, set: { _ in model.toggleFavorite(profile) }))
            Button(String(localized: "Host Keys", bundle: .main), systemImage: "key") { ui.inspectKeys(profile) }
            Divider()
            Button(String(localized: "Delete Host…", bundle: .main), systemImage: "trash", role: .destructive) { ui.remove(profile) }
                .accessibilityIdentifier("sshDeleteHostMenu")
        } label: {
            Label(String(localized: "More", bundle: .main), systemImage: WitermSymbols.more)
        }
        .help(String(localized: "Favorites, host keys, and deleting this host", bundle: .main))
        .menuStyle(.borderlessButton)
        .fixedSize()
        // A borderless menu has no hover of its own.
        .padding(.horizontal, WitermMetrics.Space.s).padding(.vertical, WitermMetrics.Space.xs)
        .witermHover(cornerRadius: WitermMetrics.Radius.s)
        .accessibilityLabel(String(localized: "Actions for \(String(profile.name))", bundle: .main))
        .accessibilityIdentifier("sshProfileActions-\(profile.id.uuidString)")
    }

    /// Every hop in connection order. Each host key is verified separately.
    private var route: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Route", bundle: .main))
                .font(WitermType.cardTitle)
                .padding(.bottom, WitermMetrics.Space.m)
            routeStop(String(localized: "This Mac", bundle: .main), detail: nil, systemImage: "laptopcomputer",
                      tint: WitermTheme.accent, last: false)
            ForEach(Array(profile.jumpHosts.enumerated()), id: \.element.id) { index, host in
                routeStop(String(localized: "Jump Host \(String(index + 1))", bundle: .main),
                          detail: "\(host.username)@\(host.hostname):\(host.port)",
                          systemImage: "arrow.triangle.branch", tint: WitermTheme.secondary, last: false)
            }
            routeStop(String(localized: "Target Host", bundle: .main), detail: profile.endpointSummary,
                      systemImage: WitermSymbols.relayServer, tint: profile.identityHue, last: true)
        }
        .witermCard()
        .accessibilityElement(children: .combine)
    }

    private func routeStop(_ title: String, detail: String?, systemImage: String, tint: Color, last: Bool) -> some View {
        HStack(alignment: .top, spacing: WitermMetrics.Space.m) {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(WitermType.rowDetail)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(WitermTheme.tint(tint), in: .circle)
                if !last {
                    Rectangle()
                        .fill(WitermTheme.hairline)
                        .frame(width: 1, height: 16)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                Text(title).font(WitermType.rowTitle)
                if let detail {
                    Text(verbatim: detail)
                        .font(WitermType.codeInline)
                        .foregroundStyle(WitermTheme.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, WitermMetrics.Space.xs)
        }
    }
}
#endif
