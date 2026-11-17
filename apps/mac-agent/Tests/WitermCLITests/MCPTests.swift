import Darwin
import Foundation
import XCTest
import WitermCore
@testable import WitermCLI
@testable import WitermAgent

final class MCPUnitTests: XCTestCase {
    private func server(readOnly: Bool = false) -> MCPServer {
        let client = LocalAgentClient(socketURL: URL(fileURLWithPath: "/private/tmp/witerm-mcp-unit-none/agent.sock"))
        return MCPServer(tools: TerminalTools(client: client, readOnly: readOnly, state: TerminalToolState(agent: "Agent")))
    }

    private func reply(_ server: MCPServer, _ line: String) async throws -> [String: Any]? {
        guard let data = await server.handle(line: line) else { return nil }
        XCTAssertFalse(data.contains(0x0a), "A reply spans lines")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testParsesTheMCPCommand() throws {
        XCTAssertEqual(try CLIParser.parse(["mcp"]).command, .mcp(readOnly: false))
        XCTAssertEqual(try CLIParser.parse(["mcp", "--read-only"]).command, .mcp(readOnly: true))
        for bad in [["mcp", "--json"], ["mcp", "extra"], ["sessions", "--read-only"]] {
            XCTAssertThrowsError(try CLIParser.parse(bad), "\(bad)")
        }
    }

    func testHandshakeListsToolsAndAnswersJSONRPCErrors() async throws {
        let server = server()
        let initialize = try await reply(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let result = try XCTUnwrap(initialize?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "witerm")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let newer = try await reply(server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual((newer?["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.protocolVersions[0])
        XCTAssertEqual(newer?["id"] as? String, "a")

        let notification = try await reply(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification)
        let ping = try await reply(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual((ping?["result"] as? [String: Any])?.count, 0)

        let list = try await reply(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["list_terminals", "read_terminal", "wait_for_terminal", "run_command", "send_input", "create_terminal", "close_terminal"])
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            let readOnly = ["list_terminals", "read_terminal", "wait_for_terminal"].contains(tool["name"] as? String)
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, readOnly)
        }

        func code(_ line: String) async throws -> Int? {
            ((try await reply(server, line))?["error"] as? [String: Any])?["code"] as? Int
        }
        let parseError = try await code("not json")
        XCTAssertEqual(parseError, -32700)
        let unknownMethod = try await code(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)
        XCTAssertEqual(unknownMethod, -32601)
        let unknownTool = try await code(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}"#)
        XCTAssertEqual(unknownTool, -32602)
        let badArguments = try await code(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_terminals","arguments":[]}}"#)
        XCTAssertEqual(badArguments, -32602)
        let badID = try await code(#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)
        XCTAssertEqual(badID, -32600)
        let response = try await reply(server, #"{"jsonrpc":"2.0","id":7,"result":{}}"#)
        XCTAssertNil(response, "A response from the client was answered")
    }

    func testReadOnlyServerOffersNoWritingTools() async throws {
        let server = server(readOnly: true)
        let list = try await reply(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["list_terminals", "read_terminal", "wait_for_terminal"])
        for name in ["run_command", "send_input", "create_terminal", "close_terminal"] {
            let call = try await reply(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(name)","arguments":{"terminal":"x"}}}"#)
            XCTAssertEqual((call?["error"] as? [String: Any])?["code"] as? Int, -32602, name)
        }
    }

    func testUnreachableServiceIsAToolError() async throws {
        let call = try await reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_terminals","arguments":{}}}"#)
        let result = try XCTUnwrap(call?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(text.contains("background service"), text)
    }

    func testNamedKeys() {
        XCTAssertEqual(TerminalTools.key("enter"), Data("\r".utf8))
        XCTAssertEqual(TerminalTools.key("Ctrl-C"), Data([3]))
        XCTAssertEqual(TerminalTools.key("ctrl+d"), Data([4]))
        XCTAssertEqual(TerminalTools.key("ctrl-["), Data([0x1b]))
        XCTAssertEqual(TerminalTools.key("up"), Data("\u{1b}[A".utf8))
        XCTAssertEqual(TerminalTools.key("page_down"), Data("\u{1b}[6~".utf8))
        XCTAssertNil(TerminalTools.key("ctrl-cc"))
        XCTAssertNil(TerminalTools.key("ctrl-é"))
        XCTAssertNil(TerminalTools.key("hyper"))
    }

    /// People see "Codex is typing", from the client's own description.
    func testNamesTheAgentFromItsClientInfo() async throws {
        XCTAssertEqual(MCPServer.agentName(clientInfo: ["name": "codex-mcp-client", "version": "1"]), "Codex")
        XCTAssertEqual(MCPServer.agentName(clientInfo: ["name": "claude-code"]), "Claude Code")
        XCTAssertEqual(MCPServer.agentName(clientInfo: ["name": "x", "title": "My Bot\u{7}"]), "My Bot")
        XCTAssertEqual(MCPServer.agentName(clientInfo: nil), "Agent")
        let server = server()
        _ = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-mcp-client"}}}"#)
        let agent = await server.tools.state.agent
        XCTAssertEqual(agent, "Codex")
    }

    /// Long output keeps its head and tail, and says how much is left out.
    func testLongOutputIsShortened() {
        let text = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let short = TerminalTools.shortened(text)
        XCTAssertTrue(short.hasPrefix("line 1\n"))
        XCTAssertTrue(short.hasSuffix("line 500"))
        XCTAssertTrue(short.contains("[350 lines left out"), short)
        XCTAssertEqual(TerminalTools.shortened("a\nb"), "a\nb")
    }
}

/// Runs the real `witerm mcp` against a private broker and tmux, the way
/// Codex and Claude Code start it: one JSON-RPC message per line on stdio.
@MainActor
final class MCPIntegrationTests: XCTestCase {
    private var binary: URL {
        if let installed = ProcessInfo.processInfo.environment["WITERM_CLI_TEST_BINARY"] {
            return URL(fileURLWithPath: installed)
        }
        return Bundle(for: MCPIntegrationTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("witerm")
    }

    private func startBroker() throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build the witerm product first") }
        let url = URL(fileURLWithPath: "/private/tmp/witerm-mcp-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        addTeardownBlock {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: url)
        }
        return url.appendingPathComponent("agent.sock")
    }

    func testAnAgentRunsCommandsTypesAndEndsOnlyItsOwnTerminals() async throws {
        let socket = try startBroker()
        let user = try await LocalAgentClient(socketURL: socket).create(name: "Mine", columns: 80, rows: 24)
        let server = try MCPProcess(binary: binary, socket: socket)
        defer { server.stop() }
        _ = try await server.call("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        server.notify("notifications/initialized")

        let created = try await server.tool("create_terminal", ["name": "Agent work", "folder": "/private/tmp"])
        XCTAssertFalse(created.error, created.text)
        let id = try XCTUnwrap(created.text.range(of: #"[0-9a-f]{8}-[0-9a-f-]{27}"#, options: .regularExpression).map { String(created.text[$0]) })

        let listed = try await server.tool("list_terminals", [:])
        XCTAssertTrue(listed.text.contains("“Mine”") && listed.text.contains("“Agent work”"), listed.text)

        let ran = try await server.tool("run_command", ["terminal": id, "command": "echo answer-$((6*7))", "timeout_seconds": 20])
        XCTAssertFalse(ran.error, ran.text)
        XCTAssertTrue(ran.text.hasPrefix("Finished"), ran.text)
        XCTAssertTrue(ran.text.contains("echo answer-$((6*7))\nanswer-42"), ran.text)

        // A running program: run_command refuses, keys stop it, the prompt returns.
        let slept = try await server.tool("run_command", ["terminal": id, "command": "sleep 30", "timeout_seconds": 1])
        XCTAssertTrue(slept.text.hasPrefix("Still running sleep"), slept.text)
        let refused = try await server.tool("run_command", ["terminal": id, "command": "echo no"])
        XCTAssertTrue(refused.error && refused.text.contains("running sleep"), refused.text)
        let interrupted = try await server.tool("send_input", ["terminal": id, "keys": ["ctrl-c"]])
        XCTAssertFalse(interrupted.error, interrupted.text)
        let idle = try await server.tool("wait_for_terminal", ["terminal": id, "timeout_seconds": 10])
        XCTAssertTrue(idle.text.hasPrefix("The prompt is back."), idle.text)

        let typed = try await server.tool("send_input", ["terminal": "Agent work", "text": "echo typed-$((1+2))\n"])
        XCTAssertFalse(typed.error, typed.text)
        let appeared = try await server.tool("wait_for_terminal", ["terminal": id, "text": "typed-3", "timeout_seconds": 10])
        XCTAssertTrue(appeared.text.hasPrefix("The text appeared."), appeared.text)
        let read = try await server.tool("read_terminal", ["terminal": String(id.prefix(8)), "history_lines": 100])
        XCTAssertTrue(read.text.contains("answer-42") && read.text.contains("at the prompt"), read.text)
        // Reads after the first say only what changed.
        let unchanged = try await server.tool("read_terminal", ["terminal": id])
        XCTAssertTrue(unchanged.text.hasSuffix("No change since your last look."), unchanged.text)
        let more = try await server.tool("run_command", ["terminal": id, "command": "echo more-$((2*3))"])
        XCTAssertTrue(more.text.contains("more-6"), more.text)
        let after = try await server.tool("read_terminal", ["terminal": id])
        XCTAssertTrue(after.text.hasSuffix("No change since your last look."), "run_command counts as a look: \(after.text)")
        let typedMore = try await server.tool("send_input", ["terminal": id, "text": "echo diff-$((3+4))\n"])
        XCTAssertTrue(typedMore.text.contains("diff-7"), typedMore.text)
        XCTAssertTrue(typedMore.text.contains("you've seen left out"), typedMore.text)
        XCTAssertFalse(typedMore.text.contains("answer-42"), "Seen lines were repeated: \(typedMore.text)")
        let full = try await server.tool("read_terminal", ["terminal": id, "full": true])
        XCTAssertTrue(full.text.contains("diff-7") && !full.text.contains("No change"), full.text)

        let bad = try await server.tool("send_input", ["terminal": id, "keys": ["hyper"]])
        XCTAssertTrue(bad.error)
        let missing = try await server.tool("read_terminal", ["terminal": "nothing-like-it"])
        XCTAssertTrue(missing.error && missing.text.contains("list_terminals"), missing.text)

        let notMine = try await server.tool("close_terminal", ["terminal": user.id])
        XCTAssertTrue(notMine.error, "The agent ended the user's terminal")
        let closed = try await server.tool("close_terminal", ["terminal": id])
        XCTAssertFalse(closed.error, closed.text)
        let remaining = try await LocalAgentClient(socketURL: socket).sessions().map(\.id)
        XCTAssertEqual(remaining, [user.id])
    }
}

/// A `witerm mcp` child process spoken to over pipes.
private final class MCPProcess: @unchecked Sendable {
    struct ToolResult { let text: String; let error: Bool }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1

    init(binary: URL, socket: URL) throws {
        process.executableURL = binary
        process.arguments = ["mcp"]
        process.environment = ["WITERM_AGENT_SOCKET": socket.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock { self.buffer.append(data) }
        }
        try process.run()
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
    }

    func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { defer { nextID += 1 }; return nextID }
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let line: Data? = lock.withLock {
                guard let end = buffer.firstIndex(of: 0x0a) else { return nil }
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                return Data(line)
            }
            if let line {
                let message = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
                XCTAssertEqual(message["id"] as? Int, id)
                return message
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CLIFailure(exit: .failure, code: "timeout", message: "No answer to \(method)")
    }

    func tool(_ name: String, _ arguments: [String: Any]) async throws -> ToolResult {
        let message = try await call("tools/call", ["name": name, "arguments": arguments])
        let result = try XCTUnwrap(message["result"] as? [String: Any], "\(message)")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return ToolResult(text: text, error: result["isError"] as? Bool ?? false)
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        input.fileHandleForWriting.write(data + Data("\n".utf8))
    }
}
