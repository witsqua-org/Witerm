#if os(iOS)
import SwiftUI
import UIKit
import WitermCore

/// Joins one Mac session from an invitation, without pairing.
@MainActor @Observable
final class JoinSessionModel {
    enum Phase: Equatable {
        case idle
        case working(String)
        /// A control invitation waits for the person at the Mac to approve.
        case waitingForApproval
        /// This device is already paired with that Mac; its pairing applies.
        case alreadyPaired(DeviceGrant)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    @ObservationIgnored private var work: Task<Void, Never>?
    /// A grant whose proof couldn't be delivered yet, so trying again
    /// doesn't need a new invitation.
    @ObservationIgnored private var joined: (PairingClient, DeviceGrant)?

    /// Joins through the pairing endpoints, checks that the grant the Mac
    /// signed matches what the link says, then proves this device holds the
    /// link. Nothing opens until all three succeed.
    func join(_ invitation: SessionInvitation, server: ConnectionModel, opened: @escaping (DeviceGrant) -> Void) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let client: PairingClient
                let grant: DeviceGrant
                if let joined = self.joined, joined.1.pairingID == invitation.pairingID {
                    (client, grant) = joined
                } else {
                    self.phase = .working(String(localized: "Joining…", bundle: .main))
                    let joining = try PairingClient(serverAddress: server.address, deviceName: Self.deviceName, platform: .ios)
                    _ = try await joining.register()
                    // One grant per Mac and device: an existing pairing is used as is.
                    if let paired = try await joining.grants().first(where: { $0.host.publicKey == invitation.hostPublicKey }) {
                        self.phase = .alreadyPaired(paired)
                        return
                    }
                    var pairing = try await joining.join(invitation.pairingInvitation())
                    while pairing.status != .approved {
                        guard pairing.status == .pending || pairing.status == .waiting else { throw PairingClientError.api(code: "pairing_unavailable") }
                        if invitation.permission == .control { self.phase = .waitingForApproval }
                        try await Task.sleep(for: .seconds(2))
                        pairing = try await joining.pairing(id: invitation.pairingID)
                    }
                    // Verifies the Mac's signature against the key pinned from the link.
                    guard let signed = try await joining.grants().first(where: { $0.pairingID == invitation.pairingID }) else {
                        throw PairingClientError.invalidProof
                    }
                    guard signed.permission == invitation.permission else {
                        try? await joining.revoke(grantID: signed.id, pairingID: signed.pairingID)
                        throw PairingClientError.invalidProof
                    }
                    (client, grant) = (joining, signed)
                    self.joined = (client, grant)
                }
                self.phase = .working(String(localized: "Opening the terminal…", bundle: .main))
                try await RemoteTerminalClient(pairing: client, grantID: grant.id).redeem(invitation)
                self.joined = nil
                self.phase = .idle
                opened(grant)
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                let issue = (error as? RelayError).map { RemoteTerminalIssue($0) }
                self.phase = .failed(issue?.title ?? PairingIssue(error).title)
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    private static var deviceName: String {
        let clean = UIDevice.current.name.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView((clean.isEmpty ? String(localized: "My iPhone", bundle: .main) : clean).unicodeScalars.prefix(64)))
    }
}
#endif
