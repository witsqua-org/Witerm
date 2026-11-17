import Darwin
import Foundation

/// A JSON value, for the Model Context Protocol's JSON-RPC messages.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value && abs(value) < 1e15: Int(value)
        default: nil
        }
    }
    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}

/// A JSON-RPC error answered to the client.
struct MCPError: Error, Equatable {
    let code: Int
    let message: String

    static let parse = MCPError(code: -32700, message: "Parse error")
    static let invalidRequest = MCPError(code: -32600, message: "Invalid request")
    static func methodNotFound(_ method: String) -> MCPError { MCPError(code: -32601, message: "Method not found: \(method)") }
    static func invalidParams(_ message: String) -> MCPError { MCPError(code: -32602, message: message) }
}

/// `witerm mcp`: a Model Context Protocol server on stdin and stdout, one
/// JSON-RPC message per line, so agents such as Codex and Claude Code can read
/// and drive this Mac's Witerm terminals. Nothing but protocol messages is
/// written to stdout; terminal text is never logged.
final class MCPServer: Sendable {
    /// Newest first; an unknown requested version gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// Longer lines are refused rather than buffered.
    static let lineLimit = 4 << 20

    let tools: TerminalTools
    /// Orbit's tasks, for agents that guide or take them over.
    let orbit: OrbitHandoffTools?
    private let output: MCPLineWriter

    static let instructions = """
    Witerm terminals are the user's own shells on this Mac. The user can watch every terminal live in Witerm, \
    and may be typing in one at the same time; when a tool says someone is typing, wait and read again. \
    Look at a terminal before typing in it. Every tool returns what changed on the screen since your last look, \
    so a separate read_terminal after run_command, send_input or create_terminal is rarely needed. Use run_command for shell \
    commands at a prompt, and send_input for programs that are waiting for keys (editors, prompts, REPLs). \
    Never type passwords or other secrets; ask the user to type them. Prefer create_terminal for your own work \
    instead of taking over a terminal the user is using. Orbit, Witerm's own assistant, may be working on tasks: \
    list_orbit_tasks shows them, and you can guide one or take it over.
    """

    init(tools: TerminalTools, orbit: OrbitHandoffTools? = nil,
         output: MCPLineWriter = MCPLineWriter(descriptor: STDOUT_FILENO)) {
        self.tools = tools
        self.orbit = orbit
        self.output = output
    }

    /// The name people see while this agent types ("Codex is typing"),
    /// from the client's own description of itself.
    static func agentName(clientInfo: JSONValue?) -> String {
        let name = clientInfo?["name"]?.string ?? ""
        let title = clientInfo?["title"]?.string
        let lowered = (name + " " + (title ?? "")).lowercased()
        if lowered.contains("codex") { return "Codex" }
        if lowered.contains("claude") { return "Claude Code" }
        for candidate in [title, name].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            let cleaned = String(String.UnicodeScalarView(candidate.unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }.prefix(64)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return "Agent"
    }

    /// Serves until stdin ends. Requests run concurrently, so a long
    /// `run_command` doesn't hold up `ping` or another terminal's call.
    func serve() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.isEmpty else { continue }
                // The handshake names the agent before anything it asks for.
                if line.contains("\"initialize\"") {
                    if let reply = await handle(line: line) { output.write(reply) }
                    continue
                }
                group.addTask { [self] in
                    if let reply = await handle(line: line) { output.write(reply) }
                }
            }
            try await group.waitForAll()
        }
    }

    /// The encoded reply to one line, or nil for notifications and responses.
    func handle(line: String) async -> Data? {
        guard line.utf8.count <= Self.lineLimit,
              let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return encode(id: .null, error: .parse)
        }
        guard case .object(let fields) = message else { return encode(id: .null, error: .invalidRequest) }
        let id = fields["id"]
        guard let method = fields["method"]?.string else {
            // A response to a request we never send, or garbage with an id.
            return id == nil || fields["result"] != nil || fields["error"] != nil ? nil : encode(id: id ?? .null, error: .invalidRequest)
        }
        // Notifications (initialized, cancelled) need no answer.
        guard let id else { return nil }
        switch id {
        case .string, .int: break
        default: return encode(id: .null, error: .invalidRequest)
        }
        do {
            return encode(id: id, result: try await respond(to: method, params: fields["params"] ?? [:]))
        } catch let error as MCPError {
            return encode(id: id, error: error)
        } catch {
            return encode(id: id, error: MCPError(code: -32603, message: "Internal error"))
        }
    }

    private func respond(to method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            await tools.state.setAgent(Self.agentName(clientInfo: params["clientInfo"]))
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "witerm", "title": "Witerm", "version": .string(CLIRunner.version)],
                "instructions": .string(Self.instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array((tools.definitions + (orbit?.definitions ?? [])).map(Self.encode))]
        case "tools/call":
            guard let name = params["name"]?.string else { throw MCPError.invalidParams("tools/call needs a tool name.") }
            let arguments = params["arguments"] ?? [:]
            guard case .object = arguments else { throw MCPError.invalidParams("Tool arguments must be an object.") }
            let result: ToolResult
            if let orbit, orbit.offers(name) {
                result = await orbit.run(name, arguments: arguments, agent: await tools.state.agent)
            } else {
                result = try await tools.run(name, arguments: arguments)
            }
            return ["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)]
        default:
            throw MCPError.methodNotFound(method)
        }
    }

    static func encode(_ tool: ToolDefinition) -> JSONValue {
        [
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": tool.schema,
            "annotations": ["title": .string(tool.title), "readOnlyHint": .bool(tool.readOnly),
                            "destructiveHint": .bool(tool.destructive), "idempotentHint": .bool(tool.readOnly),
                            "openWorldHint": false],
        ]
    }

    private func encode(id: JSONValue, result: JSONValue) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(id: JSONValue, error: MCPError) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]])
    }

    private func encode(_ message: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(message)
    }
}

/// Whole lines to a descriptor, one writer at a time, never interleaved.
/// A closed stdout ends the server (SIGPIPE is ignored, so writes fail).
final class MCPLineWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ message: Data) {
        lock.withLock {
            var data = message
            data.append(0x0a)
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0, errno == EINTR { continue }
                    exit(CLIExit.failure.rawValue)
                }
            }
        }
    }
}
