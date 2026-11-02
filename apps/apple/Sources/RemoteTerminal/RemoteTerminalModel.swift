#if os(iOS)
import Foundation
import Observation
import UIKit
import WitermCore

struct RemoteTerminalIssue {
    let title: String
    let recovery: String
    let canViewReadOnly: Bool
    /// Someone else is typing; the view names who, when the Mac says.
    let typingElsewhere: Bool

    init(_ error: Error) {
        let relay = error as? RelayError
        let local = error as? LocalAgentClientError
        canViewReadOnly = relay == .sessionBusy || relay == .readOnly
            || local == .rejected(.sessionBusy) || local == .rejected(.readOnly)
        typingElsewhere = relay == .sessionBusy || local == .rejected(.sessionBusy)
        if let error = error as? RelayError {
            switch error {
            case .offline:
                title = String(localized: "Device Is Offline", bundle: .main)
                recovery = String(localized: "Check that the other device is online and allows remote access.", bundle: .main)
            case .untrusted, .revoked:
                title = String(localized: "No Longer Paired", bundle: .main)
                recovery = String(localized: "This device was unpaired, or can’t be verified. To pair again, choose Open On ▸ New Device on the other device.", bundle: .main)
            case .unauthorized:
                title = String(localized: "Unable to Verify Device Identity", bundle: .main)
                recovery = String(localized: "Unlock your device and check the network, then try again.", bundle: .main)
            case .invalidMessage:
                title = String(localized: "Unable to Verify Terminal Connection", bundle: .main)
                recovery = String(localized: "Disconnected. Check that this device is still paired, then reconnect.", bundle: .main)
            case .transport, .unavailable:
                title = String(localized: "Terminal Connection Interrupted", bundle: .main)
                recovery = String(localized: "Check your network and the device, then reconnect.", bundle: .main)
            case .backpressure:
                title = String(localized: "Terminal Cannot Receive Input", bundle: .main)
                recovery = String(localized: "Reconnect to continue.", bundle: .main)
            case .readOnly:
                title = String(localized: "Can Only Watch", bundle: .main)
                recovery = String(localized: "This device can only watch this terminal. Choose Watch.", bundle: .main)
            case .sessionBusy:
                title = String(localized: "Typing on Another Device", bundle: .main)
                recovery = String(localized: "Watch, or try again when it stops typing.", bundle: .main)
            case .sessionUnavailable:
                title = String(localized: "Terminal Unavailable", bundle: .main)
                recovery = String(localized: "It ended, or this device can no longer open it. Pull down to refresh the list.", bundle: .main)
            }
        } else if let error = error as? LocalAgentClientError {
            switch error {
            case .rejected(.sessionBusy):
                title = String(localized: "Typing on Another Device", bundle: .main)
                recovery = String(localized: "Watch, or try again when it stops typing.", bundle: .main)
            case .rejected(.notFound):
                title = String(localized: "Terminal Unavailable", bundle: .main)
                recovery = String(localized: "It ended, or this device can no longer open it. Pull down to refresh the list.", bundle: .main)
            case .rejected(.readOnly):
                title = String(localized: "Can Only Watch", bundle: .main)
                recovery = String(localized: "This device can only watch this terminal. Choose Watch.", bundle: .main)
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

/// Where typing is, in the words a paired device can use. The Mac lists the
/// others who can type in a terminal (`writers`): another paired device by
/// name, or nil for the Mac itself. Older Macs don't list them, so the
/// wording falls back to "another device".
enum TypingElsewhere {
    /// The names of everyone else typing, the Mac by its paired name, each
    /// once; nil when the Mac didn't say.
    static func names(_ writers: [LocalWriterInfo]?, hostName: String) -> [String]? {
        guard let writers else { return nil }
        var names: [String] = []
        for writer in writers {
            let name = writer.name ?? hostName
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// "Typing on iPad", or nil when nobody else types or the Mac didn't say.
    static func summary(_ writers: [LocalWriterInfo]?, hostName: String) -> String? {
        guard let names = names(writers, hostName: hostName), !names.isEmpty else { return nil }
        let joined = names.formatted(.list(type: .and))
        return String(localized: "Typing on \(joined)", bundle: .main)
    }

    /// A terminal that refused typing because someone else types.
    static func busyTitle(_ writers: [LocalWriterInfo]?, hostName: String) -> String {
        summary(writers, hostName: hostName) ?? String(localized: "Typing on Another Device", bundle: .main)
    }

    /// A reconnect that found someone else typing and watched instead.
    static func watchingNotice(_ writers: [LocalWriterInfo]?, hostName: String) -> String {
        guard let summary = summary(writers, hostName: hostName) else {
            return String(localized: "Another device is typing, so you’re watching.", bundle: .main)
        }
        return String(localized: "\(summary), so you’re watching.", bundle: .main)
    }
}

enum RemoteTerminalConnectionState: Equatable {
    case browsing, connecting, connected, switching, disconnected, ended
}

@MainActor @Observable
final class RemoteTerminalModel {
    let serverAddress: String
    private(set) var grants: [DeviceGrant] = []
    /// One grant per device, however many pairings it has on this server:
    /// the one that can type if any can, then the newest. Lists show these;
    /// Unpair ends every pairing with the device.
    var devices: [DeviceGrant] { Self.devices(in: grants) }
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
    @ObservationIgnored private var opensSoleSession = false
    /// An automatic reconnect found someone else typing, so it watches
    /// instead; the view says who, from the latest list.
    private(set) var notice = false
    /// The grant being unpaired from this device, while that's under way.
    private(set) var unpairingID: String?
    /// The device whose pairing just ended while it was open here. Its
    /// terminal and list close at once, so Terminals says why until dismissed.
    private(set) var unpairedName: String?
    /// Whether the app is in the foreground. Reconnects wait for it.
    @ObservationIgnored private var appActive = true
    /// The terminal was interrupted by something the person didn't choose
    /// (the app went to the background or the network dropped), so it
    /// reconnects on its own once the app is active. Leaving, revocation,
    /// and a session ending never set it.
    @ObservationIgnored private var resumeWhenActive = false
    @ObservationIgnored private var automaticAttempts = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var grace: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
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
    var canRequestControl: Bool { selectedSession.map { access(for: $0) == .control } ?? false }

    /// What this device may do in a session: the Mac's policy for it, within
    /// the signed grant.
    func access(for session: LocalSessionInfo) -> LocalAttachmentMode {
        guard selectedGrant?.permission == .control else { return .view }
        return sessions.first { $0.id == session.id }?.access ?? session.access ?? .control
    }

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

    /// `openingSole` attaches at once when the device can open exactly one
    /// session, as after continuing a session from that device.
    func select(_ grant: DeviceGrant, openingSole: Bool = false) {
        guard busy == nil else { return }
        suspend()
        clearDisplay()
        unpairedName = nil
        selectedGrant = grant
        selectedSession = nil
        sessions = []
        opensSoleSession = openingSole
        // A grant approved just now is listed before the next device listing;
        // listing its sessions verifies it first, as for any grant.
        if !grants.contains(where: { $0.id == grant.id }) { grants.append(grant) }
        refreshSessions()
    }

    func refreshSessions() {
        guard busy == nil, let grant = selectedGrant, attachment == nil else { return }
        cancelWork()
        loaded = false
        do {
            let pairing = try pairingClient()
            let token = generation
            busy = String(localized: "Loading terminals…", bundle: .main)
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
                    if self.opensSoleSession, sessions.count == 1 {
                        self.opensSoleSession = false
                        self.attach(sessions[0])
                    }
                    self.opensSoleSession = false
                } catch { self?.failed(error, token: token) }
            }
        } catch { issue = RemoteTerminalIssue(error) }
    }

    func attach(_ session: LocalSessionInfo, mode requestedMode: LocalAttachmentMode? = nil) {
        attach(session, mode: requestedMode, automatic: false)
    }

    private func attach(_ session: LocalSessionInfo, mode requestedMode: LocalAttachmentMode?, automatic: Bool) {
        guard busy == nil, let grant = selectedGrant else { return }
        let allowed = access(for: session)
        if !automatic {
            automaticAttempts = 0
            notice = false
        }
        resumeWhenActive = false
        retry?.cancel(); retry = nil
        let targetMode = requestedMode ?? allowed
        guard allowed == .control || targetMode == .view else {
            issue = RemoteTerminalIssue(RelayError.readOnly)
            return
        }
        cancelWork()
        let previous = deactivate()
        // Typing or watching the same session, rather than opening another one.
        let changingMode = previous != nil && selectedSession?.id == session.id
        selectedSession = session
        reconnectMode = targetMode
        let switching = previous != nil
        connectionState = switching ? .switching : .connecting
        busy = changingMode ? (targetMode == .view ? String(localized: "Switching to Watching…", bundle: .main) : String(localized: "Switching to Typing…", bundle: .main)) : String(localized: "Opening terminal…", bundle: .main)
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
                        sessionID: session.id, columns: session.columns, rows: session.rows, mode: targetMode,
                        // Earlier output fills the renderer's scrollback, so a drag scrolls back through it.
                        history: true)
                    guard let self, self.generation == token, !Task.isCancelled else {
                        await next.abort()
                        return
                    }
                    // The attach reply carries the live grid; the listed access still applies.
                    // Who else types comes from the list, until the next one.
                    let writers = self.sessions.first { $0.id == next.session.id }?.writers ?? session.writers
                    let live = LocalSessionInfo(id: next.session.id, name: next.session.name, createdAt: next.session.createdAt,
                                                columns: next.session.columns, rows: next.session.rows, access: allowed,
                                                writers: writers)
                    self.selectedSession = live
                    self.sessions = self.sessions.map { $0.id == live.id ? live : $0 }
                    self.mode = targetMode
                    self.attachmentID = UUID()
                    self.activeID = self.attachmentID
                    self.displayAttachment = next
                    self.attachment = next
                    self.connectionState = .connected
                    self.busy = nil
                    self.work = nil
                    self.automaticAttempts = 0
                    // The title bar shows the new state; VoiceOver hears it.
                    if changingMode {
                        UIAccessibility.post(notification: .announcement, argument: targetMode == .view
                            ? String(localized: "Watching", bundle: .main) : String(localized: "Typing", bundle: .main))
                    }
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    // Coming back never takes control by force: when another
                    // device has it, watch instead and say so.
                    if automatic, targetMode == .control, Self.isBusy(error) {
                        self.busy = nil
                        self.work = nil
                        self.notice = true
                        self.attach(session, mode: .view, automatic: true)
                        return
                    }
                    self.failed(error, token: token, automatic: automatic)
                }
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
        failed(error, token: generation, allowCancelledCaller: true, automatic: true)
    }

    func attachmentEnded(id: UUID) {
        guard id == activeID else { return }
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        resumeWhenActive = false
        connectionState = .ended
        issue = nil
        if let id = selectedSession?.id { sessions.removeAll { $0.id == id } }
    }

    // MARK: Background and return

    /// How long a live terminal stays connected in the background, so a quick
    /// app switch costs nothing. It stays well inside the time iOS allows a
    /// background task, leaving room for the bounded detach that follows.
    static let backgroundGrace: Duration = .seconds(15)

    /// The app moved to the background. A live terminal keeps its connection
    /// for a short grace period, then detaches cleanly so another device can
    /// take control, and reconnects when the app returns.
    func enterBackground() {
        appActive = false
        retry?.cancel(); retry = nil
        guard attachment != nil, busy == nil else {
            // Interrupted mid-connect, or already disconnected by accident:
            // pick it up again on return.
            if displayAttachment != nil, connectionState != .ended, busy != nil || resumeWhenActive { resumeWhenActive = true }
            suspend()
            return
        }
        resumeWhenActive = true
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Witerm terminal") { [weak self] in
            // iOS is about to suspend the app: there is no time left for an
            // acknowledged detach, so close at once. The Mac releases control
            // when the connection closes.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.grace?.cancel(); self.grace = nil
                let resume = self.resumeWhenActive
                self.suspend()
                self.resumeWhenActive = resume
                self.endBackgroundTask()
            }
        }
        grace = Task { [weak self] in
            do { try await Task.sleep(for: Self.backgroundGrace) } catch { return }
            self?.detachForBackground()
        }
    }

