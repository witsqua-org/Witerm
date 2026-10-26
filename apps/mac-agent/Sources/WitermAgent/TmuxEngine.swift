import Darwin
import Foundation
import WitermCore

// Accessed only on AgentBroker's serial state queue.
final class TmuxEngine {
    let state: PrivateState
    let configuration: AgentConfiguration
    private var records: [String: LocalSessionInfo]

    init(state: PrivateState, configuration: AgentConfiguration) throws {
        self.state = state
        self.configuration = configuration
        records = try state.loadMetadata()
    }

    var available: Bool { configuration.tmuxPath != nil }

    private func runner() throws -> CommandRunner {
        guard let path = configuration.tmuxPath else { throw AgentFailure(.dependencyMissing) }
        try state.validateTmuxSocket()
        return CommandRunner(executable: path, environment: configuration.environment)
    }

    var baseArguments: [String] { ["-S", state.tmuxSocketURL.path, "-f", "/dev/null"] }
    func internalName(_ id: String) -> String { "witerm-" + id }

    @discardableResult
    private func command(_ arguments: [String], timeout: TimeInterval = 3) throws -> Data {
        let result = try runner().run(baseArguments + arguments, timeout: timeout)
        guard result.status == 0 else { throw AgentFailure() }
        return result.output
    }

    func sessions() throws -> [LocalSessionInfo] {
        let result = try runner().run(baseArguments + ["list-sessions", "-F", "#{session_name}"])
        let live: Set<String>
        if result.status == 0 {
            guard let names = String(data: result.output, encoding: .utf8) else { throw AgentFailure() }
            live = Set(names.split(separator: "\n").map(String.init))
        } else {
            // A failed query is not evidence that the server (or its tasks) is
            // gone. Preserve both the in-memory and durable records unless the
            // private endpoint is positively absent or refuses connections.
            guard try state.tmuxServerIsAbsent() else { throw AgentFailure() }
            live = []
        }
        let kept = records.filter { live.contains(internalName($0.key)) }
        if kept.count != records.count { try state.saveMetadata(kept); records = kept }
        return records.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    func session(_ id: String) throws -> LocalSessionInfo {
        guard validSessionID(id), let record = try sessions().first(where: { $0.id == id }) else { throw AgentFailure(.notFound) }
        return record
    }

    func create(name: String, columns: Int, rows: Int) throws -> LocalSessionInfo {
        guard try sessions().count < 16 else { throw AgentFailure() }
        let id = UUID().uuidString.lowercased()
        let internalID = internalName(id)
        // More than one shell argument asks tmux to exec argv directly. The
        // display name is metadata only and is never interpreted by tmux.
        try command(["new-session", "-d", "-s", internalID, "-x", String(columns), "-y", String(rows), "--", configuration.shellPath, configuration.loginShell ? "-l" : "-i"])
        do {
            for (key, value) in [
                ("status", "off"), ("prefix", "None"), ("prefix2", "None"),
                ("exit-unattached", "off"), ("destroy-unattached", "off"),
                ("set-titles", "off"), ("default-terminal", "xterm-256color")
            ] { try command(["set-option", "-g", key, value]) }
            try command(["set-window-option", "-g", "window-size", "manual"])
            try command(["set-window-option", "-t", internalID, "allow-rename", "off"])
            try command(["set-window-option", "-t", internalID, "automatic-rename", "off"])
            try command(["set-window-option", "-t", internalID, "remain-on-exit", "off"])
            try command(["resize-window", "-t", internalID, "-x", String(columns), "-y", String(rows)])
            let record = LocalSessionInfo(id: id, name: name, createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), columns: columns, rows: rows)
            records[id] = record
            try state.saveMetadata(records)
            return record
        } catch {
            records.removeValue(forKey: id)
            _ = try? command(["kill-session", "-t", internalID])
            throw AgentFailure()
        }
    }

    func resize(_ id: String, columns: Int, rows: Int) throws -> LocalSessionInfo {
        let old = try session(id)
        try command(["resize-window", "-t", internalName(id), "-x", String(columns), "-y", String(rows)])
        let record = LocalSessionInfo(id: id, name: old.name, createdAt: old.createdAt, columns: columns, rows: rows)
        records[id] = record
        try state.saveMetadata(records)
        return record
    }

