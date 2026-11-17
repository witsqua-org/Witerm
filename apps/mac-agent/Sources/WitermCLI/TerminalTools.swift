import Foundation
import WitermCore

/// A tool that failed in a way the model should read and act on (the
/// terminal is busy, it doesn't exist), answered as a tool result with
/// `isError`, not as a protocol error.
struct ToolFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// What a tool call came back with.
struct ToolResult: Sendable, Equatable {
    let text: String
    let isError: Bool
}

/// A tool as both MCP and the OpenAI API describe one.
struct ToolDefinition: Sendable {
    let name: String
    let title: String
    let description: String
    let schema: JSONValue
    let readOnly: Bool
    let destructive: Bool
}

/// Per-connection memory: who is acting, which terminals it made, and what
/// it last saw of each terminal, so a read can say only what changed.
actor TerminalToolState {
    struct Screen: Sendable {
        /// The screen's top row, counted from the top of history.
        let top: Int
        let lines: [String]
        let alternate: Bool
    }

    private(set) var agent: String
    private var created: Set<String>
    private var screens: [String: Screen] = [:]
    private let onCreate: @Sendable (String) async -> Void

    init(agent: String, created: Set<String> = [], onCreate: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.agent = agent
        self.created = created
        self.onCreate = onCreate
    }

    func setAgent(_ name: String) { agent = name }
    func didCreate(_ id: String) async { created.insert(id); await onCreate(id) }
    func owns(_ id: String) -> Bool { created.contains(id) }
    func forget(_ id: String) { created.remove(id); screens.removeValue(forKey: id) }
    func screen(_ id: String) -> Screen? { screens[id] }
    func saw(_ id: String, _ screen: Screen) { screens[id] = screen }
}

/// Reading, typing into, and running commands in this Mac's Witerm
/// terminals, through the same background service the app uses. `witerm mcp`
/// offers these to external agents and Orbit uses them itself. Typing
/// follows the service's rules for any local writer: a paired device that
/// doesn't allow typing alongside makes the terminal busy, a person typing
/// makes an agent wait, and nothing takes control from anyone.
struct TerminalTools: Sendable {
    let client: LocalAgentClient
    /// Only `list_terminals`, `read_terminal` and `wait_for_terminal`.
    let readOnly: Bool
    let state: TerminalToolState
    /// How often waiting tools look at the terminal.
    var pollInterval: Duration = .milliseconds(200)
    /// How long typing stays attached after its input, so tmux's client has
    /// passed it on before the attachment ends.
    var inputHold: Duration = .milliseconds(250)
    /// The size of terminals made here, until a Witerm window attaches.
    static let newTerminalSize = (columns: 120, rows: 32)
    /// Command output longer than this keeps its first and last lines.
    static let outputHead = 30
    static let outputTail = 120

    init(client: LocalAgentClient, readOnly: Bool, state: TerminalToolState) {
        self.client = client
        self.readOnly = readOnly
        self.state = state
    }

    static let readingTools: Set<String> = ["list_terminals", "read_terminal", "wait_for_terminal"]
    static let writingTools: Set<String> = ["run_command", "send_input", "create_terminal", "close_terminal"]

    // MARK: Definitions

