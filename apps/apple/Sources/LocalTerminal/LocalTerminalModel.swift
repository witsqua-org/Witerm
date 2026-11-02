#if os(macOS)
import Accessibility
import Foundation
import Observation
import WitermCore

struct LocalTerminalIssue: Equatable {
    let title: String
    let recovery: String
    let canViewReadOnly: Bool

    init(_ error: Error) {
        canViewReadOnly = (error as? LocalAgentClientError) == .rejected(.sessionBusy)
            || (error as? LocalAgentClientError) == .rejected(.readOnly)
        switch error as? LocalAgentClientError {
        case .rejected(.sessionBusy):
            title = String(localized: "Session Is in Use Elsewhere", bundle: .main)
            recovery = String(localized: "View only, or try again after disconnecting elsewhere.", bundle: .main)
        case .rejected(.readOnly):
            title = String(localized: "This Connection Is View Only", bundle: .main)
            recovery = String(localized: "Reconnect in view-only mode.", bundle: .main)
        case .rejected(.dependencyMissing):
            title = String(localized: "tmux Required", bundle: .main)
            recovery = String(localized: "Install tmux, then check the local terminal again.", bundle: .main)
        case .rejected(.notFound):
            title = String(localized: "Session Ended", bundle: .main)
            recovery = String(localized: "Choose another session or create a new one.", bundle: .main)
        case .unsafeSocket:
            title = String(localized: "Unable to Verify Local Service", bundle: .main)
            recovery = String(localized: "Disable and reenable the local terminal.", bundle: .main)
        case .backpressure, .rejected(.backpressure):
            title = String(localized: "Terminal Connection Interrupted", bundle: .main)
            recovery = String(localized: "Reconnect; paste long input in smaller sections.", bundle: .main)
        case .rejected(.invalidRequest):
            title = String(localized: "Unable to Complete This Action", bundle: .main)
            recovery = String(localized: "Check the session name and count, then refresh and try again.", bundle: .main)
        case .rejected(.unsupportedVersion), .invalidResponse:
            title = String(localized: "Unrecognized Local Service Response", bundle: .main)
            recovery = String(localized: "Update the app, then reenable the local terminal.", bundle: .main)
        default:
            title = String(localized: "Unable to Connect to Local Terminal", bundle: .main)
            recovery = String(localized: "Check that the local service is enabled, then try again.", bundle: .main)
        }
    }
}

extension LocalSessionInfo {
    /// Other devices attached to this session now, each named once.
    var remoteDeviceNames: [String] {
        var seen = Set<String>()
        return (sharing?.attachments ?? []).compactMap(\.device)
            .filter { seen.insert($0.deviceID).inserted }
            .map(\.name)
    }
}

@MainActor @Observable
final class LocalTerminalModel {
    private(set) var sessions: [LocalSessionInfo] = [] {
        didSet { activities = activities.filter { id, _ in sessions.contains { $0.id == id } } }
    }
    private(set) var selectedID: String?
    private(set) var attachment: LocalTerminalAttachment?
    private(set) var attachmentID = UUID()
    private(set) var mode = LocalAttachmentMode.control
    private(set) var busy: String?
    private(set) var issue: LocalTerminalIssue?
    private(set) var tmuxAvailable = true
    private(set) var ended = false
    /// Remote access per server; empty when Allow Remote Access is off.
    private(set) var relays: [LocalRelayStatus] = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// What each session was last seen doing while shown here. Memory only.
    @ObservationIgnored private var activities: [String: TerminalActivity] = [:]

    var selectedSession: LocalSessionInfo? { sessions.first { $0.id == selectedID } }

    func activity(for sessionID: String) -> TerminalActivity {
        if let existing = activities[sessionID] { return existing }
        let created = TerminalActivity()
        activities[sessionID] = created
        return created
    }
    var isWorking: Bool { busy != nil }

    func refresh(using client: LocalAgentClient) {
        guard !isWorking else { return }
        begin(String(localized: "Checking local terminal…", bundle: .main)) { [weak self] expected in
            let status = try await client.status()
            let sessions = status.tmuxAvailable ? try await client.sessions() : []
            try Task.checkCancellation()
            guard let self, self.generation == expected else { return }
            self.tmuxAvailable = status.tmuxAvailable
            self.relays = status.relays ?? []
            self.sessions = sessions
            if let selectedID = self.selectedID, !sessions.contains(where: { $0.id == selectedID }) {
                self.detach()
                self.selectedID = nil
            }
        }
    }

