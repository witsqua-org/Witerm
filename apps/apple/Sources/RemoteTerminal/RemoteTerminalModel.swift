#if os(iOS)
import Foundation
import Observation
import UIKit
import WitermCore

struct RemoteTerminalIssue {
    let title: String
    let recovery: String
    let canViewReadOnly: Bool

    init(_ error: Error) {
        let relay = error as? RelayError
        let local = error as? LocalAgentClientError
        canViewReadOnly = relay == .sessionBusy || relay == .readOnly
            || local == .rejected(.sessionBusy) || local == .rejected(.readOnly)
        if let error = error as? RelayError {
            switch error {
            case .offline:
                title = String(localized: "Device Is Offline", bundle: .main)
                recovery = String(localized: "Check that the device is online and allows Witerm remote access.", bundle: .main)
            case .untrusted, .revoked:
                title = String(localized: "Device Access Unavailable", bundle: .main)
                recovery = String(localized: "Check the device’s authorization in Device Pairing.", bundle: .main)
            case .unauthorized:
                title = String(localized: "Unable to Verify Device Identity", bundle: .main)
                recovery = String(localized: "Unlock your device and check the network, then try again.", bundle: .main)
            case .invalidMessage:
                title = String(localized: "Unable to Verify Terminal Connection", bundle: .main)
                recovery = String(localized: "Disconnected. Check device authorization, then reconnect.", bundle: .main)
            case .transport, .unavailable:
                title = String(localized: "Terminal Connection Interrupted", bundle: .main)
                recovery = String(localized: "Check your network and the device, then reconnect.", bundle: .main)
            case .backpressure:
                title = String(localized: "Terminal Cannot Receive Input", bundle: .main)
                recovery = String(localized: "Reconnect to continue.", bundle: .main)
            case .readOnly:
                title = String(localized: "View-Only Connection", bundle: .main)
                recovery = String(localized: "Use View Only, or authorize control again on the device.", bundle: .main)
            case .sessionBusy:
                title = String(localized: "Session Is Being Controlled", bundle: .main)
                recovery = String(localized: "View only, or reconnect after the other device disconnects.", bundle: .main)
            }
        } else if let error = error as? LocalAgentClientError {
            switch error {
            case .rejected(.sessionBusy):
                title = String(localized: "Session Is Being Controlled", bundle: .main)
                recovery = String(localized: "Use View Only, or reconnect after the other device disconnects.", bundle: .main)
            case .rejected(.notFound):
                title = String(localized: "Session Unavailable", bundle: .main)
                recovery = String(localized: "Refresh the list and check that the session still exists on the device.", bundle: .main)
            case .rejected(.readOnly):
                title = String(localized: "View-Only Connection", bundle: .main)
                recovery = String(localized: "Use View Only.", bundle: .main)
            default:
                title = String(localized: "Terminal Connection Interrupted", bundle: .main)
                recovery = String(localized: "Check the terminal service on the device, then try again.", bundle: .main)
            }
        } else {
            let issue = PairingIssue(error)
            title = issue.title
            recovery = issue.recovery
        }
    }
}

enum RemoteTerminalConnectionState: Equatable {
    case browsing, connecting, connected, switching, disconnected, ended
}

@MainActor @Observable
final class RemoteTerminalModel {
    let serverAddress: String
    private(set) var grants: [DeviceGrant] = []
    private(set) var selectedGrant: DeviceGrant?
    private(set) var sessions: [LocalSessionInfo] = []
    private(set) var selectedSession: LocalSessionInfo?
    private(set) var attachment: RemoteTerminalAttachment?
    // The renderer retains only its in-memory last frame after a disconnect.
    private(set) var displayAttachment: RemoteTerminalAttachment?
    private(set) var attachmentID = UUID()
    private(set) var mode: LocalAttachmentMode = .view
    private(set) var reconnectMode: LocalAttachmentMode = .view
    private(set) var connectionState: RemoteTerminalConnectionState = .browsing
    private(set) var busy: String?
    private(set) var issue: RemoteTerminalIssue?
    private(set) var loaded = false
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var pairing: PairingClient?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var authorizationCheck: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(serverAddress: String) { self.serverAddress = serverAddress }

    var isInteractive: Bool { attachment != nil && connectionState == .connected && busy == nil }
    var canReconnect: Bool {
        selectedGrant != nil && selectedSession != nil && busy == nil && connectionState != .ended
    }
    var canRequestControl: Bool { selectedGrant?.permission == .control }