    var definitions: [ToolDefinition] {
        let terminal: JSONValue = ["type": "string",
                                   "description": "The terminal's ID, a unique ID prefix of at least 4 characters, or its exact name."]
        let timeout: JSONValue = ["type": "number", "minimum": 1, "maximum": 600,
                                  "description": "Seconds to wait before returning what is there so far (default 30)."]
        var tools = [
            tool("list_terminals", "List terminals",
                 "Lists this Mac's Witerm terminals: ID, name, size, folder, the program in the foreground (none at the shell prompt), and who has it open.",
                 [:], required: [], readOnly: true),
            tool("read_terminal", "Read a terminal",
                 "Returns a terminal's screen as plain text: the first time, the whole screen; after that, only what changed since your last look. Every other tool already returns what changed, so you rarely need this right after one. full gives the whole screen; history_lines gives earlier output.",
                 ["terminal": terminal,
                  "history_lines": ["type": "integer", "minimum": 0, "maximum": .int(LocalTerminalCapture.historyLimit),
                                    "description": "Earlier lines to include above the screen (default 0). Long text keeps the latest lines."],
                  "full": ["type": "boolean", "description": "The whole screen even if you have seen it (default false)."]],
                 required: ["terminal"], readOnly: true),
            tool("wait_for_terminal", "Wait for a terminal",
                 "Waits until text appears on a terminal's screen, or, without text, until the shell's prompt is back and the screen has settled. Returns what changed since your last look.",
                 ["terminal": terminal,
                  "text": ["type": "string", "description": "Text to wait for on the screen."],
                  "timeout_seconds": timeout],
                 required: ["terminal"], readOnly: true),
        ]
        guard !readOnly else { return tools }
        tools += [
            tool("run_command", "Run a shell command",
                 "Types a command at a terminal's shell prompt, presses Return, and waits until the shell's prompt is back. Returns the output since the command (very long output keeps its first and last lines). Refuses when a program is already running there. The exit status isn't reported; append `; echo \"exit=$?\"` when you need it.",
                 ["terminal": terminal,
                  "command": ["type": "string", "description": "One command line, without a trailing newline."],
                  "timeout_seconds": timeout],
                 required: ["terminal", "command"], readOnly: false, destructive: true),
            tool("send_input", "Type into a terminal",
                 "Types text and then named keys into a terminal, as if on its keyboard, and returns what changed on the screen. A line feed in text is sent as Return.",
                 ["terminal": terminal,
                  "text": ["type": "string", "description": "Literal text to type."],
                  "keys": ["type": "array", "items": ["type": "string"],
                           "description": "Keys typed after the text: enter, tab, escape, backspace, delete, space, up, down, left, right, home, end, page_up, page_down, or ctrl-<letter> such as ctrl-c."]],
                 required: ["terminal"], readOnly: false, destructive: true),
            tool("create_terminal", "Create a terminal",
                 "Starts a new Witerm terminal with a fresh login shell, visible in the Witerm app. Returns its ID and first screen.",
                 ["name": ["type": "string", "description": "Display name, 1–64 characters (default your name)."],
                  "folder": ["type": "string", "description": "Absolute folder the shell starts in (default the home folder)."]],
                 required: [], readOnly: false),
            tool("close_terminal", "End a terminal",
                 "Ends a terminal and its programs. Only terminals you created with create_terminal can be ended; the user ends their own in Witerm.",
                 ["terminal": terminal], required: ["terminal"], readOnly: false, destructive: true),
        ]
        return tools
    }