    /// The app is active again: finish any background work and reconnect a
    /// terminal that was interrupted.
    func enterForeground() {
        appActive = true
        grace?.cancel(); grace = nil
        endBackgroundTask()
        resumeIfNeeded()
        // A list may have changed while away.
        if displayAttachment == nil, selectedGrant != nil, busy == nil { refreshSessions() }
    }

    private func detachForBackground() {
        grace = nil
        guard !appActive, busy == nil, let previous = deactivate() else { endBackgroundTask(); return }
        cancelWork()
        connectionState = .disconnected
        // Busy until the detach ACK, so returning mid-release reconnects only
        // after the Mac has let go of the old connection.
        busy = String(localized: "Leaving…", bundle: .main)
        let token = generation
        work = Task { [weak self] in
            // A failed release leaves nothing to resend; the Mac also
            // releases control when this connection closes.
            do { try await previous.detach() } catch { await previous.abort() }
            guard let self, self.generation == token else { return }
            self.busy = nil
            self.work = nil
            self.endBackgroundTask()
            self.resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard appActive, resumeWhenActive, attachment == nil, busy == nil, displayAttachment != nil,
              canReconnect, let session = selectedSession else { return }
        resumeWhenActive = false
        attach(session, mode: reconnectMode, automatic: true)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Network and relay interruptions are retried a few times with growing
    /// pauses while the app is active. Anything about trust, permission or
    /// the session itself waits for the person.
    private func scheduleAutomaticReconnect(after error: Error) {
        guard Self.isTransient(error), displayAttachment != nil, connectionState != .ended,
              selectedSession != nil else { return }
        guard appActive else { resumeWhenActive = true; return }
        guard automaticAttempts < 4 else { return }
        automaticAttempts += 1
        let delay = Duration.seconds(1 << (automaticAttempts - 1))
        let token = generation
        retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == token, self.appActive else { return }
            self.retry = nil
            self.resumeWhenActive = true
            self.resumeIfNeeded()
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let relay = error as? RelayError {
            return [.offline, .transport, .unavailable, .backpressure].contains(relay)
        }
        if error is URLError { return true }
        if let local = error as? LocalAgentClientError, case .rejected = local { return false }
        return error is LocalAgentClientError
    }

    private static func isBusy(_ error: Error) -> Bool {
        (error as? RelayError) == .sessionBusy || (error as? LocalAgentClientError) == .rejected(.sessionBusy)
    }

    func dismissNotice() { notice = false }

    /// Who else can type in the open terminal, as of the latest list.
    var openWriters: [LocalWriterInfo]? {
        guard let id = selectedSession?.id else { return nil }
        return sessions.first { $0.id == id }?.writers
    }

    /// Lists the device's terminals again only to learn who else types in
    /// the one being watched, so its title can say where typing is. Changes
    /// nothing else; false when the list couldn't be had.
    @discardableResult
    func refreshWriters() async -> Bool {
        guard isInteractive, mode == .view, canRequestControl, let grant = selectedGrant,
              let id = selectedSession?.id, let pairing else { return false }
        let token = generation
        guard let listed = try? await RemoteTerminalClient(pairing: pairing, grantID: grant.id).sessions() else { return false }
        guard generation == token, selectedGrant?.id == grant.id, selectedSession?.id == id else { return false }
        sessions = sessions.map { session in
            guard let fresh = listed.first(where: { $0.id == session.id }) else { return session }
            return LocalSessionInfo(id: session.id, name: session.name, createdAt: session.createdAt, columns: session.columns,
                                    rows: session.rows, access: session.access, writers: fresh.writers)
        }
        return true
    }

    /// Ends this device's pairing with `grant`'s device, through the server
    /// (either side may). A terminal open from it is left first, after the
    /// detach ACK; then it leaves the lists. Throws when the server wasn't
    /// told, leaving the device listed so Unpair can be tried again.
    func unpair(_ grant: DeviceGrant) async throws {
        guard unpairingID == nil else { return }
        unpairingID = grant.id
        defer { unpairingID = nil }
        let pairing = try pairingClient()
        // Every pairing with that device ends, so it leaves the lists: an
        // earlier one that was never cleaned up would otherwise keep it there.
        let ending = Self.pairings(endedBy: grant, in: grants)
        if let selected = selectedGrant, ending.contains(where: { $0.id == selected.id }) {
            cancelWork()
            resumeWhenActive = false
            notice = false
            if let previous = deactivate() {
                connectionState = .disconnected
                busy = String(localized: "Leaving…", bundle: .main)
                do { try await previous.detach() } catch { await previous.abort() }
                busy = nil
            }
            clearDisplay()
            selectedSession = nil
            sessions = []
            selectedGrant = nil
            connectionState = .browsing
        }
        for pairingToEnd in ending {
            try await pairing.revoke(grantID: pairingToEnd.id, pairingID: pairingToEnd.pairingID)
            grants.removeAll { $0.id == pairingToEnd.id }
        }
        if unpairedName == grant.host.name { unpairedName = nil }
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "Unpaired from \(grant.host.name)", bundle: .main))
    }

