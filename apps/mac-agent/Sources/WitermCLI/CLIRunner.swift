import Darwin
import Foundation
import WitermCore

/// Whether paired devices can reach shared sessions right now.
enum RemoteState: String, Encodable, Equatable {
    /// Allow Remote Access is off for every server.
    case off
    /// On, but no server has accepted this Mac's connection yet.
    case waiting
    /// At least one server has accepted it.
    case ready

    init(_ relays: [LocalRelayStatus]) {
        if relays.isEmpty { self = .off } else if relays.contains(where: { $0.state == .ready }) { self = .ready } else { self = .waiting }
    }
}

struct CLIRunner {
    let invocation: CLIInvocation
    let environment: [String: String]

    func run() async throws -> CLIExit {
        switch invocation.command {
        case .help:
            print(CLIParser.usage)
            return .success
        case .version:
            print("witerm \(Self.version)")
            return .success
        case .status: return try await status()
        case .sessions: return try await sessions()
        case .new(let name, let share, let detach): return try await create(name: name, share: share, detach: detach)
        case .share(let reference, let wait): return try await share(reference, wait: wait)
        case .unshare(let reference): return try await unshare(reference)
        case .attach(let reference, let view): return try await attach(reference, view: view)
        }
    }

    static var version: String { AgentLocator.containingApp()?.version ?? "development" }

    private func client() throws -> LocalAgentClient {
        LocalAgentClient(socketURL: try AgentLocator.socketURL(override: invocation.socket, environment: environment))
    }

    // MARK: Commands

    private func status() async throws -> CLIExit {
        let status = try await client().status()
        let relays = status.relays ?? []
        if invocation.json {
            emit(StatusJSON(service: "running", tmux: status.tmuxAvailable, remote: RemoteJSON(relays), version: Self.version))
        } else {
            print("Background service: running")
            print("tmux: " + (status.tmuxAvailable ? "available" : "missing (brew install tmux)"))
            print("Remote access: " + Self.describe(relays))
        }
        return status.tmuxAvailable ? .success : .tmuxMissing
    }

    private func sessions() async throws -> CLIExit {
        let sessions = try await client().sessions()
        if invocation.json {
            emit(sessions.map(SessionJSON.init))
        } else if sessions.isEmpty {
            print("No sessions. Start one with: witerm new")
        } else {
            let rows = sessions.map { session -> [String] in
                let sharing = session.sharing
                return [String(session.id.prefix(8)), session.name, "\(session.columns)x\(session.rows)",
                        sharing?.shared == true ? "yes" : "no",
                        sharing.map { Self.describe($0.attachments) } ?? "—"]
            }
            Self.printTable(header: ["ID", "NAME", "SIZE", "SHARED", "ATTACHED"], rows: rows)
        }
        return .success
    }

    private func create(name: String?, share: Bool, detach: Bool) async throws -> CLIExit {
        let client = try client()
        let status = try await client.status()
        guard status.tmuxAvailable else { throw Self.tmuxMissing }
        let directory = Self.currentDirectory()
        let interactive = !invocation.json && !detach && TerminalBridge.isInteractive
        let size = interactive ? TerminalBridge.terminalSize() : (columns: 80, rows: 24)
        let session = try await client.create(name: try Self.sessionName(name, directory: directory),
                                              columns: size.columns, rows: size.rows, cwd: directory, shared: share)
        let relays = share ? (try await client.status().relays ?? []) : []
        if invocation.json {
            emit(SharedJSON(session: SessionJSON(session), remote: share ? RemoteJSON(relays) : nil))
            return .success
        }
        print("Created “\(session.name)” in \(directory) (\(session.id.prefix(8))).")
        if share { print(Self.shareSummary(relays)) }
        guard interactive else {
            if !detach { print("Attach with: witerm attach \(session.id.prefix(8))") }
            return .success
        }
        return try await run(session, mode: .control, client: client)
    }

