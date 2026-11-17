import Darwin
import Foundation
import XCTest
import WitermCore
@testable import WitermCLI

/// A scripted Responses API: each request gets the next reply, and every
/// request body is kept for inspection.
private final class FakeOpenAI: @unchecked Sendable {
    enum Reply {
        case output([JSONValue])
        case status(Int, String)
        /// Waits until cancelled.
        case hang
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var bodies: [JSONValue] = []
    private(set) var keys: [String] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [JSONValue] { lock.withLock { bodies } }

    var api: OpenAIResponses {
        OpenAIResponses(endpoint: URL(string: "https://api.invalid/v1/responses")!) { [self] request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let reply: Reply = lock.withLock {
                bodies.append(body)
                keys.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                return replies.isEmpty ? .output([Self.message("(no more replies)")]) : replies.removeFirst()
            }
            let url = request.url!
            switch reply {
            case .output(let output):
                let json: JSONValue = ["id": "resp", "status": "completed", "output": .array(output),
                                       "usage": ["input_tokens": 100, "input_tokens_details": ["cached_tokens": 40], "output_tokens": 10]]
                return (try JSONEncoder().encode(json), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .status(let code, let message):
                let json: JSONValue = ["error": ["message": .string(message)]]
                return (try JSONEncoder().encode(json), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            case .hang:
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        }
    }

    static func message(_ text: String) -> JSONValue {
        ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": .string(text)]]]
    }

    static func call(_ name: String, _ arguments: JSONValue, id: String) -> JSONValue {
        let encoded = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
        return ["type": "function_call", "call_id": .string(id), "name": .string(name), "arguments": .string(encoded)]
    }

    static func reasoning(_ id: String) -> JSONValue {
        ["type": "reasoning", "id": .string(id), "summary": [], "encrypted_content": .string("enc-\(id)")]
    }
}

final class OrbitEngineTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("witerm-orbit-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try OrbitDaemon.privateDirectory(url)
        return url
    }

    private func engine(_ fake: FakeOpenAI, directory: URL? = nil, key: String? = "sk-test") async throws -> OrbitEngine {
        let store = OrbitStore(directory: try directory ?? self.directory())
        try store.prepare()
        let terminals = LocalAgentClient(socketURL: URL(fileURLWithPath: "/private/tmp/witerm-orbit-none/agent.sock"))
        let engine = OrbitEngine(store: store, terminals: terminals, api: fake.api)
        if let key { _ = await engine.handle(OrbitRequest(operation: .configure, apiKey: key)) }
        return engine
    }

    private func start(_ engine: OrbitEngine, _ text: String, kind: OrbitThreadKind) async throws -> String {
        let response = await engine.handle(OrbitRequest(operation: .start, text: text, kind: kind))
        return try XCTUnwrap(response.thread?.summary.id, "\(response)")
    }

    /// Waits for the thread to stop running.
    private func settled(_ engine: OrbitEngine, _ id: String) async throws -> OrbitThreadDetail {
        for _ in 0..<200 {
            let threadValue = await engine.handle(OrbitRequest(operation: .thread, threadID: id)).thread
            let thread = try XCTUnwrap(threadValue)
            if thread.summary.status != .running { return thread }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Still running")
        throw CancellationError()
    }

    func testAChatAnswersAndWaitsForTheNextMessage() async throws {
        let fake = FakeOpenAI([.output([FakeOpenAI.reasoning("r1"), FakeOpenAI.message("Hello! Nothing is running.")])])
        let engine = try await engine(fake)
        let id = try await start(engine, "What's running?", kind: .chat)
        let thread = try await settled(engine, id)
        XCTAssertEqual(thread.summary.status, .idle)
        XCTAssertEqual(thread.entries.map(\.kind), [.user, .assistant])
        XCTAssertEqual(thread.entries.last?.text, "Hello! Nothing is running.")
        XCTAssertEqual(thread.usage, OrbitUsage(inputTokens: 100, cachedTokens: 40, outputTokens: 10))
        let body = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(body["store"], JSONValue.bool(false))
        XCTAssertEqual(body["model"]?.string, OrbitWire.defaultModel)
        XCTAssertEqual(body["include"], JSONValue.array([.string("reasoning.encrypted_content")]))
        XCTAssertEqual(body["prompt_cache_key"]?.string, id)
        XCTAssertEqual(body["parallel_tool_calls"], JSONValue.bool(false))
        let tools = (body["tools"]?.array ?? []).compactMap { $0["name"]?.string }
        XCTAssertTrue(tools.contains("run_command") && tools.contains("update_plan"))
        XCTAssertFalse(tools.contains("finish_task"), "A chat has no task to finish")
        XCTAssertEqual(fake.keys, ["Bearer sk-test"])
        // The next turn sends the earlier answer, but not its reasoning.
        _ = await engine.handle(OrbitRequest(operation: .send, threadID: id, text: "Thanks"))
        _ = try await settled(engine, id)
        let second = try XCTUnwrap(fake.requests.last?["input"]?.array)
        XCTAssertEqual(second.map { $0["type"]?.string ?? $0["role"]?.string }, ["user", "assistant", "user"])
    }

    func testATaskPlansWorksAndFinishes() async throws {
        let fake = FakeOpenAI([
            .output([FakeOpenAI.reasoning("r1"),
                     FakeOpenAI.call("update_plan", ["steps": [["text": "Look", "status": "active"], ["text": "Report", "status": "pending"]]], id: "c1")]),
            .output([FakeOpenAI.message("Done looking."),
                     FakeOpenAI.call("finish_task", ["summary": "All checks passed.", "success": true], id: "c2")]),
        ])
        let engine = try await engine(fake)
        let id = try await start(engine, "Check the build", kind: .task)
        let thread = try await settled(engine, id)
        XCTAssertEqual(thread.summary.status, .done)
        XCTAssertEqual(thread.plan, [OrbitPlanStep(text: "Look", status: .active), OrbitPlanStep(text: "Report", status: .pending)])
        XCTAssertEqual(thread.entries.compactMap(\.text), ["Check the build", "Done looking.", "All checks passed."])
        XCTAssertTrue((fake.requests.first?["tools"]?.array ?? []).contains { $0["name"]?.string == "finish_task" })
        // The second request carries the run's reasoning and the call's answer, in order.
        let input = try XCTUnwrap(fake.requests.last?["input"]?.array)
        XCTAssertEqual(input.map { $0["type"]?.string ?? $0["role"]?.string },
                       ["user", "reasoning", "function_call", "function_call_output"])
        XCTAssertEqual(input[1]["encrypted_content"]?.string, "enc-r1")
        // The summary is recorded after the call's output, never between them.
        let itemsValue = await engine.record(id)
        let items = try XCTUnwrap(itemsValue).items
        let output = try XCTUnwrap(items.lastIndex { $0.kind == .output })
        XCTAssertEqual(items[output + 1].text, "All checks passed.")
    }

    func testWithoutAKeyOrbitWaitsAndSaysWhy() async throws {
        let fake = FakeOpenAI([.output([FakeOpenAI.message("Now I can.")])])
        let engine = try await engine(fake, key: nil)
        let id = try await start(engine, "Hi", kind: .chat)
        var thread = try await settled(engine, id)
        XCTAssertEqual(thread.summary.status, .waiting)
        XCTAssertEqual(thread.entries.last?.failure, .missingKey)
        XCTAssertTrue(fake.requests.isEmpty)
        let status = await engine.handle(OrbitRequest(operation: .configure, apiKey: "sk-new", model: "gpt-6.1-terra")).status
        XCTAssertEqual(status?.hasKey, true)
        XCTAssertEqual(status?.model, "gpt-6.1-terra")
        _ = await engine.handle(OrbitRequest(operation: .send, threadID: id, text: "Try again"))
        thread = try await settled(engine, id)
        XCTAssertEqual(thread.entries.last?.text, "Now I can.")
        XCTAssertEqual(fake.requests.first?["model"]?.string, "gpt-6.1-terra")
        // An empty key forgets it; a bad key or model is refused.
        let cleared = await engine.handle(OrbitRequest(operation: .configure, apiKey: "")).status
        XCTAssertEqual(cleared?.hasKey, false)
        let badKey = await engine.handle(OrbitRequest(operation: .configure, apiKey: "sk bad"))
        XCTAssertEqual(badKey.error, .invalidRequest)
        let badModel = await engine.handle(OrbitRequest(operation: .configure, model: "gpt 6"))
        XCTAssertEqual(badModel.error, .invalidRequest)
    }

    func testAPIErrorsAreNamed() async throws {
        let fake = FakeOpenAI([.status(401, "Incorrect API key provided."), .status(429, "Rate limit reached."), .status(500, "Oops")])
        let engine = try await engine(fake)
        let id = try await start(engine, "Hi", kind: .chat)
        var thread = try await settled(engine, id)
        XCTAssertEqual(thread.entries.last?.failure, .keyRejected)
        XCTAssertEqual(thread.entries.last?.text, "Incorrect API key provided.")
        XCTAssertEqual(thread.summary.status, .waiting)
        _ = await engine.handle(OrbitRequest(operation: .send, threadID: id, text: "Again"))
        thread = try await settled(engine, id)
        XCTAssertEqual(thread.entries.last?.failure, .limited)
        let task = try await start(engine, "Do it", kind: .task)
        let failed = try await settled(engine, task)
        XCTAssertEqual(failed.entries.last?.failure, .api)
        XCTAssertEqual(failed.summary.status, .failed)
    }

    func testStopEndsTheRunAndAnotherCanStart() async throws {
        let fake = FakeOpenAI([.hang, .output([FakeOpenAI.message("Back.")])])
        let engine = try await engine(fake)
        let id = try await start(engine, "Long one", kind: .task)
        for _ in 0..<100 where fake.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let stoppedValue = await engine.handle(OrbitRequest(operation: .stop, threadID: id)).thread
        let stopped = try XCTUnwrap(stoppedValue)
        XCTAssertEqual(stopped.summary.status, .stopped)
        XCTAssertEqual(stopped.entries.last?.note, .stopped)
        let running = await engine.runningCount
        XCTAssertEqual(running, 0)
        _ = await engine.handle(OrbitRequest(operation: .send, threadID: id, text: "Continue"))
        let thread = try await settled(engine, id)
        XCTAssertEqual(thread.entries.last?.text, "Back.")
        let input = try XCTUnwrap(fake.requests.last?["input"]?.array)
        XCTAssertTrue(input.contains { $0["role"]?.string == "developer" && ($0["content"]?.string ?? "").contains("stopped") })
    }

    func testAnotherAgentCanTakeOverGuideAndFinish() async throws {
        let fake = FakeOpenAI([.hang, .output([FakeOpenAI.message("Following Codex's advice.")])])
        let engine = try await engine(fake)
        let id = try await start(engine, "Fix the tests", kind: .task)
        let takenValue = await engine.handle(OrbitRequest(operation: .takeOver, threadID: id, agent: "Codex")).thread
        let taken = try XCTUnwrap(takenValue)
        XCTAssertEqual(taken.summary.status, .takenOver)
        XCTAssertEqual(taken.summary.takenOverBy, "Codex")
        let other = await engine.handle(OrbitRequest(operation: .takeOver, threadID: id, agent: "Claude Code"))
        XCTAssertEqual(other.error, .busy)
        let guideOther = await engine.handle(OrbitRequest(operation: .send, threadID: id, text: "Hi", agent: "Claude Code"))
        XCTAssertEqual(guideOther.error, .busy)
        let finishOther = await engine.handle(OrbitRequest(operation: .finish, threadID: id, text: "Done", agent: "Claude Code", success: true))
        XCTAssertEqual(finishOther.error, .busy)
        // Guidance from the agent that has it hands it back to Orbit.
        _ = await engine.handle(OrbitRequest(operation: .send, threadID: id, text: "Run the unit tests first.", agent: "Codex"))
        let resumed = try await settled(engine, id)
        XCTAssertNil(resumed.summary.takenOverBy)
        XCTAssertTrue(resumed.entries.contains { $0.kind == .user && $0.from == "Codex" })
        let input = try XCTUnwrap(fake.requests.last?["input"]?.array)
        XCTAssertTrue(input.contains { ($0["content"]?.string ?? "").contains("[Message from Codex") })
        XCTAssertTrue(input.contains { ($0["content"]?.string ?? "").contains("Codex took this thread over") })
        _ = await engine.handle(OrbitRequest(operation: .takeOver, threadID: id, agent: "Codex"))
        let finishedValue = await engine.handle(OrbitRequest(operation: .finish, threadID: id, text: "Fixed two tests.",
                                                                       agent: "Codex", success: true)).thread
        let finished = try XCTUnwrap(finishedValue)
        XCTAssertEqual(finished.summary.status, .done)
        XCTAssertEqual(finished.entries.last?.note, .finishedByAgent)
        XCTAssertEqual(finished.entries.last?.text, "Fixed two tests.")
    }

    /// Older tool output and reasoning stay out of the request; the latest
    /// run keeps its own; a call cut off by a stop still gets an answer.
    func testInputKeepsOnlyWhatTheModelNeeds() {
        var record = OrbitRecord(title: "t", kind: .chat)
        let long = "“api” (12345678) 80×24 · ~ · at the prompt\n" + String(repeating: "old output\n", count: 100)
        record.items = [
            OrbitItem(kind: .user, text: "First"),
            OrbitItem(kind: .reasoning, raw: ["type": "reasoning", "id": "old"]),
            OrbitItem(kind: .call, name: "read_terminal", callID: "a", arguments: "{}"),
            OrbitItem(kind: .output, callID: "a", output: long),
            OrbitItem(kind: .call, name: "send_input", callID: "cut", arguments: "{}"),
            OrbitItem(kind: .assistant, text: "Earlier answer"),
            OrbitItem(kind: .user, text: "Second"),
            OrbitItem(kind: .reasoning, raw: ["type": "reasoning", "id": "new"]),
            OrbitItem(kind: .call, name: "read_terminal", callID: "b", arguments: "{}"),
            OrbitItem(kind: .output, callID: "b", output: long),
        ]
        record.runStart = 6
        record.memory = "The user works on api."
        let input = OrbitEngine.input(for: record)
        XCTAssertTrue((input.first?["content"]?.string ?? "").contains("The user works on api."))
        let reasoning = input.filter { $0["type"]?.string == "reasoning" }.compactMap { $0["id"]?.string }
        XCTAssertEqual(reasoning, ["new"])
        let outputs = Dictionary(uniqueKeysWithValues: input.filter { $0["type"]?.string == "function_call_output" }
            .compactMap { item in item["call_id"]?.string.map { ($0, item["output"]?.string ?? "") } })
        XCTAssertTrue(outputs["a"]?.contains("left out to save space") == true, outputs["a"] ?? "")
        XCTAssertFalse(outputs["a"]?.contains("old output") == true)
        XCTAssertEqual(outputs["b"], long)
        XCTAssertEqual(outputs["cut"], "Stopped before this finished.")
        // Items before the memory's end aren't sent.
        record.memoryCount = 6
        XCTAssertFalse(OrbitEngine.input(for: record).contains { $0["content"]?.string == "First" })
    }

    func testALongThreadIsSummarizedIntoOrbitsMemory() async throws {
        let fake = FakeOpenAI([
            .output([FakeOpenAI.message("First answer " + String(repeating: "x", count: 3000))]),
            .output([FakeOpenAI.message("MEMORY: the user asked about x.")]),
            .output([FakeOpenAI.message("Second answer")]),
        ])
        let engine = try await engine(fake)
        await engine.setLimits(compaction: 1000)
        let id = try await start(engine, "Tell me about x", kind: .chat)
        _ = try await settled(engine, id)
        _ = await engine.handle(OrbitRequest(operation: .send, threadID: id, text: "And now?"))
        let thread = try await settled(engine, id)
        XCTAssertEqual(thread.memory, "MEMORY: the user asked about x.")
        XCTAssertTrue(thread.entries.contains { $0.note == .summarized })
        XCTAssertEqual(thread.entries.last?.text, "Second answer")
        let summaryRequest = fake.requests[1]
        XCTAssertNil(summaryRequest["tools"], "The summary request uses no tools")
        let last = try XCTUnwrap(fake.requests.last?["input"]?.array)
        XCTAssertTrue((last.first?["content"]?.string ?? "").contains("MEMORY: the user asked about x."))
        XCTAssertFalse(last.contains { ($0["content"]?.string ?? "").hasPrefix("First answer") }, "Summarized turns were still sent")
        XCTAssertEqual(last.last?["content"]?.string, "And now?")
    }

    func testThreadsPersistAndOldOnesAreRemoved() async throws {
        let folder = try directory()
        let fake = FakeOpenAI([.output([FakeOpenAI.message("Hi")])])
        let first = try await engine(fake, directory: folder)
        let id = try await start(first, "Remember me", kind: .chat)
        _ = try await settled(first, id)
        let file = folder.appendingPathComponent("threads/\(id).json")
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let store = OrbitStore(directory: folder)
        var old = OrbitRecord(title: "Old", kind: .chat)
        old.updatedAt = Date(timeIntervalSinceNow: -31 * 24 * 3600)
        try store.save(old)
        var interrupted = OrbitRecord(title: "Was running", kind: .task)
        interrupted.status = .running
        try store.save(interrupted)
        let second = try await engine(fake, directory: folder)
        let threadsValue = await second.handle(OrbitRequest(operation: .threads)).threads
        let threads = try XCTUnwrap(threadsValue)
        XCTAssertEqual(Set(threads.map(\.title)), ["Remember me", "Was running"])
        XCTAssertEqual(threads.first { $0.title == "Was running" }?.status, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("threads/\(old.id).json").path))
        _ = await second.handle(OrbitRequest(operation: .clear))
        let none = await second.handle(OrbitRequest(operation: .threads)).threads
        XCTAssertEqual(none, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("threads").path), [])
    }

    func testRequestsAreChecked() async throws {
        let engine = try await engine(FakeOpenAI([]))
        let empty = await engine.handle(OrbitRequest(operation: .start, text: "  ", kind: .chat))
        XCTAssertEqual(empty.error, .invalidRequest)
        let huge = await engine.handle(OrbitRequest(operation: .start, text: String(repeating: "a", count: 40_000), kind: .chat))
        XCTAssertEqual(huge.error, .invalidRequest)
        let badTerminal = await engine.handle(OrbitRequest(operation: .start, text: "Hi", kind: .chat, terminalID: "nope"))
        XCTAssertEqual(badTerminal.error, .invalidRequest)
        let missing = await engine.handle(OrbitRequest(operation: .thread, threadID: UUID().uuidString.lowercased()))
        XCTAssertEqual(missing.error, .notFound)
        let version = await engine.handle(OrbitRequest(version: 2, operation: .status))
        XCTAssertEqual(version.error, .unsupportedVersion)
        XCTAssertEqual(OrbitEngine.title("Line one\nline two"), "Line one")
        XCTAssertEqual(OrbitEngine.title(String(repeating: "a", count: 80)).count, 60)
    }
}

/// The real `witerm orbit serve` process and its socket.
@MainActor
final class OrbitDaemonTests: XCTestCase {
    private var binary: URL {
        Bundle(for: OrbitDaemonTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("witerm")
    }

    func testTheDaemonServesItsOwnerAndOnlyOneRuns() async throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build the witerm product first") }
        let folder = URL(fileURLWithPath: "/private/tmp/witerm-orbit-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["orbit", "serve"]
            // Requests go to a closed port on this Mac, never to OpenAI.
            process.environment = ["WITERM_ORBIT_DIRECTORY": folder.path,
                                   "WITERM_ORBIT_OPENAI_URL": "http://127.0.0.1:9/v1/responses",
                                   "WITERM_AGENT_SOCKET": folder.appendingPathComponent("none.sock").path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        let daemon = try launch()
        addTeardownBlock {
            daemon.terminate()
            daemon.waitUntilExit()
            try? FileManager.default.removeItem(at: folder)
        }
        let client = OrbitClient(socketURL: folder.appendingPathComponent(OrbitPaths.socketName))
        var status: OrbitStatus?
        for _ in 0..<100 {
            status = try? await client.status()
            if status != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(status?.hasKey, false)
        var info = stat()
        XCTAssertEqual(lstat(folder.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(folder.appendingPathComponent(OrbitPaths.socketName).path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let configured = try await client.configure(apiKey: "sk-test", model: nil)
        XCTAssertTrue(configured.hasKey)
        let thread = try await client.start(text: "Hello", kind: .chat, terminalID: nil)
        XCTAssertEqual(thread.entries.first?.text, "Hello")
        let threads = try await client.threads()
        XCTAssertEqual(threads.map(\.id), [thread.summary.id])
        try await client.delete(thread.summary.id)
        do { _ = try await client.thread(thread.summary.id); XCTFail("Deleted thread answered") }
        catch OrbitClientError.rejected(let code) { XCTAssertEqual(code, .notFound) }
        // A second instance for the same folder leaves at once.
        let second = try launch()
        second.waitUntilExit()
        XCTAssertEqual(second.terminationStatus, 0)
        let stillServing = try? await client.status()
        XCTAssertNotNil(stillServing, "The first instance stopped serving")
    }
}
