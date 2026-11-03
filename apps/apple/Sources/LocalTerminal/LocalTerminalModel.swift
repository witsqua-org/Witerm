#if os(macOS)
import Accessibility
import Foundation
import Observation
import WitermCore

/// The terminal printed faster than this window's renderer took it in, so
/// the background service ended the attachment rather than drop output.
struct LocalOutputOverflow: Error {}

struct LocalTerminalIssue: Equatable {
    let title: String
    let recovery: String
    let canViewReadOnly: Bool

    init(_ error: Error) {
        canViewReadOnly = (error as? LocalAgentClientError) == .rejected(.sessionBusy)
            || (error as? LocalAgentClientError) == .rejected(.readOnly)
        if error is LocalOutputOverflow {
            // Not a paste: say what happened, and that nothing stopped.
            title = String(localized: "Terminal Interrupted", bundle: .main)
            recovery = String(localized: "It printed faster than this window could show. Open it again; it kept running.", bundle: .main)
            return
        }
        switch error as? LocalAgentClientError {
        case .rejected(.sessionBusy):
            title = String(localized: "Typing Somewhere Else", bundle: .main)
            recovery = String(localized: "Watch for now, or stop typing there first.", bundle: .main)
        case .rejected(.readOnly):
            title = String(localized: "Can Only Watch", bundle: .main)
            recovery = String(localized: "Watch this terminal instead.", bundle: .main)
        case .rejected(.dependencyMissing):
            title = String(localized: "tmux Required", bundle: .main)
            recovery = String(localized: "Install tmux, then choose Check Again.", bundle: .main)
        case .rejected(.notFound):
            title = String(localized: "Terminal Ended", bundle: .main)
            recovery = String(localized: "Choose another terminal or start a new one.", bundle: .main)
        case .unsafeSocket:
            title = String(localized: "Can’t Verify Terminals on This Mac", bundle: .main)
            recovery = String(localized: "Turn terminals off and on again in Settings → General.", bundle: .main)
        case .backpressure, .rejected(.backpressure):
            title = String(localized: "Terminal Interrupted", bundle: .main)
            recovery = String(localized: "Open it again. Paste long text in smaller parts.", bundle: .main)
        case .rejected(.invalidRequest):
            title = String(localized: "Unable to Complete This Action", bundle: .main)
            recovery = String(localized: "Check the terminal’s name, or end one you don’t need (16 at most).", bundle: .main)
        case .rejected(.unsupportedVersion), .invalidResponse:
            title = String(localized: "Terminals on This Mac Need an Update", bundle: .main)
            recovery = String(localized: "Update Witerm, then turn terminals off and on again in Settings → General.", bundle: .main)
        default:
            title = String(localized: "Can’t Open the Terminal", bundle: .main)
            recovery = String(localized: "Check that terminals are on in Settings → General, then try again.", bundle: .main)
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

    /// Where else this terminal is open, in the shared words: "Typing on
    /// iPhone", "Watching on iPad", and "Typing in another window" for a
    /// second typist on this Mac (such as `witerm attach`). `here` is how this
    /// window has it open, if it does, so its own attachment isn't counted.
    /// `switchedFrom` is how this window had it open just before a switch
    /// between typing and watching, while the listing may still show that
    /// earlier attachment: it's this window's own, never another one's.
    func elsewhere(here: LocalAttachmentMode?, switchedFrom: LocalAttachmentMode? = nil) -> [String] {
        let attachments = sharing?.attachments ?? []
        var typing: [String] = [], watching: [String] = [], seen = Set<String>()
        // A device typing anywhere counts as typing, whatever else it has open.
        for attachment in attachments.sorted(by: { $0.mode == .control && $1.mode != .control }) {
            guard let device = attachment.device, seen.insert(device.deviceID).inserted else { continue }
            if attachment.mode == .control { typing.append(device.name) } else { watching.append(device.name) }
        }
        var phrases = typing.map { String(localized: "Typing on \($0)", bundle: .main) }
        let own = (here == .control ? 1 : 0) + (switchedFrom == .control && here != .control ? 1 : 0)
        let localTypists = attachments.filter { $0.device == nil && $0.mode == .control }.count - own
        if localTypists > 0 { phrases.append(String(localized: "Typing in another window", bundle: .main)) }
        phrases += watching.map { String(localized: "Watching on \($0)", bundle: .main) }
        return phrases
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
    /// The mode this window had before its last switch between typing and
    /// watching, until a listing fetched after the switch replaces the one
    /// that still shows the earlier attachment. Never someone else's.
    private(set) var switchedFrom: LocalAttachmentMode?
    private(set) var busy: String?
    private(set) var issue: LocalTerminalIssue?
    private(set) var tmuxAvailable = true
    private(set) var ended = false
    /// Remote access per server; empty when Allow Remote Access is off.
    private(set) var relays: [LocalRelayStatus] = []
    /// Each change asks the shown terminal for keyboard focus.
    private(set) var focusRequest = 0
    /// Whether the next terminal shown takes keyboard focus; off while a
    /// person browses the sidebar with the arrow keys.
    @ObservationIgnored private(set) var focusOnAttach = true
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
        begin(String(localized: "Loading terminals…", bundle: .main)) { [weak self] expected in
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
        // A listing that starts after a switch finished is current.
        let settled = attachment != nil && !isWorking
        defer { if settled, !isWorking { switchedFrom = nil } }
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
                    ? String(localized: "Terminal Shared", bundle: .main)
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
                    announcement = keepPrivate ? String(localized: "Terminal Kept Private", bundle: .main)
                        : String(localized: "Terminal No Longer Private", bundle: .main)
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
                AccessibilityNotification.Announcement(String(localized: "Terminal Renamed", bundle: .main)).post()
            } catch {
                self?.report(error)
            }
        }
    }

    /// Focuses the terminal on screen, if any.
    func focusTerminal() { focusRequest += 1 }

    /// The first free "Terminal N" name; renaming is always available later.
    /// A number is taken in either language, so a Chinese "终端 2" never
    /// appears beside an English "Terminal 2", or "终端 1" beside "Terminal 1".
    var nextSessionName: String {
        Self.nextName(taken: Set(sessions.map(\.name))) { String(localized: "Terminal \($0)", bundle: .main) }
    }

    static func nextName(taken: Set<String>, localized: (Int) -> String) -> String {
        let number = (1...).first { !taken.contains(localized($0)) && !taken.contains("Terminal \($0)")
            && !taken.contains("终端 \($0)") } ?? 1
        return localized(number)
    }

    func create(name: String, using client: LocalAgentClient) {
        guard !isWorking else { return }
        begin(String(localized: "Starting terminal…", bundle: .main)) { [weak self] expected in
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

    /// Opens a session from the sidebar. `focus` is false while a person
    /// arrows through the list, so the terminal doesn't take the keyboard.
    func select(_ id: String?, using client: LocalAgentClient, focus: Bool = true) {
        guard !isWorking, let id, let session = sessions.first(where: { $0.id == id }) else { return }
        if id == selectedID, attachment != nil {
            if focus { focusTerminal() }
            return
        }
        selectedID = id
        attach(session, using: client, mode: .control, focus: focus)
    }

    func attach(_ session: LocalSessionInfo, using client: LocalAgentClient, mode: LocalAttachmentMode, focus: Bool = true) {
        focusOnAttach = focus
        let previous = attachment
        attachment = nil
        attachmentID = UUID()
        switchedFrom = nil
        selectedID = session.id
        self.mode = mode
        ended = false
        begin(String(localized: "Opening terminal…", bundle: .main)) { [weak self] expected in
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

    /// How this window shows the session now, or nil when it doesn't.
    func openMode(_ session: LocalSessionInfo) -> LocalAttachmentMode? {
        selectedID == session.id && attachment != nil ? mode : nil
    }

    /// Where else the session is open, never counting this window's own
    /// attachment, including the one it just switched away from.
    func elsewhere(_ session: LocalSessionInfo) -> [String] {
        session.elsewhere(here: openMode(session), switchedFrom: selectedID == session.id ? switchedFrom : nil)
    }

    /// Start Typing and Stop Typing on the terminal shown here. The shell and
    /// its screen stay; only whether keys are sent changes.
    func setTyping(_ typing: Bool, using client: LocalAgentClient) {
        guard let session = selectedSession, attachment != nil else { return }
        let next: LocalAttachmentMode = typing ? .control : .view
        guard next != mode else { return }
        let previous = mode
        attach(session, using: client, mode: next)
        switchedFrom = previous
        AccessibilityNotification.Announcement(typing ? String(localized: "Typing", bundle: .main)
                                               : String(localized: "Watching", bundle: .main)).post()
    }

    func close(_ session: LocalSessionInfo, using client: LocalAgentClient) {
        guard !isWorking else { return }
        if selectedID == session.id { detach() }
        begin(String(localized: "Ending terminal…", bundle: .main)) { [weak self] expected in
            try await client.close(sessionID: session.id)
            let sessions = try await client.sessions()
            try Task.checkCancellation()
            guard let self, self.generation == expected else { return }
            self.sessions = sessions
            if self.selectedID == session.id { self.selectedID = nil }
            AccessibilityNotification.Announcement(String(localized: "Terminal Ended", bundle: .main)).post()
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
