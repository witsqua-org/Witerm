#if os(macOS)
import SwiftUI
import WitermSSH

/// A saved SSH host: its route and actions, or its live terminal. Leaving
/// this page keeps the session connected; Disconnect is explicit.
struct SSHHostDetail: View {
    let profile: SSHProfile
    @Bindable var model: SSHWorkspaceModel
    let ui: SSHWorkspaceUI

    private var isConnecting: Bool { model.connectingProfile?.id == profile.id }

    var body: some View {
        Group {
            if let session = model.session(for: profile.id) {
                VStack(spacing: 0) {
                    TerminalHeader(nil, destination: profile.endpointSummary, status: String(localized: "Input Enabled", bundle: .main),
                                   statusImage: "keyboard", live: true, hue: profile.identityHue) {
                        Button(String(localized: "SFTP Files", bundle: .main), systemImage: "folder") { ui.files = session }
                            .labelStyle(.iconOnly)
                            .touchTarget(square: true)
                            .help(String(localized: "SFTP Files", bundle: .main))
                            .accessibilityIdentifier("sshFiles")
                        Button(String(localized: "Port Forwarding", bundle: .main), systemImage: "arrow.left.arrow.right") { ui.forwarding = session }
                            .labelStyle(.iconOnly)
                            .touchTarget(square: true)
                            .help(String(localized: "Port Forwarding", bundle: .main))
                            .accessibilityIdentifier("sshForwarding")
                        Button(String(localized: "Disconnect", bundle: .main), systemImage: "eject") { model.disconnect(session) }
                            .touchTarget()
                            .accessibilityIdentifier("sshDisconnect")
                    }
                    .buttonStyle(.borderless)
                    SSHTerminalSurface(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView { overview.readableContent(padding: 32) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WitermTheme.canvas)
        .navigationTitle(profile.name)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(systemImage: "terminal", tint: profile.identityHue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(WitermTheme.ink)
                        .textSelection(.enabled)
                    Text(verbatim: profile.endpointSummary)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(WitermTheme.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                actionsMenu
            }

            if model.issueProfileID == profile.id || model.issueProfileID == nil {
                SSHIssueBanner(model: model, ui: ui, profile: profile)
            }

            if isConnecting {
                ActivityRow(String(localized: "Connecting to \(String(profile.name))…", bundle: .main), cancel: model.cancelConnecting)
                    .witermCard(padding: 16)
            } else {
                if let reason = model.disconnected[profile.id] {
                    Label(String(localized: "Disconnected", bundle: .main), systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                    Text(reason).font(.subheadline).foregroundStyle(WitermTheme.secondary)
                }
                HStack(spacing: 12) {
                    PrimaryButton(model.disconnected[profile.id] == nil ? String(localized: "Connect", bundle: .main) : String(localized: "Reconnect", bundle: .main), systemImage: "play.fill", tint: profile.identityHue) {
                        ui.open(profile, model: model)
                    }
                    .disabled(model.connecting)
                    .accessibilityIdentifier("sshConnectProfile")
                    Button(String(localized: "Edit…", bundle: .main)) { ui.open(profile, model: model, editing: true) }
                        .buttonStyle(.bordered)
                        .witermControl()
                        .disabled(model.connecting)
                        .accessibilityIdentifier("sshEditProfile")
                }
                Text(String(localized: "Saved credentials connect immediately. Otherwise Witerm asks for them.", bundle: .main))
                    .font(.footnote)
                    .foregroundStyle(WitermTheme.secondary)
            }

            route
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button(model.isFavorite(profile) ? String(localized: "Remove from Favorites", bundle: .main) : String(localized: "Add to Favorites", bundle: .main), systemImage: "star") { model.toggleFavorite(profile) }
            Button(String(localized: "Host Keys", bundle: .main), systemImage: "key") { ui.inspectKeys(profile) }
            Divider()
            Button(String(localized: "Delete Connection", bundle: .main), systemImage: "trash", role: .destructive) { ui.remove(profile) }
        } label: {
            Label(String(localized: "More", bundle: .main), systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(String(localized: "Actions for \(String(profile.name))", bundle: .main))
        .accessibilityIdentifier("sshProfileActions-\(profile.id.uuidString)")
    }

    /// Every hop in connection order. Each host key is verified separately.
    private var route: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Route", bundle: .main))
                .font(.headline)
                .padding(.bottom, 12)
            routeStop(String(localized: "This Mac", bundle: .main), detail: nil, systemImage: "laptopcomputer",
                      tint: WitermTheme.accent, last: false)
            ForEach(Array(profile.jumpHosts.enumerated()), id: \.element.id) { index, host in
                routeStop(String(localized: "Jump Host \(String(index + 1))", bundle: .main),
                          detail: "\(host.username)@\(host.hostname):\(host.port)",
                          systemImage: "arrow.triangle.branch", tint: WitermTheme.secondary, last: false)
            }
            routeStop(String(localized: "Target Host", bundle: .main), detail: profile.endpointSummary,
                      systemImage: "server.rack", tint: profile.identityHue, last: true)
        }
        .witermCard()
        .accessibilityElement(children: .combine)
    }

    private func routeStop(_ title: String, detail: String?, systemImage: String, tint: Color, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: .circle)
                if !last {
                    Rectangle()
                        .fill(WitermTheme.divider)
                        .frame(width: 1, height: 18)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(WitermTheme.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        }
    }
}
#endif
