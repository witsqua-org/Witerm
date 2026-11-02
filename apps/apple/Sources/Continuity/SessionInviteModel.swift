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
                        self.phase = .failed(String(localized: "\(device.name) is already paired with this Mac. It can open this terminal from Terminals if you allow it in Settings → Devices.", bundle: .main))
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
#endif