    /// Keeps the list current while the window is open, so sessions started
    /// from the command line, sharing, and who is attached appear on their own.
    func watch(using client: LocalAgentClient) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.quietRefresh(client)
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func quietRefresh(_ client: LocalAgentClient) async {
        guard !isWorking, let status = try? await client.status() else { return }
        let relays = status.relays ?? []
        if relays != self.relays { self.relays = relays }
        guard status.tmuxAvailable, tmuxAvailable, let sessions = try? await client.sessions(),
              !isWorking, !Task.isCancelled else { return }
        if sessions != self.sessions { self.sessions = sessions }
        // A session ended elsewhere; an open terminal learns that from its own stream.
        if let selectedID, attachment == nil, !sessions.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    /// Lets paired devices reach a session, or stops it. Stopping disconnects
    /// them; the session keeps running.
    func setShared(_ session: LocalSessionInfo, _ shared: Bool, using client: LocalAgentClient) {
        Task { [weak self] in
            do {
                let updated = try await client.share(sessionID: session.id, shared: shared)
                guard let self else { return }
                self.sessions = self.sessions.map { $0.id == updated.id ? updated : $0 }
                AccessibilityNotification.Announcement(shared
                    ? String(localized: "Session Shared", bundle: .main)
                    : String(localized: "Sharing Stopped", bundle: .main)).post()
            } catch {
                self?.report(error)
            }
        }
    }

    /// Keeps a session from every paired device, or pauses their typing in
    /// it. Either disconnects the remote attachments it no longer allows.
    func configure(_ session: LocalSessionInfo, keepPrivate: Bool? = nil, remoteTyping: Bool? = nil,
                   using client: LocalAgentClient) {
        Task { [weak self] in
            do {
                let updated = try await client.configure(sessionID: session.id, keepPrivate: keepPrivate, remoteTyping: remoteTyping)
                guard let self else { return }
                self.sessions = self.sessions.map { $0.id == updated.id ? updated : $0 }
                let announcement: String
                if let keepPrivate {
                    announcement = keepPrivate ? String(localized: "Session Kept Private", bundle: .main)
                        : String(localized: "Session Available to Paired Devices", bundle: .main)
                } else {
                    announcement = remoteTyping == false ? String(localized: "Remote Typing Paused", bundle: .main)
                        : String(localized: "Remote Typing Allowed", bundle: .main)
                }
                AccessibilityNotification.Announcement(announcement).post()
            } catch {
                self?.report(error)
            }
        }
    }

    /// Renaming changes only the display name; the shell and attachments stay.
    func rename(_ session: LocalSessionInfo, to name: String, using client: LocalAgentClient) {
        Task { [weak self] in
            do {
                let updated = try await client.rename(sessionID: session.id, to: name)
                guard let self else { return }
                self.sessions = self.sessions.map { $0.id == updated.id ? updated : $0 }
                AccessibilityNotification.Announcement(String(localized: "Session Renamed", bundle: .main)).post()
            } catch {
                self?.report(error)
            }
        }
    }

    func create(name: String, using client: LocalAgentClient) {
        guard !isWorking else { return }
        begin(String(localized: "Creating session…", bundle: .main)) { [weak self] expected in
            let session = try await client.create(name: name)
            let sessions = try await client.sessions()
            try Task.checkCancellation()
            guard let self, self.generation == expected else { return }
            self.sessions = sessions
            self.selectedID = session.id
            self.busy = nil
            self.attach(session, using: client, mode: .control)
        }
    }

    func select(_ id: String?, using client: LocalAgentClient) {
        guard !isWorking, let id, let session = sessions.first(where: { $0.id == id }) else { return }
        if id == selectedID, attachment != nil { return }
        selectedID = id
        attach(session, using: client, mode: .control)
    }

    func attach(_ session: LocalSessionInfo, using client: LocalAgentClient, mode: LocalAttachmentMode) {
        let previous = attachment
        attachment = nil
        attachmentID = UUID()
        selectedID = session.id
        self.mode = mode
        ended = false
        begin(String(localized: "Connecting to session…", bundle: .main)) { [weak self] expected in
            await previous?.disconnect()
            try Task.checkCancellation()
            let attachment = try await client.attach(
                sessionID: session.id, columns: session.columns, rows: session.rows, mode: mode,
                // The renderer keeps its own scrollback, starting with earlier output.
                history: true
            )
            guard !Task.isCancelled, let self, self.generation == expected else {
                await attachment.disconnect()
                return
            }
            self.attachment = attachment
            self.attachmentID = UUID()
        }
    }

    func close(_ session: LocalSessionInfo, using client: LocalAgentClient) {
        guard !isWorking else { return }
        if selectedID == session.id { detach() }
        begin(String(localized: "Ending session…", bundle: .main)) { [weak self] expected in
            try await client.close(sessionID: session.id)
            let sessions = try await client.sessions()
            try Task.checkCancellation()
            guard let self, self.generation == expected else { return }
            self.sessions = sessions
            if self.selectedID == session.id { self.selectedID = nil }
            AccessibilityNotification.Announcement(String(localized: "Session Ended", bundle: .main)).post()
        }
    }

    func detach() {
        generation += 1
        work?.cancel()
        work = nil
        busy = nil
        let previous = attachment
        attachment = nil
        attachmentID = UUID()
        if let previous { Task { await previous.disconnect() } }
    }

    func serviceUnavailable() {
        detach()
        sessions = []
        selectedID = nil
    }

    func attachmentFailed(_ error: Error, id: UUID) {
        guard attachmentID == id else { return }
        detach()
        report(error)
    }

    func attachmentEnded(id: UUID, client: LocalAgentClient) {
        guard attachmentID == id else { return }
        detach()
        ended = true
        refresh(using: client)
    }

    private func begin(_ label: String, operation: @escaping @MainActor (Int) async throws -> Void) {
        work?.cancel()
        generation += 1
        let expected = generation
        busy = label
        issue = nil
        work = Task { [weak self] in
            do {
                try await operation(expected)
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.busy = nil
                self.work = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.busy = nil
                self.work = nil
                self.report(error)
            }
        }
    }

    private func report(_ error: Error) {
        if (error as? LocalAgentClientError) == .rejected(.dependencyMissing) { tmuxAvailable = false }
        let issue = LocalTerminalIssue(error)
        self.issue = issue
        AccessibilityNotification.Announcement(issue.title + "。" + issue.recovery).post()
    }
}
#endif
