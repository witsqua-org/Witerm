import Accessibility
import Foundation
import Observation
import WitermCore
#if os(iOS)
import UIKit
#endif

/// Re-pairing ended the device's earlier pairing, then approving the new one
/// failed: the device is no longer paired until it pairs again.
struct PairingReplacementFailure: Error {}

struct PairingIssue {
    let title: String
    let recovery: String
    let integrityFailure: Bool

    init(_ error: Error) {
        integrityFailure = (error as? PairingClientError) == .invalidProof
        if error is PairingReplacementFailure {
            title = String(localized: "Pairing Not Replaced", bundle: .main)
            recovery = String(localized: "Its earlier access ended, but the new pairing wasn’t approved. Show a new QR code to pair it again.", bundle: .main)
        } else if let error = error as? PairingClientError {
            switch error {
            case .insecureTransport:
                title = String(localized: "Pairing Requires a Secure Connection", bundle: .main)
                recovery = String(localized: "Give the relay server an HTTPS address.", bundle: .main)
            case .invalidServer:
                title = String(localized: "Invalid Relay Server Address", bundle: .main)
                recovery = String(localized: "Check the relay server’s address, then try again.", bundle: .main)
            case .invalidDeviceName:
                title = String(localized: "Invalid Device Name", bundle: .main)
                recovery = String(localized: "Check the device name, then open pairing again.", bundle: .main)
            case .invalidInvitation:
                title = String(localized: "Invalid Invitation", bundle: .main)
                recovery = String(localized: "Paste the entire pairing invitation copied from the other device.", bundle: .main)
            case .serverMismatch:
                title = String(localized: "Invitation From Another Relay Server", bundle: .main)
                recovery = String(localized: "Get an invitation from a device that uses this relay server.", bundle: .main)
            case .identityUnavailable:
                title = String(localized: "Unable to Read Device Identity", bundle: .main)
                recovery = String(localized: "Unlock your device, then try again.", bundle: .main)
            case .invalidProof:
                title = String(localized: "Unable to Verify Device Identity", bundle: .main)
                recovery = String(localized: "Cancel pairing and get a new invitation from the other device.", bundle: .main)
            case .invalidResponse:
                title = String(localized: "Unrecognized Relay Server Response", bundle: .main)
                recovery = String(localized: "Check that the relay server is up to date, then try again.", bundle: .main)
            case .api(let code):
                switch code {
                case "pairing_unavailable", "not_found":
                    title = String(localized: "Invitation Unavailable", bundle: .main)
                    recovery = String(localized: "Get a new pairing invitation from the other device.", bundle: .main)
                case "rate_limited":
                    title = String(localized: "Too Many Requests", bundle: .main)
                    recovery = String(localized: "Try again later.", bundle: .main)
                case "conflict":
                    title = String(localized: "Pairing Status Changed", bundle: .main)
                    recovery = String(localized: "Refresh and try again.", bundle: .main)
                case "unauthorized":
                    title = String(localized: "Device Verification Failed", bundle: .main)
                    recovery = String(localized: "Check that the relay server is reachable, then try again.", bundle: .main)
                case "forbidden":
                    title = String(localized: "Unable to Perform This Action", bundle: .main)
                    recovery = String(localized: "Perform this action on the corresponding device in the pairing.", bundle: .main)
                default:
                    title = String(localized: "Pairing Unavailable", bundle: .main)
                    recovery = String(localized: "Check your network and the relay server, then try again.", bundle: .main)
                }
            }
        } else {
            let issue = ConnectionIssue(error: error)
            title = issue.title
            recovery = issue.recovery
        }
    }
}