    /// The pairings Unpair ends: `grant` and any other this device holds with
    /// the same device, the one asked for first.
    /// Groups pairings by device, in the order devices first appear.
    static func devices(in grants: [DeviceGrant]) -> [DeviceGrant] {
        var order: [String] = []
        var best: [String: DeviceGrant] = [:]
        func rank(_ grant: DeviceGrant) -> (Int, Date) { (grant.permission == .control ? 1 : 0, grant.createdAt) }
        for grant in grants {
            if let current = best[grant.host.id] {
                if rank(grant) > rank(current) { best[grant.host.id] = grant }
            } else {
                order.append(grant.host.id)
                best[grant.host.id] = grant
            }
        }
        return order.compactMap { best[$0] }
    }

    static func pairings(endedBy grant: DeviceGrant, in grants: [DeviceGrant]) -> [DeviceGrant] {
        [grant] + grants.filter { $0.id != grant.id && $0.host.id == grant.host.id }
    }

    /// Back to the device's terminals. An open terminal is left first (it
    /// keeps running there), and the list shows after the detach ACK.
    func showSessions() {
        guard busy == nil else { return }
        resumeWhenActive = false
        notice = false
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
        busy = String(localized: "Leaving…", bundle: .main)
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
        retry?.cancel()
        retry = nil
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
        resumeWhenActive = false
        displayAttachment = nil
        attachmentID = UUID()
    }

    private func failed(_ error: Error, token: Int, allowCancelledCaller: Bool = false, automatic: Bool = false) {
        guard generation == token, allowCancelledCaller || !Task.isCancelled else { return }
        busy = nil
        work = nil
        if Self.isTrustFailure(error) {
            authorizationUnavailable()
            return
        }
        if displayAttachment != nil { connectionState = .disconnected }
        issue = RemoteTerminalIssue(error)
        if automatic { scheduleAutomaticReconnect(after: error) }
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

    func dismissUnpaired() { unpairedName = nil }

    private func authorizationUnavailable() {
        resumeWhenActive = false
        notice = false
        if let name = selectedGrant?.host.name {
            unpairedName = name
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "No Longer Paired with \(name)", bundle: .main))
        }
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
        let client = try PairingClient(serverAddress: serverAddress, deviceName: PairingDeviceName.current, platform: .ios)
        pairing = client
        return client
    }
}

/// The name this device pairs under, which the other device shows (in its
/// Open On menu, for one).
enum PairingDeviceName {
    static var current: String {
        let clean = UIDevice.current.name.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView((clean.isEmpty ? String(localized: "My iPhone", bundle: .main) : clean).unicodeScalars.prefix(64)))
    }
}
#endif
