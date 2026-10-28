#if os(macOS)
import SwiftUI
import WitermCore

/// One invitation to one session, for someone whose device isn't paired.
@MainActor @Observable
final class SessionInviteModel {
    enum Phase: Equatable {
        case choosing
        case working(String)
        /// The link is out; nobody has joined yet.
        case waiting(SessionInvitation)
        /// Someone joined a control invitation and needs approval here.
        case review(SessionInvitation, PairedDevice)
        case joined(String)
        case failed(String)
    }

    let serverAddress: String
    let sessionID: String
    private(set) var phase = Phase.choosing
    /// Invitations to this session still in effect.
    private(set) var invites: [LocalGuestInvite] = []
    @ObservationIgnored private var client: PairingClient?
    @ObservationIgnored private var pairing: DevicePairing?
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(serverAddress: String, sessionID: String) {
        self.serverAddress = serverAddress
        self.sessionID = sessionID
    }

    /// Records the invitation with the background service before showing the
    /// link, so its grant can never reach more than this session.
    func create(permission: PairingPermission, lasting duration: TimeInterval, agent: LocalAgentClient) {
        phase = .working(String(localized: "Creating invitation…", bundle: .main))
        Task {
            do {
                let client = try pairingClient()
                _ = try await client.register()
                let created = try await client.createPairing()
                let key = SessionInvitation.newProofKey()
                let expiresAt = Date().addingTimeInterval(min(duration, SessionInvitation.longestAccess))
                do {
                    _ = try await agent.guests(adding: LocalGuestInvite(
                        pairingID: created.pairingID, sessionID: sessionID,
                        permission: permission == .view ? .view : .control, expiresAt: expiresAt, key: key))
                } catch {
                    _ = try? await client.reject(id: created.pairingID)
                    throw error
                }
                let invitation = SessionInvitation.make(pairing: created, permission: permission, expiresAt: expiresAt, proofKey: key)
                phase = .waiting(invitation)
                await refreshInvites(agent)
                poll(invitation)
            } catch {
                phase = .failed(PairingIssue(error).title)
            }
        }
    }

    /// Watches for the recipient to join. A view invitation is approved at
    /// once: its grant reaches the session only after the recipient proves
    /// it holds the link. A control invitation waits for approval here.
    private func poll(_ invitation: SessionInvitation) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let client = self.client else { return }
                guard let current = try? await client.pairing(id: invitation.pairingID) else { continue }
                self.pairing = current
                switch current.status {
                case .waiting: continue
                case .pending:
                    guard let device = current.client else { continue }
                    // A device already paired with this Mac can't hold a second
                    // grant here; its own pairing decides what it reaches.
                    if let grants = try? await client.grants(), grants.contains(where: { $0.client.id == device.id }) {
                        _ = try? await client.reject(id: invitation.pairingID)
                        self.phase = .failed(String(localized: "\(device.name) is already paired with this Mac. It can open the session from Terminals if its access allows.", bundle: .main))
                        return
                    }
                    if invitation.permission == .view {
                        self.approve(invitation)
                    } else if case .waiting = self.phase {
                        self.phase = .review(invitation, device)
                    }
                    return
                case .approved:
                    self.phase = .joined(current.client?.name ?? "")
                    return
                case .rejected, .expired:
                    self.phase = .failed(String(localized: "The invitation expired before anyone joined. Create a new one.", bundle: .main))
                    return
                }
            }
        }
    }

    func approve(_ invitation: SessionInvitation) {
        guard let client, let pairing else { return }
        phase = .working(String(localized: "Approving…", bundle: .main))
        Task {
            do {
                let approved = try await client.approve(pairing, permission: invitation.permission)
                phase = .joined(approved.client?.name ?? "")
            } catch {
                phase = .failed(PairingIssue(error).title)
            }
        }
    }

    /// Cancels an invitation nobody has used, or refuses whoever joined.
    func cancel(agent: LocalAgentClient?) {
        polling?.cancel()
        let pending: String?
        switch phase {
        case .waiting(let invitation), .review(let invitation, _): pending = invitation.pairingID
        default: pending = nil
        }
        phase = .choosing
        guard let pending else { return }
        let client = client
        Task {
            _ = try? await client?.reject(id: pending)
            _ = try? await agent?.guests(removing: pending)
            if let agent { await refreshInvites(agent) }
        }
    }

    /// Ends someone's access now: revokes the grant, then forgets the invitation.
    func end(_ invite: LocalGuestInvite, agent: LocalAgentClient) {
        Task {
            do {
                let client = try pairingClient()
                for grant in try await client.grants() where grant.pairingID == invite.pairingID {
                    try await client.revoke(grantID: grant.id, pairingID: grant.pairingID)
                }
                _ = try await agent.guests(removing: invite.pairingID)
            } catch {
                phase = .failed(PairingIssue(error).title)
            }
            await refreshInvites(agent)
        }
    }

    func refreshInvites(_ agent: LocalAgentClient) async {
        guard let all = try? await agent.guests() else { return }
        invites = all.filter { $0.sessionID == sessionID && $0.expiresAt > Date() }
    }

    func stop() { polling?.cancel() }

    private func pairingClient() throws -> PairingClient {
        if let client { return client }
        let raw = Host.current().localizedName ?? String(localized: "My Mac", bundle: .main)
        let clean = raw.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(String.UnicodeScalarView((clean.isEmpty ? String(localized: "My Mac", bundle: .main) : clean).unicodeScalars.prefix(64)))
        let made = try PairingClient(serverAddress: serverAddress, deviceName: name, platform: .macos)
        client = made
        return made
    }
}