    private func share(_ reference: String?, wait: Double?) async throws -> CLIExit {
        let client = try client()
        let session = try await resolve(reference, client: client)
        let shared = try await client.share(sessionID: session.id, shared: true)
        var relays = try await client.status().relays ?? []
        if let wait {
            let deadline = Date().addingTimeInterval(wait)
            while RemoteState(relays) != .ready, Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
                relays = try await client.status().relays ?? []
            }
        }
        if invocation.json {
            emit(SharedJSON(session: SessionJSON(shared), remote: RemoteJSON(relays)))
        } else {
            print("Shared “\(shared.name)” (\(shared.id.prefix(8))).")
            print(Self.shareSummary(relays))
        }
        return wait != nil && RemoteState(relays) != .ready ? .remoteNotReady : .success
    }

    private func unshare(_ reference: String?) async throws -> CLIExit {
        let client = try client()
        let session = try await resolve(reference, client: client)
        let updated = try await client.share(sessionID: session.id, shared: false)
        if invocation.json {
            emit(SharedJSON(session: SessionJSON(updated), remote: nil))
        } else {
            print("Stopped sharing “\(updated.name)”. Paired devices were disconnected; the session keeps running.")
        }
        return .success
    }

    private func attach(_ reference: String, view: Bool) async throws -> CLIExit {
        guard !invocation.json, TerminalBridge.isInteractive else {
            throw CLIFailure.usage("attach needs an interactive terminal.")
        }
        let client = try client()
        let session = try await resolve(reference, client: client)
        return try await run(session, mode: view ? .view : .control, client: client)
    }

    private func run(_ session: LocalSessionInfo, mode: LocalAttachmentMode, client: LocalAgentClient) async throws -> CLIExit {
        let size = TerminalBridge.terminalSize()
        let attachment: LocalTerminalAttachment
        do {
            attachment = try await client.attach(sessionID: session.id, columns: size.columns, rows: size.rows, mode: mode)
        } catch LocalAgentClientError.rejected(.sessionBusy) {
            throw CLIFailure(exit: .busy, code: "session_busy",
                             message: "Another device controls “\(session.name)”. Watch it with: witerm attach --view \(session.id.prefix(8))")
        }
        let key = invocation.escape.map { String(UnicodeScalar($0)) }
        let hint = key.map { ", Enter then \($0). to detach" } ?? ""
        FileHandle.standardError.write(Data("[\(mode == .view ? "viewing" : "attached to") “\(session.name)”\(hint)]\r\n".utf8))
        let outcome = try await TerminalBridge(escape: invocation.escape).run(attachment, mode: mode)
        let message = outcome == .detached ? "[detached; “\(session.name)” keeps running]" : "[“\(session.name)” ended]"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return .success
    }

    // MARK: Helpers

    /// A session named by ID, unique ID prefix, or exact name; with none, the
    /// session this shell runs in.
    private func resolve(_ reference: String?, client: LocalAgentClient) async throws -> LocalSessionInfo {
        guard let reference = reference ?? environment["WITERM_SESSION_ID"], !reference.isEmpty else {
            throw CLIFailure.usage("Name a session, or run this inside a Witerm session.")
        }
        return try Self.resolve(reference, in: try await client.sessions())
    }

    static func resolve(_ reference: String, in sessions: [LocalSessionInfo]) throws -> LocalSessionInfo {
        if let exact = sessions.first(where: { $0.id == reference }) { return exact }
        let named = sessions.filter { $0.name == reference }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw CLIFailure.usage("Several sessions are named “\(reference)”. Use an ID from witerm sessions.")
        }
        let lowered = reference.lowercased()
        if lowered.count >= 4, lowered.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let matches = sessions.filter { $0.id.hasPrefix(lowered) }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw CLIFailure.usage("“\(reference)” matches several sessions. Use more of the ID.") }
        }
        throw CLIFailure(exit: .notFound, code: "not_found", message: "No session matches “\(reference)”. See witerm sessions.")
    }

    /// The folder name, cleaned up to a valid session name.
    static func sessionName(_ requested: String?, directory: String) throws -> String {
        if let requested {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(trimmed.unicodeScalars.count),
                  !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CLIFailure.usage("Use a name of 1–64 characters without control characters.")
            }
            return trimmed
        }
        let folder = URL(fileURLWithPath: directory).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(String.UnicodeScalarView(folder.unicodeScalars.prefix(64)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? "Terminal" : name
    }

    static func currentDirectory() -> String {
        guard let path = getcwd(nil, 0) else { return NSHomeDirectory() }
        defer { free(path) }
        return String(cString: path)
    }

    static func shareSummary(_ relays: [LocalRelayStatus]) -> String {
        switch RemoteState(relays) {
        case .ready:
            return "Paired devices can open it now (\(hosts(relays.filter { $0.state == .ready })))."
        case .waiting:
            return "Waiting for \(hosts(relays)) to connect; paired devices can open it once connected."
        case .off:
            return "Remote access is off, so paired devices can't reach it yet. Turn on Allow Remote Access in Witerm → Paired Devices."
        }
    }

    static func describe(_ relays: [LocalRelayStatus]) -> String {
        switch RemoteState(relays) {
        case .off: "off"
        case .waiting: "waiting for \(hosts(relays))"
        case .ready: "ready (\(hosts(relays.filter { $0.state == .ready })))"
        }
    }

    static func describe(_ attachments: [LocalAttachmentInfo]) -> String {
        if attachments.isEmpty { return "—" }
        return attachments.map { "\($0.device?.name ?? "this Mac") (\($0.mode == .control ? "control" : "view"))" }
            .joined(separator: ", ")
    }

    static func hosts(_ relays: [LocalRelayStatus]) -> String {
        relays.map { relay in
            guard let url = URL(string: relay.server), let host = url.host else { return relay.server }
            return url.port.map { "\(host):\($0)" } ?? host
        }.joined(separator: ", ")
    }

    static var tmuxMissing: CLIFailure {
        CLIFailure(exit: .tmuxMissing, code: "tmux_missing", message: "tmux isn't installed. Install it with: brew install tmux")
    }

    static func printTable(header: [String], rows: [[String]]) {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        for row in all {
            print(row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  "))
        }
    }

    private func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    /// The exit code and message for any failure.
    static func failure(_ error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        switch error as? LocalAgentClientError {
        case .unavailable?:
            return CLIFailure(exit: .serviceUnavailable, code: "service_unavailable",
                              message: "Can't reach Witerm's background service. Open Witerm and turn on the local terminal in Settings → General.")
        case .unsafeSocket?:
            return CLIFailure(exit: .serviceUnavailable, code: "unsafe_socket",
                              message: "The background service's socket failed a safety check. Turn the local terminal off and on in Witerm.")
        case .rejected(.notFound)?:
            return CLIFailure(exit: .notFound, code: "not_found", message: "That session or folder no longer exists.")
        case .rejected(.sessionBusy)?:
            return CLIFailure(exit: .busy, code: "session_busy", message: "Another device controls that session.")
        case .rejected(.dependencyMissing)?:
            return tmuxMissing
        case .rejected(.invalidRequest)?:
            return CLIFailure(exit: .usage, code: "invalid_request", message: "The background service rejected that request. Check the name and folder.")
        case .backpressure?, .rejected(.backpressure)?:
            return CLIFailure(exit: .failure, code: "backpressure", message: "Disconnected because the terminal couldn't keep up. Attach again.")
        case .invalidResponse?, .rejected(.unsupportedVersion)?:
            return CLIFailure(exit: .failure, code: "version_mismatch", message: "The background service answered unexpectedly. Update Witerm.")
        default:
            return CLIFailure(exit: .failure, code: "failure", message: "The command didn't finish. Try again.")
        }
    }
}

// MARK: JSON output (stable schema)

struct DeviceJSON: Encodable, Equatable {
    let id: String
    let name: String
}

struct AttachmentJSON: Encodable, Equatable {
    let mode: String
    /// null means this Mac.
    let device: DeviceJSON?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(device, forKey: .device)
    }
    enum CodingKeys: String, CodingKey { case mode, device }
}