@MainActor @Observable
final class DevicePairingModel {
    let serverAddress: String
    private(set) var device: PairedDevice?
    private(set) var grants: [DeviceGrant] = []
    private(set) var pairing: DevicePairing?
    private(set) var invitation: PairingInvitation?
    private(set) var preparedInvitation: PairingInvitation?
    private(set) var busy: String?
    private(set) var issue: PairingIssue?
    private(set) var paused = false
    private(set) var successCount = 0
    @ObservationIgnored private var client: PairingClient?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    private enum Update: Sendable {
        case connected(PairedDevice, [DeviceGrant])
        case created(PairingInvitation, DevicePairing)
        case refreshed(DevicePairing?, [DeviceGrant])
        case revoked(String)
    }

    init(serverAddress: String) { self.serverAddress = serverAddress }

    var isWorking: Bool { busy != nil }
    var hasLivePairing: Bool {
        guard let pairing else { return false }
        return pairing.status == .waiting || pairing.status == .pending
    }
    var mayApprove: Bool {
        pairing?.status == .pending && pairing?.client != nil && !isWorking && issue?.integrityFailure != true
    }

    func connect() {
        guard !isWorking else { return }
        do {
            if client == nil {
                #if os(macOS)
                let rawName = Host.current().localizedName ?? String(localized: "My Mac", bundle: .main)
                let platform = DevicePlatform.macos
                #else
                let rawName = UIDevice.current.name
                let platform = DevicePlatform.ios
                #endif
                let cleanName = rawName.components(separatedBy: .controlCharacters).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = String(String.UnicodeScalarView((cleanName.isEmpty ? String(localized: "My Device", bundle: .main) : cleanName).unicodeScalars.prefix(64)))
                client = try PairingClient(serverAddress: serverAddress, deviceName: name, platform: platform)
            }
            run(String(localized: "Preparing device identity…", bundle: .main)) { client in
                let device = try await client.register()
                let grants = try await client.grants()
                return .connected(device, grants)
            }
        } catch { report(error) }
    }

    func create() {
        run(String(localized: "Creating invitation…", bundle: .main)) { client in
            let invitation = try await client.createPairing()
            let pairing = try await client.pairing(id: invitation.pairingID)
            return .created(invitation, pairing)
        }
    }

    func prepare(_ text: String) {
        guard !isWorking else { return }
        do {
            preparedInvitation = try PairingInvitation(urlString: text.trimmingCharacters(in: .whitespacesAndNewlines), expectedServer: serverAddress)
            issue = nil
        } catch {
            preparedInvitation = nil
            report(error)
        }
    }

    func discardPreparedInvitation() { preparedInvitation = nil }

    func join() {
        guard let invitation = preparedInvitation else { return }
        run(String(localized: "Requesting pairing…", bundle: .main)) { client in
            let pairing = try await client.join(invitation)
            let grants = try await client.grants()
            return .refreshed(pairing, grants)
        }
    }

    /// The grant the requesting device already has with this device, if any.
    /// The server allows one active grant per pair, so approving replaces it.
    var existingGrantForRequest: DeviceGrant? {
        guard let requester = pairing?.client else { return nil }
        return grants.first { $0.client.id == requester.id || $0.host.id == requester.id }
    }

    /// Approves the pending request. `older` are pairings with the same device
    /// under an earlier identity (same name and kind); they end only after
    /// this approval succeeds, so a failure never leaves the device unpaired.
    func approve(permission: PairingPermission, alsoUnpair older: [DeviceGrant] = []) {
        guard mayApprove, let pairing else { return }
        let replaced = existingGrantForRequest
        run(String(localized: "Approving pairing…", bundle: .main)) { client in
            // The same identity's current grant has to end first: the server
            // allows one active grant per pair of identities. If approving
            // then fails, say so plainly, with the way back.
            if let replaced { try await client.revoke(grantID: replaced.id, pairingID: replaced.pairingID) }
            let result: DevicePairing
            do {
                result = try await client.approve(pairing, permission: permission)
            } catch where replaced != nil && !(error is CancellationError) {
                throw PairingReplacementFailure()
            }
            for grant in older where grant.id != replaced?.id {
                try? await client.revoke(grantID: grant.id, pairingID: grant.pairingID)
            }
            let grants = try await client.grants()
            return .refreshed(result, grants)
        }
    }