    func loadDevices() {
        suspend()
        clearDisplay()
        selectedGrant = nil
        selectedSession = nil
        sessions = []
        grants = []
        loaded = false
        connectionState = .browsing
        do {
            let pairing = try pairingClient()
            let token = generation
            busy = String(localized: "Loading paired devices…", bundle: .main)
            issue = nil
            work = Task { [weak self] in
                do {
                    _ = try await pairing.register()
                    let candidates = try await pairing.grants()
                    var verified: [DeviceGrant] = []
                    for candidate in candidates {
                        try Task.checkCancellation()
                        do {
                            let grant = try await pairing.trustedRelayGrant(id: candidate.id)
                            guard grant.host.platform == .macos else { continue }
                            verified.append(grant)
                        } catch RelayError.untrusted { continue }
                        catch RelayError.revoked { continue }
                    }
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.grants = verified
                    self.loaded = true
                    self.busy = nil
                    self.work = nil
                } catch { self?.failed(error, token: token) }
            }
        } catch { issue = RemoteTerminalIssue(error) }
    }

    func select(_ grant: DeviceGrant) {
        guard busy == nil else { return }
        suspend()
        clearDisplay()
        selectedGrant = grant
        selectedSession = nil
        sessions = []
        refreshSessions()
    }

    func refreshSessions() {
        guard busy == nil, let grant = selectedGrant, attachment == nil else { return }
        cancelWork()
        loaded = false
        do {
            let pairing = try pairingClient()
            let token = generation
            busy = String(localized: "Loading terminal sessions…", bundle: .main)
            issue = nil
            work = Task { [weak self] in
                do {
                    let grants = try await pairing.grants()
                    guard grants.contains(where: { $0.id == grant.id }) else { throw RelayError.revoked }
                    _ = try await pairing.trustedRelayGrant(id: grant.id)
                    let sessions = try await RemoteTerminalClient(pairing: pairing, grantID: grant.id).sessions()
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.sessions = sessions
                    self.loaded = true
                    self.busy = nil
                    self.work = nil
                    if let selected = self.selectedSession, !sessions.contains(where: { $0.id == selected.id }) {
                        self.selectedSession = nil
                    }
                } catch { self?.failed(error, token: token) }
            }
        } catch { issue = RemoteTerminalIssue(error) }
    }

    func attach(_ session: LocalSessionInfo, mode requestedMode: LocalAttachmentMode? = nil) {
        guard busy == nil, let grant = selectedGrant else { return }
        let targetMode = requestedMode ?? (grant.permission == .view ? .view : .control)
        guard grant.permission == .control || targetMode == .view else {
            issue = RemoteTerminalIssue(RelayError.readOnly)
            return
        }
        cancelWork()
        let previous = deactivate()
        selectedSession = session
        reconnectMode = targetMode
        let switching = previous != nil
        connectionState = switching ? .switching : .connecting
        busy = switching ? (targetMode == .view ? String(localized: "Releasing control…", bundle: .main) : String(localized: "Requesting control…", bundle: .main)) : String(localized: "Connecting to terminal…", bundle: .main)
        issue = nil
        do {
            let pairing = try pairingClient()
            let token = generation
            work = Task { [weak self] in
                do {
                    // A detach ACK confirms the host released the old controller.
                    // A failed release never silently proceeds to a new controller.
                    if let previous { try await previous.detach() }
                    try Task.checkCancellation()
                    _ = try await pairing.trustedRelayGrant(id: grant.id)
                    let next = try await RemoteTerminalClient(pairing: pairing, grantID: grant.id).attach(
                        sessionID: session.id, columns: session.columns, rows: session.rows, mode: targetMode)
                    guard let self, self.generation == token, !Task.isCancelled else {
                        await next.abort()
                        return
                    }
                    self.selectedSession = next.session
                    self.sessions = self.sessions.map { $0.id == next.session.id ? next.session : $0 }
                    self.mode = targetMode
                    self.attachmentID = UUID()
                    self.activeID = self.attachmentID
                    self.displayAttachment = next
                    self.attachment = next
                    self.connectionState = .connected
                    self.busy = nil
                    self.work = nil
                } catch { self?.failed(error, token: token) }
            }
        } catch {
            if let previous { Task { await previous.abort() } }
            failed(error, token: generation)
        }
    }

    func switchMode() {
        guard isInteractive, canRequestControl, let session = selectedSession else { return }
        attach(session, mode: mode == .control ? .view : .control)
    }