struct SessionJSON: Encodable, Equatable {
    let id: String
    let name: String
    let created_at: Date
    let columns: Int
    let rows: Int
    let shared: Bool
    let attachments: [AttachmentJSON]

    init(_ session: LocalSessionInfo) {
        id = session.id; name = session.name; created_at = session.createdAt
        columns = session.columns; rows = session.rows
        shared = session.sharing?.shared ?? false
        attachments = (session.sharing?.attachments ?? []).map {
            AttachmentJSON(mode: $0.mode.rawValue, device: $0.device.map { DeviceJSON(id: $0.deviceID, name: $0.name) })
        }
    }
}

struct RemoteJSON: Encodable, Equatable {
    let state: RemoteState
    let servers: [[String: String]]

    init(_ relays: [LocalRelayStatus]) {
        state = RemoteState(relays)
        servers = relays.map { ["server": $0.server, "state": $0.state.rawValue] }
    }
}

struct SharedJSON: Encodable {
    let session: SessionJSON
    let remote: RemoteJSON?
}

struct StatusJSON: Encodable {
    let service: String
    let tmux: Bool
    let remote: RemoteJSON
    let version: String
}

struct ErrorJSON: Encodable {
    struct Detail: Encodable { let code: String; let message: String; let exit: Int32 }
    let error: Detail
}
