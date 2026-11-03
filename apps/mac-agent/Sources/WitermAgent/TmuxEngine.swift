import Darwin
import Foundation
import WitermCore

// Accessed only on AgentBroker's serial state queue.
final class TmuxEngine {
    let state: PrivateState
    let configuration: AgentConfiguration
    private var records: [String: LocalSessionInfo]
    /// Sessions every paired device may list and attach to.
    private(set) var shared: Set<String>
    /// Sessions no paired device may reach. Never also shared.
    private(set) var keptPrivate: Set<String>

    init(state: PrivateState, configuration: AgentConfiguration) throws {
        self.state = state
        self.configuration = configuration
        records = try state.loadMetadata()
        // An unreadable sharing file shares nothing rather than stopping the service.
        shared = ((try? state.loadSharing()) ?? []).intersection(records.keys)
        // An unreadable privacy file can't prove a session is safe to show,
        // but devices limited to shared sessions still see only shared ones.
        keptPrivate = ((try? state.loadPrivate()) ?? []).intersection(records.keys).subtracting(shared)
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
    private func command(_ arguments: [String], timeout: TimeInterval = 3, directory: String? = nil) throws -> Data {
        let result = try runner().run(baseArguments + arguments, timeout: timeout, directory: directory)
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
        let stillShared = shared.intersection(records.keys)
        if stillShared != shared { shared = stillShared; try state.saveSharing(shared) }
        let stillPrivate = keptPrivate.intersection(records.keys)
        if stillPrivate != keptPrivate { keptPrivate = stillPrivate; try state.savePrivate(keptPrivate) }
        return records.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    func session(_ id: String) throws -> LocalSessionInfo {
        guard validSessionID(id), let record = try sessions().first(where: { $0.id == id }) else { throw AgentFailure(.notFound) }
        return record
    }

    func create(name: String, columns: Int, rows: Int, cwd: String? = nil, shared share: Bool = false) throws -> LocalSessionInfo {
        guard try sessions().count < 16 else { throw AgentFailure() }
        if let cwd { try Self.validateDirectory(cwd) }
        let id = UUID().uuidString.lowercased()
        let internalID = internalName(id)
        // More than one shell argument asks tmux to exec argv directly. The
        // display name is metadata only and is never interpreted by tmux.
        // WITERM_SESSION_ID lets `witerm share` know which session it runs in.
        // The start folder is tmux's own working directory, never -c: tmux
        // expands formats in -c, including #{…} and #(command), and no
        // escaping covers every folder name.
        try command(["new-session", "-d", "-s", internalID, "-x", String(columns), "-y", String(rows),
                     "-e", "WITERM_SESSION_ID=\(id)", "--", configuration.shellPath, configuration.loginShell ? "-l" : "-i"],
                    directory: cwd)
        do {
            for (key, value) in [
                ("status", "off"), ("prefix", "None"), ("prefix2", "None"),
                ("exit-unattached", "off"), ("destroy-unattached", "off"),
                ("set-titles", "off"), ("default-terminal", "xterm-256color"),
                // tmux 3.6 and later turn the mouse on by default, even with
                // -f /dev/null: its client then asks every viewer's terminal
                // for button drags, and a swipe on the phone became tmux's
                // copy-mode selection. Touches and scrolling stay the viewers'.
                ("mouse", "off")
            ] { try command(["set-option", "-g", key, value]) }
            try command(["set-window-option", "-g", "window-size", "manual"])
            try command(["set-window-option", "-t", internalID, "allow-rename", "off"])
            try command(["set-window-option", "-t", internalID, "automatic-rename", "off"])
            try command(["set-window-option", "-t", internalID, "remain-on-exit", "off"])
            try command(["resize-window", "-t", internalID, "-x", String(columns), "-y", String(rows)])
            if let cwd {
                // tmux falls back to another folder when it can't use one; never
                // report a session as started where it wasn't.
                let started = try command(["display-message", "-p", "-t", internalID, "#{pane_start_path}"])
                guard String(decoding: started, as: UTF8.self).trimmingCharacters(in: .newlines) == cwd else {
                    throw AgentFailure(.invalidRequest)
                }
            }
            let record = LocalSessionInfo(id: id, name: name, createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), columns: columns, rows: rows)
            records[id] = record
            try state.saveMetadata(records)
            if share { try setShared(id, true) }
            return record
        } catch {
            records.removeValue(forKey: id)
            shared.remove(id)
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
        if shared.remove(id) != nil { try state.saveSharing(shared) }
        if keptPrivate.remove(id) != nil { try state.savePrivate(keptPrivate) }
    }

    /// The display name is metadata only; tmux keeps the internal name.
    func rename(_ id: String, to name: String) throws -> LocalSessionInfo {
        let old = try session(id)
        let record = LocalSessionInfo(id: id, name: name, createdAt: old.createdAt, columns: old.columns, rows: old.rows)
        var next = records
        next[id] = record
        try state.saveMetadata(next)
        records = next
        return record
    }

    /// Sharing a session ends keeping it private.
    func setShared(_ id: String, _ value: Bool) throws {
        _ = try session(id)
        if value { try setPrivate(id, false) }
        var next = shared
        if value { next.insert(id) } else { next.remove(id) }
        guard next != shared else { return }
        try state.saveSharing(next)
        shared = next
    }

    /// Keeping a session private ends sharing it.
    func setPrivate(_ id: String, _ value: Bool) throws {
        _ = try session(id)
        if value { try setShared(id, false) }
        var next = keptPrivate
        if value { next.insert(id) } else { next.remove(id) }
        guard next != keptPrivate else { return }
        try state.savePrivate(next)
        keptPrivate = next
    }

    /// The start directory must be an existing directory this user can enter.
    /// tmux silently falls back to another directory when it cannot use one.
    static func validateDirectory(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 1024,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw AgentFailure(.invalidRequest) }
        var info = stat()
        guard stat(path, &info) == 0 else { throw AgentFailure(.notFound) }
        guard info.st_mode & S_IFMT == S_IFDIR, access(path, X_OK | R_OK) == 0 else { throw AgentFailure(.invalidRequest) }
    }

    /// Earlier output above the visible screen, as VT bytes for a fresh
    /// renderer's scrollback: up to 1,000 lines and 128 KiB with their colors,
    /// then enough line feeds to scroll them all above the screen tmux
    /// redraws next. Nothing while a program uses the alternate screen.
    func history(_ id: String, rows: Int) throws -> Data {
        _ = try session(id)
        let target = internalName(id)
        let alternate = try command(["display-message", "-p", "-t", target, "#{alternate_on}"])
        guard String(decoding: alternate, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { return Data() }
        let captured = try command(["capture-pane", "-p", "-e", "-t", target, "-S", "-1000", "-E", "-1"], timeout: 2)
        var lines = captured.split(separator: 0x0a, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        // Leading blank lines are tmux's unused history, not output.
        while let first = lines.first, first.allSatisfy({ $0 == 0x20 }) { lines.removeFirst() }
        guard !lines.isEmpty else { return Data() }
        var kept: [Data.SubSequence] = []
        var size = 0
        for line in lines.reversed() {
            guard size + line.count + 2 <= 131_072 else { break }
            size += line.count + 2
            kept.append(line)
        }
        var output = Data("\u{1b}[0m".utf8)
        for line in kept.reversed() { output.append(contentsOf: line); output.append(contentsOf: [0x1b, 0x5b, 0x30, 0x6d, 0x0d, 0x0a]) }
        output.append(Data(repeating: 0x0a, count: rows))
        return output
    }

    func attach(_ id: String, columns: Int, rows: Int, mode: LocalAttachmentMode) throws -> PTYChild {
        _ = try session(id)
        guard let path = configuration.tmuxPath else { throw AgentFailure(.dependencyMissing) }
        let flags = mode == .view ? "read-only,ignore-size" : "ignore-size"
        // Sessions made before the mouse was turned off at creation get it here.
        _ = try? command(["set-option", "-g", "mouse", "off"])
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