    /// tmux applies a pane's PTY size from its event loop and defers a resize
    /// that follows another one closely. The window reports the new grid before
    /// the shell does, so confirm the kernel winsize the shell will read.
    func waitForPaneSize(_ id: String, columns: Int, rows: Int) throws {
        try withPaneTerminal(id) { fd in
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while true {
                let size = try Self.windowSize(fd)
                if size.columns == columns && size.rows == rows { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AgentFailure() }
                usleep(2_000)
            }
        }
    }

    /// The grid the shell actually has. A record can be stale after a resize
    /// whose confirmation and reconciliation both failed, so attachments start
    /// from this and correct the record. An unreadable pane fails the attach.
    func verifiedSession(_ id: String) throws -> LocalSessionInfo {
        let record = try session(id)
        let size = try withPaneTerminal(id) { try Self.windowSize($0) }
        guard validDimensions(columns: size.columns, rows: size.rows) else { throw AgentFailure() }
        guard size.columns != record.columns || size.rows != record.rows else { return record }
        let actual = LocalSessionInfo(id: id, name: record.name, createdAt: record.createdAt, columns: size.columns, rows: size.rows)
        records[id] = actual
        try state.saveMetadata(records)
        return actual
    }

    /// After an unconfirmed resize, records the grid the shell actually has and
    /// returns the window to it, so the next attach or resize compares against
    /// the real size instead of the announced one.
    func reconcileToPane(_ id: String) throws {
        let actual = try verifiedSession(id)
        try command(["resize-window", "-t", internalName(id), "-x", String(actual.columns), "-y", String(actual.rows)])
    }

    private func withPaneTerminal<T>(_ id: String, _ body: (Int32) throws -> T) throws -> T {
        let output = try command(["display-message", "-p", "-t", internalName(id), "#{pane_tty}"])
        guard let path = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/dev/ttys"), !path.contains("..") else { throw AgentFailure() }
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AgentFailure() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR, info.st_uid == geteuid() else { throw AgentFailure() }
        return try body(fd)
    }

    private static func windowSize(_ fd: Int32) throws -> (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { throw AgentFailure() }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    func close(_ id: String) throws {
        _ = try session(id)
        try command(["kill-session", "-t", internalName(id)])
        records.removeValue(forKey: id)
        try state.saveMetadata(records)
    }

    func attach(_ id: String, columns: Int, rows: Int, mode: LocalAttachmentMode) throws -> PTYChild {
        _ = try session(id)
        guard let path = configuration.tmuxPath else { throw AgentFailure(.dependencyMissing) }
        let flags = mode == .view ? "read-only,ignore-size" : "ignore-size"
        return try PTYChild(executable: path, arguments: baseArguments + ["attach-session", "-t", internalName(id), "-f", flags], environment: configuration.environment, columns: columns, rows: rows)
    }

    func refresh(_ id: String, terminals: Set<String>, columns: Int, rows: Int) throws {
        guard !terminals.isEmpty else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var live: [String] = []
        repeat {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw AgentFailure() }
            let data = try command(["list-clients", "-t", internalName(id), "-F",
                "#{client_tty}\t#{client_width}\t#{client_height}"], timeout: min(0.5, remaining))
            guard let text = String(data: data, encoding: .utf8) else { throw AgentFailure() }
            var waiting = false
            live.removeAll(keepingCapacity: true)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3 else { throw AgentFailure() }
                let terminal = String(parts[0])
                guard terminals.contains(terminal) else { continue }
                live.append(terminal)
                if Int(parts[1]) != columns || Int(parts[2]) != rows { waiting = true }
            }
            guard live.count <= 32 else { throw AgentFailure() }
            if !waiting { break }
            usleep(2_000)
        } while true
        // Only refresh our exact PTY clients in this session/private tmux.
        // A just-spawned client may not yet be registered; its own attach path
        // performs the initial full redraw using the already-updated winsize.
        var arguments: [String] = []
        for terminal in live.sorted() {
            if !arguments.isEmpty { arguments.append(";") }
            arguments += ["refresh-client", "-t", terminal]
        }
        // Semicolons are tmux argv command separators, never shell text. A
        // single bounded command process covers all clients rather than 32
        // independent command timeouts while output barriers are held.
        if !arguments.isEmpty { try command(arguments, timeout: 1) }
    }
}