    func reconnect(as requestedMode: LocalAttachmentMode? = nil) {
        guard canReconnect, let session = selectedSession else { return }
        attach(session, mode: requestedMode ?? reconnectMode)
    }

    func attachmentFailed(_ error: Error, id: UUID) {
        guard id == activeID else { return }
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        // Renderer shutdown cancels its callback task. The active attachment
        // identity, rather than that task's cancellation bit, owns this event.
        failed(error, token: generation, allowCancelledCaller: true)
    }

    func attachmentEnded(id: UUID) {
        guard id == activeID else { return }
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        connectionState = .ended
        issue = nil
        if let id = selectedSession?.id { sessions.removeAll { $0.id == id } }
    }

    func disconnect() {
        guard busy == nil, let previous = deactivate() else { return }
        cancelWork()
        connectionState = .disconnected
        busy = String(localized: "Disconnecting…", bundle: .main)
        issue = nil
        let token = generation
        work = Task { [weak self] in
            do {
                try await previous.detach()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.busy = nil
                self.work = nil
            } catch { self?.failed(error, token: token) }
        }
    }

    func showSessions() {
        guard busy == nil else { return }
        let previous = deactivate()
        cancelWork()
        issue = nil
        guard let previous else {
            clearDisplay()
            selectedSession = nil
            connectionState = .browsing
            refreshSessions()
            return
        }
        // Keep the noninteractive renderer until the detach ACK; dismantling
        // its output consumer first can race the release handshake.
        connectionState = .disconnected
        let token = generation
        busy = String(localized: "Disconnecting…", bundle: .main)
        work = Task { [weak self] in
            do {
                try await previous.detach()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.clearDisplay()
                self.selectedSession = nil
                self.connectionState = .browsing
                self.busy = nil
                self.work = nil
                self.refreshSessions()
            } catch { self?.failed(error, token: token) }
        }
    }

    func suspend() {
        cancelWork()
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        if displayAttachment != nil, connectionState != .ended { connectionState = .disconnected }
    }

    func cancelWork() {
        generation += 1
        work?.cancel()
        authorizationCheck?.cancel()
        work = nil
        authorizationCheck = nil
        busy = nil
        if attachment == nil, displayAttachment != nil, connectionState != .ended {
            connectionState = .disconnected
        }
    }

    private func deactivate() -> RemoteTerminalAttachment? {
        let previous = attachment
        attachment = nil
        activeID = nil
        return previous
    }

    private func clearDisplay() {
        displayAttachment = nil
        attachmentID = UUID()
    }

    private func failed(_ error: Error, token: Int, allowCancelledCaller: Bool = false) {
        guard generation == token, allowCancelledCaller || !Task.isCancelled else { return }
        busy = nil
        work = nil
        if Self.isTrustFailure(error) {
            authorizationUnavailable()
            return
        }
        if displayAttachment != nil { connectionState = .disconnected }
        issue = RemoteTerminalIssue(error)
        // A peer-side revoke closes the transport. Refresh signed grants so the
        // UI removes stale reconnect actions rather than misreporting an outage.
        guard let grant = selectedGrant, let pairing else { return }
        authorizationCheck = Task { [weak self] in
            do {
                let latest = try await pairing.grants()
                guard let self, self.generation == token, self.selectedGrant?.id == grant.id,
                      !Task.isCancelled else { return }
                if !latest.contains(where: { $0.id == grant.id }) { self.authorizationUnavailable() }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if Self.isTrustFailure(error) { self.authorizationUnavailable() }
            }
        }
    }

    private static func isTrustFailure(_ error: Error) -> Bool {
        if let relay = error as? RelayError { return relay == .revoked || relay == .untrusted }
        return (error as? PairingClientError) == .invalidProof
    }

    private func authorizationUnavailable() {
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        if let id = selectedGrant?.id { grants.removeAll { $0.id == id } }
        selectedGrant = nil
        selectedSession = nil
        sessions = []
        clearDisplay()
        connectionState = .browsing
        loaded = true
        busy = nil
        issue = RemoteTerminalIssue(RelayError.revoked)
    }

    private func pairingClient() throws -> PairingClient {
        if let pairing { return pairing }
        let clean = UIDevice.current.name.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(String.UnicodeScalarView((clean.isEmpty ? String(localized: "My iPhone", bundle: .main) : clean).unicodeScalars.prefix(64)))
        let client = try PairingClient(serverAddress: serverAddress, deviceName: name, platform: .ios)
        pairing = client
        return client
    }
}
#endif
