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

@MainActor @Observable
final class LocalTerminalModel {
    private(set) var sessions: [LocalSessionInfo] = []
    private(set) var selectedID: String?
    private(set) var attachment: LocalTerminalAttachment?
    private(set) var attachmentID = UUID()
    private(set) var mode = LocalAttachmentMode.control
    private(set) var busy: String?
    private(set) var issue: LocalTerminalIssue?
    private(set) var tmuxAvailable = true
    private(set) var ended = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var selectedSession: LocalSessionInfo? { sessions.first { $0.id == selectedID } }
    var isWorking: Bool { busy != nil }

    func refresh(using client: LocalAgentClient) {
        guard !isWorking else { return }
        begin(String(localized: "Checking local terminal…", bundle: .main)) { [weak self] expected in
            let status = try await client.status()
            let sessions = status.tmuxAvailable ? try await client.sessions() : []
            try Task.checkCancellation()
            guard let self, self.generation == expected else { return }
            self.tmuxAvailable = status.tmuxAvailable
            self.sessions = sessions
            if let selectedID = self.selectedID, !sessions.contains(where: { $0.id == selectedID }) {
                self.detach()
                self.selectedID = nil
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
                sessionID: session.id, columns: session.columns, rows: session.rows, mode: mode
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