/// Shares one session through a link or QR code, without pairing.
struct SessionInviteView: View {
    let service: LocalAgentService
    let session: LocalSessionInfo
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @Environment(\.localAgent) private var agent
    @State private var serverID: ConnectionModel.ID?
    @State private var model: SessionInviteModel?
    @State private var permission = PairingPermission.view
    @State private var duration: TimeInterval = 3600
    @State private var copied = false
    @State private var remoteAccess = MacRemoteAccessModel()

    private var usable: [ConnectionModel] { servers.servers.filter { $0.supportsRelay && $0.supportsPairing } }
    private var server: ConnectionModel? { usable.first { $0.id == serverID } ?? usable.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(localized: "Anyone with this invitation can open “\(session.name)” on their iPhone or iPad without pairing. It works once, for one device, and ends at the time you choose or when the session ends.", bundle: .main))
                        .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let server {
                        if usable.count > 1 {
                            Picker(String(localized: "Server", bundle: .main), selection: Binding(get: { server.id }, set: { serverID = $0 })) {
                                ForEach(usable) { Text($0.displayName).tag($0.id) }
                            }
                        }
                        MacRemoteAccessCard(serverAddress: server.address, service: service, model: remoteAccess)
                            .id(server.address)
                        content(server)
                    } else {
                        ContentUnavailableView(String(localized: "Set Up a Server", bundle: .main), systemImage: "server.rack",
                            description: Text(String(localized: "Invitations use your Witerm server. Add one that offers pairing and remote terminals in Settings.", bundle: .main)))
                    }
                    if let model, let agent, !model.invites.isEmpty { current(model, agent: agent) }
                }
                .readableContent()
            }
            .background(WitermTheme.canvas)
            .navigationTitle(String(localized: "Share Session", bundle: .main))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", bundle: .main)) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 620)
        .task { remoteAccess.load() }
        .task(id: server?.address) {
            model?.stop()
            guard let server else { model = nil; return }
            let next = SessionInviteModel(serverAddress: server.address, sessionID: session.id)
            model = next
            if let agent { await next.refreshInvites(agent) }
        }
        // An unused invitation doesn't outlive this window.
        .onDisappear { model?.cancel(agent: agent) }
    }

    @ViewBuilder
    private func content(_ server: ConnectionModel) -> some View {
        if let model {
            VStack(alignment: .leading, spacing: 14) {
                switch model.phase {
                case .choosing, .failed:
                    if case .failed(let message) = model.phase {
                        IssueBanner(message, message: String(localized: "Nothing was shared. Try again.", bundle: .main)) { EmptyView() }
                    }
                    Picker(String(localized: "Access", bundle: .main), selection: $permission) {
                        Text(String(localized: "View only", bundle: .main)).tag(PairingPermission.view)
                        Text(String(localized: "Can type (you approve who joins)", bundle: .main)).tag(PairingPermission.control)
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("inviteAccess")
                    Picker(String(localized: "Access ends after", bundle: .main), selection: $duration) {
                        Text(String(localized: "1 hour", bundle: .main)).tag(TimeInterval(3600))
                        Text(String(localized: "8 hours", bundle: .main)).tag(TimeInterval(8 * 3600))
                        Text(String(localized: "24 hours", bundle: .main)).tag(SessionInvitation.longestAccess)
                    }
                    .accessibilityIdentifier("inviteDuration")
                    PrimaryButton(String(localized: "Create Invitation", bundle: .main), systemImage: "qrcode") {
                        guard let agent else { return }
                        // A private session can't be shared; inviting someone ends keeping it private.
                        if session.sharing?.keepPrivate == true {
                            Task { _ = try? await agent.configure(sessionID: session.id, keepPrivate: false)
                                model.create(permission: permission, lasting: duration, agent: agent) }
                        } else {
                            model.create(permission: permission, lasting: duration, agent: agent)
                        }
                    }
                    .disabled(agent == nil || !remoteAccess.isEnabled(for: server.address))
                    .accessibilityIdentifier("createSessionInvitation")
                    if !remoteAccess.isEnabled(for: server.address) {
                        Text(String(localized: "Turn on remote access above first.", bundle: .main))
                            .font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                case .working(let message):
                    ActivityRow(message)
                case .waiting(let invitation):
                    HStack(alignment: .center, spacing: 16) {
                        PairingQRCode(value: invitation.urlString)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(localized: "On the other iPhone or iPad, open Witerm, choose Open Shared Session in Machines, and scan this code or paste the link.", bundle: .main))
                                .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(copied ? String(localized: "Link Copied", bundle: .main) : String(localized: "Copy Invitation Link", bundle: .main),
                                   systemImage: copied ? "checkmark" : "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(invitation.urlString, forType: .string)
                                copied = true
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("copySessionInvitation")
                            IconText(String(localized: "Join within 5 minutes · access until \(String(invitation.expiresAt.formatted(date: .omitted, time: .shortened)))", bundle: .main), systemImage: "clock")
                                .font(.caption).foregroundStyle(WitermTheme.secondary)
                        }
                    }
                    Text(String(localized: "Keep this window open until they join. Share the link only with the person you mean to invite.", bundle: .main))
                        .font(.caption).foregroundStyle(WitermTheme.secondary)
                    Button(String(localized: "Cancel Invitation", bundle: .main), role: .cancel) { model.cancel(agent: agent) }
                case .review(let invitation, let device):
                    Label(String(localized: "Someone Wants to Type", bundle: .main), systemImage: "keyboard").font(.headline)
                    Text(device.name).font(.subheadline.weight(.semibold))
                    Text(PairingFingerprint.display(publicKey: device.publicKey))
                        .font(.system(.caption, design: .monospaced))
                    Text(String(localized: "Approve only if this is the device you invited. They can type in this session until the invitation ends.", bundle: .main))
                        .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        PrimaryButton(String(localized: "Approve", bundle: .main), systemImage: "checkmark.shield") { model.approve(invitation) }
                            .accessibilityIdentifier("approveSessionInvitation")
                        Button(String(localized: "Reject", bundle: .main), role: .destructive) { model.cancel(agent: agent) }
                    }
                case .joined(let name):
                    Label(String(localized: "\(name) Joined", bundle: .main), systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(WitermTheme.positive)
                    Button(String(localized: "Create Another Invitation", bundle: .main)) { model.cancel(agent: nil) }
                }
            }
            .witermCard()
        }
    }

    private func current(_ model: SessionInviteModel, agent: LocalAgentClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Invitations", bundle: .main)).font(.headline)
            ForEach(model.invites) { invite in
                HStack {
                    Label(invite.permission == .control ? String(localized: "Can type", bundle: .main) : String(localized: "View only", bundle: .main),
                          systemImage: invite.permission == .control ? "keyboard" : "eye")
                    Text(invite.redeemed ? String(localized: "In use · until \(String(invite.expiresAt.formatted(date: .omitted, time: .shortened)))", bundle: .main)
                         : String(localized: "Not used yet", bundle: .main))
                        .foregroundStyle(WitermTheme.secondary)
                    Spacer()
                    Button(String(localized: "End Access", bundle: .main), role: .destructive) { model.end(invite, agent: agent) }
                        .accessibilityIdentifier("endInvite-\(invite.pairingID)")
                }
                .font(.subheadline)
            }
        }
        .witermCard()
    }
}
#endif