    private func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: JSONValue],
                      required: [String], readOnly: Bool, destructive: Bool = false) -> ToolDefinition {
        ToolDefinition(name: name, title: title, description: description,
                       schema: ["type": "object", "properties": .object(properties),
                                "required": .array(required.map(JSONValue.string)), "additionalProperties": false],
                       readOnly: readOnly, destructive: destructive)
    }

    func offers(_ name: String) -> Bool {
        Self.readingTools.contains(name) || (!readOnly && Self.writingTools.contains(name))
    }

    // MARK: Calls

    /// Runs one tool. Failures the model should see come back as an error
    /// result; a tool this connection doesn't offer throws.
    func run(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        guard offers(name) else { throw MCPError.invalidParams("Unknown tool: \(name)") }
        guard case .object = arguments else { return ToolResult(text: "Arguments must be an object.", isError: true) }
        do {
            let text: String
            switch name {
            case "list_terminals": text = try await listTerminals()
            case "read_terminal": text = try await readTerminal(arguments)
            case "wait_for_terminal": text = try await waitForTerminal(arguments)
            case "run_command": text = try await runCommand(arguments)
            case "send_input": text = try await sendInput(arguments)
            case "create_terminal": text = try await createTerminal(arguments)
            default: text = try await closeTerminal(arguments)
            }
            return ToolResult(text: text, isError: false)
        } catch {
            return ToolResult(text: Self.describe(error), isError: true)
        }
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? ToolFailure { return failure.message }
        if case LocalAgentClientError.rejected(.sessionBusy)? = error as? LocalAgentClientError {
            return "Someone is typing in that terminal right now (the user, or a paired device that doesn't allow typing alongside). Wait a few seconds, read it again, then retry."
        }
        if case LocalAgentClientError.rejected(.notFound)? = error as? LocalAgentClientError {
            return "That terminal or folder no longer exists. Call list_terminals."
        }
        return CLIRunner.failure(error).message
    }

    private func listTerminals() async throws -> String {
        let sessions = try await client.sessions()
        guard !sessions.isEmpty else { return "No terminals. Start one with create_terminal." }
        var lines: [String] = []
        for session in sessions {
            let place = try? await client.place(sessionID: session.id)
            var line = "\(session.id) “\(session.name)” \(session.columns)×\(session.rows)"
            if let place { line += " · \(Self.abbreviate(place.cwd)) · " + (place.command.map { "running \($0)" } ?? "at the prompt") }
            let attachments = session.sharing?.attachments ?? []
            if !attachments.isEmpty { line += " · open in: " + Self.describe(attachments) }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func readTerminal(_ arguments: JSONValue) async throws -> String {
        let session = try await resolve(arguments)
        let history = try integer(arguments, "history_lines", default: 0, in: 0...LocalTerminalCapture.historyLimit)
        let full = arguments["full"]?.bool ?? false
        if history > 0 {
            let capture = try await client.capture(sessionID: session.id, start: -history)
            let place = try? await client.place(sessionID: session.id)
            await remember(session, try await client.capture(sessionID: session.id))
            return Self.header(session, place: place, capture: capture) + "\n" + Self.body(capture.text, truncated: capture.truncated)
        }
        return try await changes(in: session, full: full)
    }

    private func runCommand(_ arguments: JSONValue) async throws -> String {
        let session = try await resolve(arguments)
        guard let command = arguments["command"]?.string, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailure("Give the command to run.")
        }
        guard !command.contains("\n"), !command.contains("\r") else {
            throw ToolFailure("Give one command line. Join commands with && or ;, or use send_input for multi-line input.")
        }
        let timeout = try seconds(arguments)
        if let running = try await client.place(sessionID: session.id).command {
            throw ToolFailure("“\(session.name)” is running \(running), not at a shell prompt. Read it, then use send_input, wait_for_terminal, or another terminal.")
        }
        let before = try await client.capture(sessionID: session.id)
        let start = before.historySize + before.cursorRow
        try await type(Data((command + "\r").utf8), into: session)
        let finished = try await waitUntilIdle(session, after: start, timeout: timeout)
        // Everything from the command's line down, wherever it is now.
        let latest = try await client.capture(sessionID: session.id)
        let from = max(start - latest.historySize, -LocalTerminalCapture.historyLimit)
        let output = try await client.capture(sessionID: session.id, start: min(from, latest.cursorRow))
        await remember(session, latest)
        let place = try? await client.place(sessionID: session.id)
        let state = finished
            ? "Finished; the prompt is back."
            : "Still running\(place?.command.map { " \($0)" } ?? "") after \(Self.seconds(timeout)) s. Use wait_for_terminal to keep waiting, or send_input with keys [\"ctrl-c\"] to stop it."
        return state + "\n" + Self.body(Self.shortened(output.text), truncated: output.truncated)
    }

    private func sendInput(_ arguments: JSONValue) async throws -> String {
        let session = try await resolve(arguments)
        let data = try Self.input(arguments)
        // What was there before typing is the baseline for what changed.
        await remember(session, try await client.capture(sessionID: session.id))
        try await type(data, into: session)
        try await Task.sleep(for: .milliseconds(300))
        return "Typed.\n" + (try await changes(in: session, full: false))
    }

    private func waitForTerminal(_ arguments: JSONValue) async throws -> String {
        let session = try await resolve(arguments)
        let timeout = try seconds(arguments)
        var met: Bool
        if let wanted = arguments["text"] {
            guard let wanted = wanted.string, !wanted.isEmpty else { throw ToolFailure("text must be non-empty.") }
            met = false
            let deadline = ContinuousClock.now + .seconds(timeout)
            while ContinuousClock.now < deadline {
                if try await client.capture(sessionID: session.id).text.contains(wanted) { met = true; break }
                try await Task.sleep(for: pollInterval)
            }
        } else {
            met = try await waitUntilIdle(session, after: nil, timeout: timeout)
        }
        let state = met ? (arguments["text"] == nil ? "The prompt is back." : "The text appeared.")
            : "Timed out after \(Self.seconds(timeout)) s."
        return state + "\n" + (try await changes(in: session, full: false))
    }

    private func createTerminal(_ arguments: JSONValue) async throws -> String {
        let agent = await state.agent
        let name: String
        do { name = try CLIRunner.sessionName(arguments["name"]?.string ?? agent, directory: "/") }
        catch { throw ToolFailure("Use a name of 1–64 characters without control characters.") }
        let folder = arguments["folder"]?.string ?? NSHomeDirectory()
        guard folder.hasPrefix("/") else { throw ToolFailure("Give the folder as an absolute path.") }
        let size = Self.newTerminalSize
        let session = try await client.create(name: name, columns: size.columns, rows: size.rows, cwd: folder)
        await state.didCreate(session.id)
        // The new shell's first screen, once its prompt is up, so the agent
        // needn't read it before its first command.
        var capture = try await client.capture(sessionID: session.id)
        for _ in 0..<15 where capture.text.isEmpty {
            try await Task.sleep(for: pollInterval)
            capture = try await client.capture(sessionID: session.id)
        }
        await remember(session, capture)
        return "Created “\(session.name)” (\(session.id)) in \(Self.abbreviate(folder)); the user can watch it in Witerm.\n"
            + Self.body(capture.text, truncated: capture.truncated)
    }

    private func closeTerminal(_ arguments: JSONValue) async throws -> String {
        let session = try await resolve(arguments)
        guard await state.owns(session.id) else {
            throw ToolFailure("“\(session.name)” wasn't created by you, so only the user can end it, in Witerm.")
        }
        try await client.close(sessionID: session.id)
        await state.forget(session.id)
        return "Ended “\(session.name)”."
    }

    // MARK: Reading what changed

    private func remember(_ session: LocalSessionInfo, _ capture: LocalTerminalCapture) async {
        await state.saw(session.id, TerminalToolState.Screen(top: capture.historySize, lines: Self.lines(capture.text),
                                                             alternate: capture.alternateScreen))
    }

    /// The screen, or only what changed since this connection last saw it:
    /// lines the same as before, from the top of that earlier screen, are
    /// left out and counted.
    private func changes(in session: LocalSessionInfo, full: Bool) async throws -> String {
        let now = try await client.capture(sessionID: session.id)
        let place = try? await client.place(sessionID: session.id)
        let header = Self.header(session, place: place, capture: now)
        let previous = await state.screen(session.id)
        await remember(session, now)
        guard !full, let previous, previous.alternate == now.alternateScreen else {
            return header + "\n" + Self.body(now.text, truncated: now.truncated)
        }
        let start = previous.top - now.historySize
        // History cleared, or scrolled past what tmux keeps: start over.
        guard start <= 0, start >= -LocalTerminalCapture.historyLimit else {
            return header + "\n" + Self.body(now.text, truncated: now.truncated)
        }
        let since = start == 0 ? now : try await client.capture(sessionID: session.id, start: start)
        let lines = Self.lines(since.text)
        let same = zip(previous.lines, lines).prefix { $0 == $1 }.count
        if same == lines.count, lines.count == previous.lines.count {
            return header + "\nNo change since your last look."
        }
        if same == lines.count {
            return header + "\nThe screen was cleared or redrawn:\n" + Self.body(now.text, truncated: now.truncated)
        }
        let rest = Array(lines[same...]).joined(separator: "\n")
        let note = same > 0 ? "[\(same) line\(same == 1 ? "" : "s") you've seen left out]\n" : ""
        return header + "\n" + note + Self.body(Self.shortened(rest), truncated: since.truncated && same == 0)
    }

    static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// Long output keeps its first and last lines.
    static func shortened(_ text: String) -> String {
        let lines = lines(text)
        guard lines.count > outputHead + outputTail + 10 else { return text }
        let left = lines.count - outputHead - outputTail
        return (lines.prefix(outputHead) + ["[\(left) lines left out; read_terminal with history_lines shows them]"]
                + lines.suffix(outputTail)).joined(separator: "\n")
    }

    // MARK: Typing and waiting

    static func input(_ arguments: JSONValue) throws -> Data {
        var data = Data()
        if let text = arguments["text"] {
            guard let text = text.string else { throw ToolFailure("text must be a string.") }
            data.append(Data(text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r").utf8))
        }
        if let keys = arguments["keys"] {
            guard let keys = keys.array else { throw ToolFailure("keys must be a list of key names.") }
            for key in keys {
                guard let name = key.string, let bytes = Self.key(name) else {
                    throw ToolFailure("Unknown key \(key.string ?? "?"). Use enter, tab, escape, backspace, delete, space, arrows (up, down, left, right), home, end, page_up, page_down, or ctrl-<letter>.")
                }
                data.append(bytes)
            }
        }
        guard !data.isEmpty else { throw ToolFailure("Give text, keys, or both.") }
        guard data.count <= 64 * 1024 else { throw ToolFailure("Type at most 64 KiB at once.") }
        return data
    }

    /// Types as a short-lived writer at the session's current size, so the
    /// grid doesn't change, then detaches. Output is read and discarded.
    /// Input waits for tmux's first redraw: until its client has put the
    /// attachment's terminal in raw mode, a Control-C would interrupt the
    /// client itself instead of reaching the shell.
    private func type(_ data: Data, into session: LocalSessionInfo) async throws {
        let attachment = try await client.attach(sessionID: session.id, columns: session.columns, rows: session.rows,
                                                 mode: .control, agent: await state.agent)
        let (drawn, signal) = AsyncStream<Void>.makeStream()
        let drain = Task {
            do {
                for try await event in attachment.events {
                    if case .output = event { signal.yield(); signal.finish() }
                }
            } catch {}
            signal.finish()
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(2)); signal.finish() }
        defer { drain.cancel(); timeout.cancel() }
        for await _ in drawn { break }
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + 16_384, data.count)
                try await attachment.send(data.subdata(in: offset..<end))
                offset = end
            }
            try await Task.sleep(for: inputHold)
            try await attachment.detach()
        } catch {
            await attachment.disconnect()
            throw error
        }
    }

    /// Whether the shell's prompt came back (and, with `after`, the cursor
    /// moved below that absolute line) and the screen stayed the same for
    /// two looks in a row, before the timeout.
    private func waitUntilIdle(_ session: LocalSessionInfo, after line: Int?, timeout: Double) async throws -> Bool {
        let started = ContinuousClock.now
        let deadline = started + .seconds(timeout)
        var previous: String?
        var settled = 0
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            let place = try await client.place(sessionID: session.id)
            let capture = try await client.capture(sessionID: session.id)
            let moved = line.map { capture.historySize + capture.cursorRow > $0 } ?? true
            // A command that clears the screen may leave the cursor higher;
            // a prompt that has been back for a second still counts.
            let longEnough = ContinuousClock.now - started > .seconds(1)
            if place.command == nil, moved || longEnough, capture.text == previous {
                settled += 1
                if settled >= 2 { return true }
            } else {
                settled = 0
            }
            previous = capture.text
        }
        return false
    }

    // MARK: Helpers

    func resolve(_ arguments: JSONValue) async throws -> LocalSessionInfo {
        guard let reference = arguments["terminal"]?.string, !reference.isEmpty else {
            throw ToolFailure("Name the terminal: its ID, a unique ID prefix, or its exact name. Call list_terminals to see them.")
        }
        do { return try CLIRunner.resolve(reference, in: try await client.sessions()) }
        catch let failure as CLIFailure { throw ToolFailure(failure.message.replacingOccurrences(of: "witerm sessions", with: "list_terminals")) }
    }

    private func integer(_ arguments: JSONValue, _ key: String, default value: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let raw = arguments[key] else { return value }
        guard let number = raw.int, range.contains(number) else {
            throw ToolFailure("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    private func seconds(_ arguments: JSONValue) throws -> Double {
        guard let raw = arguments["timeout_seconds"] else { return 30 }
        guard let seconds = raw.number, seconds >= 1, seconds <= 600 else {
            throw ToolFailure("timeout_seconds must be from 1 to 600.")
        }
        return seconds
    }

    /// One line: name, short ID, size, folder, and what runs there; the
    /// cursor only when something other than the shell has the terminal.
    static func header(_ session: LocalSessionInfo, place: LocalSessionPlace?, capture: LocalTerminalCapture) -> String {
        var line = "“\(session.name)” (\(session.id.prefix(8))) \(session.columns)×\(session.rows)"
        if let place { line += " · \(abbreviate(place.cwd)) · " + (place.command.map { "running \($0)" } ?? "at the prompt") }
        if capture.alternateScreen { line += " · full-screen program" }
        if capture.alternateScreen || place?.command != nil {
            line += " · cursor row \(capture.cursorRow + 1), column \(capture.cursorColumn + 1)"
        }
        return line
    }

    static func body(_ text: String, truncated: Bool) -> String {
        (truncated ? "[earlier lines left out]\n" : "") + "```\n" + text + "\n```"
    }

    static func describe(_ attachments: [LocalAttachmentInfo]) -> String {
        attachments.map { "\($0.agent ?? $0.device?.name ?? "this Mac") (\($0.mode == .control ? "typing" : "watching"))" }
            .joined(separator: ", ")
    }

    static func seconds(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func key(_ name: String) -> Data? {
        let named: [String: String] = [
            "enter": "\r", "return": "\r", "tab": "\t", "escape": "\u{1b}", "esc": "\u{1b}", "backspace": "\u{7f}",
            "delete": "\u{1b}[3~", "space": " ", "up": "\u{1b}[A", "down": "\u{1b}[B", "right": "\u{1b}[C",
            "left": "\u{1b}[D", "home": "\u{1b}[H", "end": "\u{1b}[F", "page_up": "\u{1b}[5~", "page_down": "\u{1b}[6~",
        ]
        let lowered = name.lowercased()
        if let sequence = named[lowered] { return Data(sequence.utf8) }
        for prefix in ["ctrl-", "ctrl+", "c-"] where lowered.hasPrefix(prefix) {
            let rest = lowered.dropFirst(prefix.count)
            guard rest.count == 1, let scalar = rest.unicodeScalars.first, scalar.isASCII else { return nil }
            let value = UInt8(scalar.value)
            switch value {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return Data([value - 0x60])
            case UInt8(ascii: "["), UInt8(ascii: "\\"), UInt8(ascii: "]"): return Data([value - 0x40])
            case UInt8(ascii: "@"), UInt8(ascii: " "): return Data([0])
            default: return nil
            }
        }
        return nil
    }
}
