import Foundation
import WitermCore

/// MCP tools that let an external agent (Codex, Claude Code) see Orbit's
/// tasks, guide one, take one over, and report one finished. Orbit itself
/// runs in `witerm orbit serve`; these talk to it, and start it when it
/// isn't running.
struct OrbitHandoffTools: Sendable {
    let client: OrbitClient
    let readOnly: Bool
    /// Starts Orbit and reports whether it answers; nil never starts it.
    var start: (@Sendable () async -> Bool)? = nil
    /// How long guidance waits for Witerm to give a just-started Orbit its key.
    var keyWait: Duration = .seconds(2)

    static let reading: Set<String> = ["list_orbit_tasks", "read_orbit_task"]
    static let writing: Set<String> = ["guide_orbit_task", "take_over_orbit_task", "finish_orbit_task"]

    func offers(_ name: String) -> Bool {
        Self.reading.contains(name) || (!readOnly && Self.writing.contains(name))
    }

    var definitions: [ToolDefinition] {
        let task: JSONValue = ["type": "string", "description": "The task's ID, or a unique ID prefix of at least 4 characters."]
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: JSONValue],
                  required: [String], readOnly: Bool, destructive: Bool = false) -> ToolDefinition {
            ToolDefinition(name: name, title: title, description: description,
                           schema: ["type": "object", "properties": .object(properties),
                                    "required": .array(required.map(JSONValue.string)), "additionalProperties": false],
                           readOnly: readOnly, destructive: destructive)
        }
        var tools = [
            tool("list_orbit_tasks", "List Orbit tasks",
                 "Lists the conversations and delegated tasks of Orbit, Witerm's built-in assistant, newest first, with their status.",
                 [:], required: [], readOnly: true),
            tool("read_orbit_task", "Read an Orbit task",
                 "Shows one Orbit task: its plan, Orbit's memory of earlier turns, and its latest messages and actions.",
                 ["task": task], required: ["task"], readOnly: true),
        ]
        guard !readOnly else { return tools }
        tools += [
            tool("guide_orbit_task", "Guide an Orbit task",
                 "Sends Orbit a message about a task, signed with your name. Orbit reads it and continues working (also after a take-over).",
                 ["task": task, "message": ["type": "string", "description": "What Orbit should know or do."]],
                 required: ["task", "message"], readOnly: false),
            tool("take_over_orbit_task", "Take over an Orbit task",
                 "Stops Orbit working on a task so you can continue it yourself with the terminal tools. Call finish_orbit_task when you're done, or guide_orbit_task to hand it back.",
                 ["task": task], required: ["task"], readOnly: false, destructive: true),
            tool("finish_orbit_task", "Finish an Orbit task",
                 "Marks a task you took over as done or failed, with a summary the user sees in Witerm.",
                 ["task": task, "summary": ["type": "string", "description": "What was done, for the user."],
                  "success": ["type": "boolean", "description": "Whether the task succeeded (default true)."]],
                 required: ["task", "summary"], readOnly: false),
        ]
        return tools
    }

    func run(_ name: String, arguments: JSONValue, agent: String) async -> ToolResult {
        let first = await attempt(name, arguments: arguments, agent: agent)
        guard first.unavailable, let start, await start() else { return first.result }
        return await attempt(name, arguments: arguments, agent: agent).result
    }

    /// Orbit started by an agent has no key until Witerm gives it one, which
    /// Witerm does as soon as Orbit starts while Witerm is open.
    private func requireKey() async throws {
        let deadline = ContinuousClock.now + keyWait
        while try await !client.status().hasKey {
            guard ContinuousClock.now < deadline else {
                throw ToolFailure("Orbit has no OpenAI API key right now, so it can't continue the task. Witerm gives Orbit its key while Witerm is open: ask the user to open Witerm, then try again. You can still take the task over.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func attempt(_ name: String, arguments: JSONValue, agent: String) async -> (result: ToolResult, unavailable: Bool) {
        do {
            return (try await perform(name, arguments: arguments, agent: agent), false)
        } catch let failure as ToolFailure {
            return (ToolResult(text: failure.message, isError: true), false)
        } catch OrbitClientError.unavailable {
            return (ToolResult(text: "Orbit isn't running, and it couldn't be started. Ask the user to open Orbit in Witerm.", isError: true), true)
        } catch OrbitClientError.rejected(.notFound) {
            return (ToolResult(text: "No such Orbit task. Call list_orbit_tasks.", isError: true), false)
        } catch OrbitClientError.rejected(.busy) {
            return (ToolResult(text: "Another agent has taken that task over.", isError: true), false)
        } catch {
            return (ToolResult(text: "Orbit didn't answer as expected. Try again.", isError: true), false)
        }
    }

    private func perform(_ name: String, arguments: JSONValue, agent: String) async throws -> ToolResult {
        switch name {
        case "list_orbit_tasks":
            let threads = try await client.threads()
            guard !threads.isEmpty else { return ToolResult(text: "Orbit has no conversations or tasks.", isError: false) }
            return ToolResult(text: threads.map(Self.line).joined(separator: "\n"), isError: false)
        case "read_orbit_task":
            return ToolResult(text: Self.describe(try await client.thread(try await resolve(arguments))), isError: false)
        case "guide_orbit_task":
            guard let message = arguments["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty, message.utf8.count <= OrbitWire.textLimit else {
                throw ToolFailure("Give a message of at most 32 KiB.")
            }
            let id = try await resolve(arguments)
            try await requireKey()
            let thread = try await client.send(message, to: id, agent: agent)
            return ToolResult(text: "Sent. Orbit is \(thread.summary.status.rawValue) on “\(thread.summary.title)”.", isError: false)
        case "take_over_orbit_task":
            let thread = try await client.takeOver(try await resolve(arguments), agent: agent)
            return ToolResult(text: "You have “\(thread.summary.title)” now; Orbit stopped working on it.\n" + Self.describe(thread),
                              isError: false)
        default:
            guard let summary = arguments["summary"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty, summary.utf8.count <= OrbitWire.textLimit else {
                throw ToolFailure("Give a summary of at most 32 KiB.")
            }
            let thread = try await client.finish(try await resolve(arguments), agent: agent, summary: summary,
                                                 success: arguments["success"]?.bool ?? true)
            return ToolResult(text: "Marked “\(thread.summary.title)” \(thread.summary.status.rawValue).", isError: false)
        }
    }

    private func resolve(_ arguments: JSONValue) async throws -> String {
        guard let reference = arguments["task"]?.string?.lowercased(), reference.count >= 4 else {
            throw ToolFailure("Name the task by its ID or a unique prefix of at least 4 characters. Call list_orbit_tasks.")
        }
        let matches = try await client.threads().filter { $0.id.hasPrefix(reference) }
        guard matches.count == 1 else {
            throw ToolFailure(matches.isEmpty ? "No Orbit task matches “\(reference)”. Call list_orbit_tasks."
                                              : "“\(reference)” matches several tasks. Use more of the ID.")
        }
        return matches[0].id
    }

    static func line(_ thread: OrbitThreadSummary) -> String {
        var line = "\(thread.id) [\(thread.kind.rawValue), \(thread.status.rawValue)] “\(thread.title)”"
        if let agent = thread.takenOverBy { line += " (taken over by \(agent))" }
        return line
    }

    static func describe(_ thread: OrbitThreadDetail) -> String {
        var lines = [line(thread.summary)]
        if !thread.plan.isEmpty {
            lines.append("Plan:")
            lines += thread.plan.map { "  [\($0.status == .done ? "x" : $0.status == .active ? ">" : " ")] \($0.text)" }
        }
        if let memory = thread.memory { lines.append("Earlier (Orbit's summary): " + memory) }
        let entries = thread.entries.suffix(40)
        if thread.entries.count + thread.earlierEntries > entries.count {
            lines.append("[\(thread.entries.count + thread.earlierEntries - entries.count) earlier entries left out]")
        }
        for entry in entries {
            switch entry.kind {
            case .user: lines.append("\(entry.from ?? "User"): \(entry.text ?? "")")
            case .assistant: lines.append("Orbit: \(entry.text ?? "")")
            case .action:
                var action = "Orbit used \(entry.tool ?? "a tool")"
                if let terminal = entry.terminal { action += " in “\(terminal)”" }
                if let command = entry.command { action += ": \(command)" }
                if entry.failed == true { action += " (failed)" }
                lines.append(action)
            case .note: lines.append("[\(entry.note?.rawValue ?? "note")\(entry.from.map { " by \($0)" } ?? "")]")
            case .error: lines.append("[error: \(entry.failure?.rawValue ?? "unknown")\(entry.text.map { " \($0)" } ?? "")]")
            }
        }
        return lines.joined(separator: "\n")
    }
}