    func reject() {
        guard let pairing, hasLivePairing else { return }
        run(String(localized: "Cancelling pairing…", bundle: .main)) { client in
            let result = try await client.reject(id: pairing.id)
            let grants = try await client.grants()
            return .refreshed(result, grants)
        }
    }

    func resetPairing() {
        suspend()
        pairing = nil
        invitation = nil
        preparedInvitation = nil
        issue = nil
        paused = false
    }

    func refresh() {
        guard issue?.integrityFailure != true else { return }
        guard client != nil, device != nil else { connect(); return }
        let id = pairing?.id
        run(String(localized: "Refreshing…", bundle: .main)) { client in
            var result: DevicePairing?
            if let id { result = try await client.pairing(id: id) }
            let grants = try await client.grants()
            return .refreshed(result, grants)
        }
    }

    func revoke(_ grant: DeviceGrant) {
        run(String(localized: "Unpairing…", bundle: .main)) { client in
            try await client.revoke(grantID: grant.id, pairingID: grant.pairingID)
            return .revoked(grant.id)
        }
    }

    func suspend() {
        generation += 1
        work?.cancel()
        polling?.cancel()
        work = nil
        polling = nil
        busy = nil
        paused = hasLivePairing
    }

    func resume() {
        guard !isWorking else { return }
        paused = false
        if client == nil || device == nil { connect() } else { refresh() }
    }

    private func run(_ label: String, operation: @escaping @MainActor (PairingClient) async throws -> Update) {
        guard !isWorking, let client else { return }
        polling?.cancel()
        generation += 1
        let expected = generation
        busy = label
        issue = nil
        paused = false
        work = Task { [weak self] in
            do {
                let update = try await operation(client)
                try Task.checkCancellation()
                guard let self, self.generation == expected else { return }
                self.apply(update)
                self.busy = nil
                self.work = nil
                self.startPolling()
            } catch {
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.busy = nil
                self.work = nil
                self.report(error)
            }
        }
    }

    private func apply(_ update: Update) {
        let previousStatus = pairing?.status
        switch update {
        case .connected(let device, let grants):
            self.device = device
            self.grants = grants
        case .created(let invitation, let pairing):
            self.invitation = invitation
            self.preparedInvitation = nil
            self.pairing = pairing
        case .refreshed(let pairing, let grants):
            self.pairing = pairing
            self.grants = grants
        case .revoked(let id):
            grants.removeAll { $0.id == id }
            if pairing?.grant?.id == id { pairing = nil }
        }
        if let pairing, pairing.status == .approved, pairing.grant != nil, previousStatus != .approved {
            successCount += 1
            AccessibilityNotification.Announcement(String(localized: "Pairing Confirmed", bundle: .main)).post()
        }
        if !hasLivePairing {
            invitation = nil
            // Foreground refreshes with no submitted request must not discard
            // an invitation being reviewed after scanning or pasting.
            if pairing != nil { preparedInvitation = nil }
        }
    }

    private func startPolling() {
        guard hasLivePairing, let id = pairing?.id, let client, !paused else { return }
        let expected = generation
        polling = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let pairing = try await client.pairing(id: id)
                    try Task.checkCancellation()
                    guard let self, self.generation == expected else { return }
                    if pairing.status == .approved || pairing.status == .rejected || pairing.status == .expired {
                        let grants = try await client.grants()
                        try Task.checkCancellation()
                        guard self.generation == expected else { return }
                        self.apply(.refreshed(pairing, grants))
                        return
                    }
                    self.pairing = pairing
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.report(error)
            }
        }
    }

    private func report(_ error: Error) {
        polling?.cancel()
        let issue = PairingIssue(error)
        self.issue = issue
        paused = hasLivePairing
        AccessibilityNotification.Announcement(issue.title + "。" + issue.recovery).post()
    }
}
