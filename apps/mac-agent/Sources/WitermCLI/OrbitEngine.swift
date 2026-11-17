import Foundation
import WitermCore

/// Orbit's conversations and delegated tasks, run against the OpenAI
/// Responses API with Witerm's terminal tools. One run per thread at a time;
/// a message that arrives while it runs is read at its next step.
///
/// Context (docs/orbit.md): the full record stays in the thread's file. Each
/// request sends Orbit's summary of older turns, the turns since verbatim,
/// tool output in full only for the run in progress (and only its latest
/// eight), and reasoning only from that run. Instructions and tools come
/// first and don't change, so the API can cache them.
actor OrbitEngine {
    let store: OrbitStore
    let terminals: LocalAgentClient
    let api: OpenAIResponses
    private(set) var apiKey: String?
    private(set) var model = OrbitWire.defaultModel
    private var records: [String: OrbitRecord] = [:]
    private var runs: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var toolStates: [String: TerminalToolState] = [:]
    private(set) var lastRequest = ContinuousClock.now

    /// Model requests in one run before Orbit stops to ask.
    var stepLimit = 50
    /// Sent input past this many characters is summarized first.
    var compactionThreshold = 120_000
    /// Tool outputs kept whole in the run in progress.
    static let fullOutputs = 8
    /// Older tool output longer than this is cut to its first line.
    static let elisionLength = 400
    static let agentName = "Orbit"

    init(store: OrbitStore, terminals: LocalAgentClient, api: OpenAIResponses = OpenAIResponses()) {
        self.store = store
        self.terminals = terminals
        self.api = api
        for record in store.load() { records[record.id] = record }
    }

    var runningCount: Int { runs.count }

    /// For tests: fewer steps, or summarizing sooner.
    func setLimits(steps: Int? = nil, compaction: Int? = nil) {
        if let steps { stepLimit = steps }
        if let compaction { compactionThreshold = compaction }
    }

    /// For tests: the stored record.
    func record(_ id: String) -> OrbitRecord? { records[id] }

    // MARK: Requests

    func handle(_ request: OrbitRequest) async -> OrbitResponse {
        lastRequest = .now
        func fail(_ code: OrbitErrorCode) -> OrbitResponse { OrbitResponse(id: request.id, ok: false, error: code) }
        func ok(_ record: OrbitRecord) -> OrbitResponse { OrbitResponse(id: request.id, ok: true, thread: record.detail) }
        guard request.version == 1 else { return fail(.unsupportedVersion) }
        switch request.operation {
        case .status:
            return OrbitResponse(id: request.id, ok: true, status: status)
        case .configure:
            if let key = request.apiKey {
                guard key.count <= 512, !key.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }) else {
                    return fail(.invalidRequest)
                }
                apiKey = key.isEmpty ? nil : key
            }
            if let model = request.model {
                guard OrbitWire.validModel(model) else { return fail(.invalidRequest) }
                self.model = model
            }
            return OrbitResponse(id: request.id, ok: true, status: status)
        case .threads:
            return OrbitResponse(id: request.id, ok: true,
                                 threads: records.values.sorted { $0.updatedAt > $1.updatedAt }.map(\.summary))
        case .thread:
            guard let id = request.threadID, let record = records[id] else { return fail(.notFound) }
            return ok(record)
        case .start:
            guard let text = Self.message(request.text), let kind = request.kind,
                  request.terminalID.map(Self.validID) ?? true else { return fail(.invalidRequest) }
            guard records.count < OrbitStore.maximumThreads || dropOldest() else { return fail(.busy) }
            var record = OrbitRecord(title: Self.title(text), kind: kind, terminalID: request.terminalID)
            var item = OrbitItem(kind: .user, text: text)
            item.context = await anchorContext(request.terminalID)
            record.items.append(item)
            records[record.id] = record
            begin(record.id)
            return ok(records[record.id]!)
        case .send:
            guard let id = request.threadID, var record = records[id] else { return fail(.notFound) }
            guard let text = Self.message(request.text), request.agent.map(OrbitWire.validAgent) ?? true else {
                return fail(.invalidRequest)
            }
            if let holder = record.takenOverBy, let agent = request.agent, agent != holder { return fail(.busy) }
            var item = OrbitItem(kind: .user, text: text)
            item.from = request.agent
            record.items.append(item)
            // A message from the user, or from the agent that took it over,
            // gives the thread back to Orbit.
            record.takenOverBy = nil
            records[id] = record
            if runs[id] == nil { begin(id) } else { touch(id) }
            return ok(records[id]!)
        case .stop:
            guard let id = request.threadID, records[id] != nil else { return fail(.notFound) }
            if cancel(id) {
                update(id) { record in
                    record.status = record.kind == .task ? .stopped : .idle
                    record.items.append(OrbitItem(kind: .note, note: .stopped))
                }
            }
            return ok(records[id]!)
        case .takeOver:
            guard let id = request.threadID, records[id] != nil else { return fail(.notFound) }
            guard let agent = request.agent, OrbitWire.validAgent(agent) else { return fail(.invalidRequest) }
            if let holder = records[id]?.takenOverBy, holder != agent { return fail(.busy) }
            _ = cancel(id)
            update(id) { record in
                record.status = .takenOver
                record.takenOverBy = agent
                var note = OrbitItem(kind: .note, note: .takenOver)
                note.from = agent
                record.items.append(note)
            }
            return ok(records[id]!)
        case .finish:
            guard let id = request.threadID, records[id] != nil else { return fail(.notFound) }
            guard let agent = request.agent, let summary = Self.message(request.text) else { return fail(.invalidRequest) }
            guard records[id]?.takenOverBy == agent else { return fail(.busy) }
            update(id) { record in
                record.status = request.success == false ? .failed : .done
                record.takenOverBy = nil
                var note = OrbitItem(kind: .note, text: summary, note: .finishedByAgent)
                note.from = agent
                record.items.append(note)
            }
            return ok(records[id]!)
        case .delete:
            guard let id = request.threadID, records[id] != nil else { return fail(.notFound) }
            _ = cancel(id)
            records.removeValue(forKey: id)
            toolStates.removeValue(forKey: id)
            store.delete(id)
            return OrbitResponse(id: request.id, ok: true)
        case .clear:
            for id in Array(records.keys) {
                _ = cancel(id)
                store.delete(id)
            }
            records.removeAll()
            toolStates.removeAll()
            return OrbitResponse(id: request.id, ok: true)
        }
    }

    private var status: OrbitStatus {
        OrbitStatus(hasKey: apiKey != nil, model: model, running: runs.count)
    }

    static func message(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.utf8.count <= OrbitWire.textLimit else { return nil }
        return text
    }

    static func validID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }

    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count <= 60 ? line : String(line.prefix(59)) + "…"
    }

    private func dropOldest() -> Bool {
        guard let oldest = records.values.filter({ runs[$0.id] == nil }).min(by: { $0.updatedAt < $1.updatedAt }) else { return false }
        records.removeValue(forKey: oldest.id)
        store.delete(oldest.id)
        return true
    }

    /// The first message of a thread started from a terminal says which.
    private func anchorContext(_ terminalID: String?) async -> String? {
        guard let terminalID, let session = try? await terminals.sessions().first(where: { $0.id == terminalID }) else { return nil }
        return "[I started this from the terminal “\(session.name)” (ID \(session.id)). Unless I say otherwise, “this terminal” means that one.]"
    }

    // MARK: Record changes

    private func update(_ id: String, _ change: (inout OrbitRecord) -> Void) {
        guard var record = records[id] else { return }
        change(&record)
        record.revision += 1
        record.updatedAt = Date()
        records[id] = record
        try? store.save(record)
    }

    private func touch(_ id: String) { update(id) { _ in } }

    @discardableResult
    private func cancel(_ id: String) -> Bool {
        guard let run = runs.removeValue(forKey: id) else { return false }
        run.task.cancel()
        return true
    }

    private func begin(_ id: String) {
        update(id) { record in
            record.status = .running
            record.runStart = max(record.items.lastIndex { $0.kind == .user } ?? 0, record.memoryCount)
        }
        let token = UUID()
        let task: Task<Void, Never> = Task { [weak self] in await self?.run(id, token: token) }
        runs[id] = (token: token, task: task)
    }

    /// Whether `token`'s run is still the thread's: a stopped run that is
    /// still unwinding never touches a newer one.
    private func current(_ id: String, _ token: UUID) -> Bool {
        runs[id]?.token == token && !Task.isCancelled
    }

    /// Ends the run `token`, unless it was stopped or replaced.
    private func end(_ id: String, _ token: UUID, status: OrbitThreadStatus, _ change: (inout OrbitRecord) -> Void = { _ in }) {
        guard runs[id]?.token == token else { return }
        runs.removeValue(forKey: id)
        update(id) { record in
            change(&record)
            record.status = status
        }
    }

    private func tools(for id: String) -> TerminalTools {
        let state = toolStates[id] ?? TerminalToolState(agent: Self.agentName, created: Set(records[id]?.created ?? [])) {
            [weak self] created in await self?.didCreate(created, in: id)
        }
        toolStates[id] = state
        return TerminalTools(client: terminals, readOnly: false, state: state)
    }

    private func didCreate(_ terminal: String, in id: String) {
        update(id) { $0.created.append(terminal) }
    }

    // MARK: The run

    private func run(_ id: String, token: UUID) async {
        for _ in 0..<stepLimit {
            guard current(id, token) else { return }
            guard let key = apiKey else {
                return end(id, token, status: .waiting) { $0.items.append(OrbitItem(kind: .error, failure: .missingKey)) }
            }
            await compactIfNeeded(id, key: key)
            guard current(id, token), let record = records[id] else { return }
            let body = request(for: record)
            let response: JSONValue
            do {
                response = try await api.create(body, key: key)
            } catch is CancellationError {
                return
            } catch {
                guard current(id, token) else { return }
                return end(id, token, status: record.kind == .task ? .failed : .waiting) { $0.items.append(Self.errorItem(error)) }
            }
            guard current(id, token) else { return }
            let reply = OpenAIResponses.parse(response)
            update(id) { record in
                record.usage.inputTokens += reply.inputTokens
                record.usage.cachedTokens += reply.cachedTokens
                record.usage.outputTokens += reply.outputTokens
                for part in reply.parts {
                    switch part {
                    case .text(let text): record.items.append(OrbitItem(kind: .assistant, text: text))
                    case .reasoning(let raw): record.items.append(OrbitItem(kind: .reasoning, raw: raw))
                    case .call(let call):
                        record.items.append(OrbitItem(kind: .call, name: call.name, callID: call.callID, arguments: call.arguments))
                    }
                }
            }
            let calls = reply.calls
            if calls.isEmpty {
                return end(id, token, status: record.kind == .task ? .waiting : .idle)
            }
            for call in calls {
                guard current(id, token) else { return }
                if let finished = await perform(call, in: id) {
                    return end(id, token, status: finished ? .done : .failed)
                }
            }
        }
        end(id, token, status: .waiting) { $0.items.append(OrbitItem(kind: .note, note: .stepLimit)) }
    }

    /// Runs one tool call and records its output. For `finish_task`, the
    /// task's outcome.
    private func perform(_ call: OpenAIResponses.Reply.Call, in id: String) async -> Bool? {
        let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .null
        var output: ToolResult
        var outcome: Bool?
        var summary: String?
        switch call.name {
        case "update_plan":
            if let steps = Self.plan(arguments) {
                update(id) { $0.plan = steps }
                output = ToolResult(text: "Plan updated.", isError: false)
            } else {
                output = ToolResult(text: "Give steps: a list of at most 20 {text, status} with status pending, active or done.", isError: true)
            }
        case "finish_task" where records[id]?.kind == .task:
            summary = arguments["summary"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            outcome = arguments["success"]?.bool ?? true
            output = ToolResult(text: "Task marked \(outcome == true ? "done" : "failed").", isError: false)
        default:
            let tools = tools(for: id)
            if case .object = arguments {
                if let reference = arguments["terminal"]?.string,
                   let session = try? await tools.resolve(["terminal": .string(reference)]) {
                    update(id) { record in
                        if let index = record.items.lastIndex(where: { $0.callID == call.callID && $0.kind == .call }) {
                            record.items[index].terminal = session.name
                        }
                    }
                }
                do { output = try await tools.run(call.name, arguments: arguments) }
                catch { output = ToolResult(text: "No tool named \(call.name).", isError: true) }
            } else {
                output = ToolResult(text: "The arguments weren't valid JSON.", isError: true)
            }
        }
        if Task.isCancelled { output = ToolResult(text: "Stopped by the user before this finished.", isError: true) }
        update(id) { record in
            var item = OrbitItem(kind: .output, callID: call.callID, output: output.text)
            item.failed = output.isError ? true : nil
            record.items.append(item)
            // The summary follows the call's output, never between them.
            if let summary, !summary.isEmpty { record.items.append(OrbitItem(kind: .assistant, text: summary)) }
        }
        return outcome
    }

    static func plan(_ arguments: JSONValue) -> [OrbitPlanStep]? {
        guard let steps = arguments["steps"]?.array, steps.count <= 20 else { return nil }
        var plan: [OrbitPlanStep] = []
        for step in steps {
            guard let text = step["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let status = step["status"]?.string.flatMap(OrbitPlanStepStatus.init(rawValue:)) else { return nil }
            plan.append(OrbitPlanStep(text: String(text.prefix(300)), status: status))
        }
        return plan
    }

    static func errorItem(_ error: Error) -> OrbitItem {
        switch error as? OpenAIError {
        case .http(let status, let message)?:
            let failure: OrbitFailure = [401, 403].contains(status) ? .keyRejected : status == 429 ? .limited : .api
            return OrbitItem(kind: .error, text: message, failure: failure)
        case .network?:
            return OrbitItem(kind: .error, failure: .network)
        default:
            return OrbitItem(kind: .error, failure: .api)
        }
    }

    // MARK: Context

    static let instructions = """
    You are Orbit, the assistant built into Witerm, a terminal app on the user's Mac. You can read and operate \
    every Witerm terminal on this Mac with your tools: list them, read what is on screen, run commands, type \
    into programs, and start terminals of your own. The user sees everything you do live in Witerm and may type \
    in the same terminals; when a tool says someone is typing, wait a few seconds and read again.

    How to work:
    - Look at a terminal before typing in it. Every tool returns what changed on the screen since your last \
    look, so you rarely need read_terminal right after another tool.
    - Use run_command for commands at a shell prompt and send_input for programs waiting for keys.
    - For your own work, prefer a new terminal (create_terminal) over one the user is busy in.
    - Never type passwords, tokens or other secrets, and never print them; ask the user to type them.
    - Don't run commands that delete data, rewrite history, force-push, shut down, or spend money unless the \
    user asked for exactly that. When unsure, ask.
    - When you summarize terminal output, be specific: name the error, the file, the line, the number.
    - Reply in the language the user writes in. Be brief.
    """

    static let taskInstructions = """

    This thread is a task the user delegated. Plan it with update_plan (a few concrete steps), keep the plan \
    current as you go, and work until it's done without asking for confirmation of routine steps. When it's \
    done, or can't be done, call finish_task with a short summary for the user. If you need the user to \
    decide something, say so and stop.
    """

    static let chatInstructions = """

    This thread is a conversation. Answer the user's message, using terminals when that helps, then stop.
    """

    func request(for record: OrbitRecord) -> JSONValue {
        var tools = TerminalTools(client: terminals, readOnly: false, state: TerminalToolState(agent: Self.agentName))
            .definitions.map(Self.function)
        tools.append(Self.function(ToolDefinition(
            name: "update_plan", title: "Update the plan",
            description: "Sets your plan for this thread: the whole list of steps, each pending, active or done.",
            schema: ["type": "object", "additionalProperties": false, "required": ["steps"],
                     "properties": ["steps": ["type": "array", "maxItems": 20, "items": [
                        "type": "object", "additionalProperties": false, "required": ["text", "status"],
                        "properties": ["text": ["type": "string"],
                                       "status": ["type": "string", "enum": ["pending", "active", "done"]]]]]]],
            readOnly: false, destructive: false)))
        if record.kind == .task {
            tools.append(Self.function(ToolDefinition(
                name: "finish_task", title: "Finish the task",
                description: "Ends the delegated task with a summary for the user.",
                schema: ["type": "object", "additionalProperties": false, "required": ["summary", "success"],
                         "properties": ["summary": ["type": "string"], "success": ["type": "boolean"]]],
                readOnly: false, destructive: false)))
        }
        return [
            "model": .string(model),
            "instructions": .string(Self.instructions + (record.kind == .task ? Self.taskInstructions : Self.chatInstructions)),
            "input": .array(Self.input(for: record)),
            "tools": .array(tools),
            "parallel_tool_calls": false,
            "store": false,
            "include": ["reasoning.encrypted_content"],
            "prompt_cache_key": .string(record.id),
        ]
    }

    static func function(_ tool: ToolDefinition) -> JSONValue {
        ["type": "function", "name": .string(tool.name), "description": .string(tool.description),
         "parameters": tool.schema, "strict": false]
    }

    /// What the model sees of a thread.
    static func input(for record: OrbitRecord) -> [JSONValue] {
        var input: [JSONValue] = []
        if let memory = record.memory {
            input.append(["role": "user", "content": .string("[Your own summary of the earlier part of this thread]\n" + memory)])
        }
        let items = record.items
        let first = min(record.memoryCount, items.count)
        let runStart = max(record.runStart, first)
        // The latest outputs of the run in progress stay whole.
        let outputIndices = items.indices.filter { $0 >= runStart && items[$0].kind == .output }
        let wholeFrom = outputIndices.suffix(fullOutputs).first ?? items.count
        let answered = Set(items.filter { $0.kind == .output }.compactMap(\.callID))
        for index in first..<items.count {
            let item = items[index]
            switch item.kind {
            case .user:
                var text = item.text ?? ""
                if let from = item.from { text = "[Message from \(from), another AI agent the user works with]\n" + text }
                if let context = item.context { text = context + "\n\n" + text }
                input.append(["role": "user", "content": .string(text)])
            case .assistant:
                input.append(["role": "assistant", "content": .string(item.text ?? "")])
            case .call:
                guard let callID = item.callID, let name = item.name else { continue }
                input.append(["type": "function_call", "call_id": .string(callID), "name": .string(name),
                              "arguments": .string(item.arguments ?? "{}")])
                // A call cut off by a stop still needs an answer.
                if !answered.contains(callID) {
                    input.append(["type": "function_call_output", "call_id": .string(callID),
                                  "output": "Stopped before this finished."])
                }
            case .output:
                guard let callID = item.callID else { continue }
                let text = item.output ?? ""
                input.append(["type": "function_call_output", "call_id": .string(callID),
                              "output": .string(index >= wholeFrom ? text : elided(text))])
            case .reasoning:
                if index >= runStart, let raw = item.raw { input.append(raw) }
            case .note:
                switch item.note {
                case .takenOver?:
                    input.append(["role": "developer", "content": .string("[\(item.from ?? "Another agent") took this thread over and worked on it without you.]")])
                case .finishedByAgent?:
                    input.append(["role": "developer", "content": .string("[\(item.from ?? "Another agent") finished it: \(item.text ?? "")]")])
                case .stopped?:
                    input.append(["role": "developer", "content": "[The user stopped you here.]"])
                default: continue
                }
            case .error:
                continue
            }
        }
        return input
    }

    static func elided(_ text: String) -> String {
        guard text.count > elisionLength else { return text }
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return String(first.prefix(200)) + "\n[Earlier terminal text left out to save space; read the terminal again if you need it.]"
    }

    /// When the context has grown past the threshold, everything before the
    /// run in progress is replaced by Orbit's own summary of it.
    private func compactIfNeeded(_ id: String, key: String) async {
        guard let record = records[id] else { return }
        let size = Self.input(for: record).reduce(0) { $0 + Self.size($1) } + (record.memory?.count ?? 0)
        let cut = record.runStart
        guard size > compactionThreshold, cut > record.memoryCount else { return }
        let transcript = Self.transcript(record.items[record.memoryCount..<cut])
        var prompt = ""
        if let memory = record.memory { prompt += "Your earlier summary:\n\(memory)\n\n" }
        prompt += "What happened since:\n\(transcript)"
        let body: JSONValue = [
            "model": .string(model),
            "instructions": """
            You are Orbit, an assistant that operates terminals. Write your own memory of this part of a thread, \
            to continue it later without the transcript: the user's goals and preferences, decisions, facts \
            learned about terminals, folders and programs, what is done, and what is pending. At most 300 words, \
            in the user's language. Never include secrets.
            """,
            "input": [["role": "user", "content": .string(prompt)]],
            "store": false,
            "prompt_cache_key": .string(record.id + "-memory"),
        ]
        guard let response = try? await api.create(body, key: key), !Task.isCancelled else { return }
        let reply = OpenAIResponses.parse(response)
        let summary = reply.parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        guard !summary.isEmpty else { return }
        update(id) { record in
            record.memory = summary
            record.memoryCount = cut
            record.usage.inputTokens += reply.inputTokens
            record.usage.cachedTokens += reply.cachedTokens
            record.usage.outputTokens += reply.outputTokens
            record.items.insert(OrbitItem(kind: .note, note: .summarized), at: cut)
            record.runStart = cut + 1
            record.memoryCount = cut + 1
        }
    }

    static func size(_ value: JSONValue) -> Int {
        switch value {
        case .string(let text): text.count
        case .array(let values): values.reduce(0) { $0 + size($1) }
        case .object(let object): object.reduce(0) { $0 + $1.key.count + size($1.value) }
        default: 8
        }
    }

    /// Older turns as text for the summary: words whole, actions short.
    static func transcript(_ items: ArraySlice<OrbitItem>) -> String {
        var lines: [String] = []
        for item in items {
            switch item.kind {
            case .user: lines.append("\(item.from ?? "User"): \(item.text ?? "")")
            case .assistant: lines.append("Orbit: \(item.text ?? "")")
            case .call: lines.append("Orbit called \(item.name ?? "?") \(item.arguments ?? "")")
            case .output: lines.append("→ " + String((item.output ?? "").prefix(300)))
            case .note: if let text = item.text { lines.append("[\(item.from ?? "Note")] \(text)") }
            case .reasoning, .error: continue
            }
        }
        let text = lines.joined(separator: "\n")
        return text.count <= 200_000 ? text : String(text.suffix(200_000))
    }
}
