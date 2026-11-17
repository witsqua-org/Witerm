import Darwin
import Foundation
import WitermCore

/// One step of a thread's full record: what people said, what Orbit said
/// and did, and what the model needs to continue (tool output, reasoning).
/// Kept only in the thread's file on this Mac.
struct OrbitItem: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case user, assistant, call, output, reasoning, note, error }

    var id = UUID().uuidString.lowercased()
    var at = Date()
    var kind: Kind
    /// `user`, `assistant`, `error` (an API message), and `note` (a summary).
    var text: String?
    /// `user`: sent to the model before the text, never shown.
    var context: String?
    /// `user` and `note`: the agent it came from, when not the user.
    var from: String?
    /// `call`: the tool, its call ID and JSON arguments, and the terminal's
    /// name when the call named one. `output`: the call it answers.
    var name: String?
    var callID: String?
    var arguments: String?
    var terminal: String?
    /// `output`: everything the tool returned.
    var output: String?
    var failed: Bool?
    /// `reasoning`: the item exactly as the API returned it.
    var raw: JSONValue?
    var note: OrbitNote?
    var failure: OrbitFailure?

    enum CodingKeys: String, CodingKey {
        case id, at, kind, text, context, from, name, arguments, terminal, output, failed, raw, note, failure
        case callID = "call_id"
    }
}

/// A thread as stored: its record, plan, memory and usage.
struct OrbitRecord: Codable, Sendable {
    var id = UUID().uuidString.lowercased()
    var title: String
    var kind: OrbitThreadKind
    var status: OrbitThreadStatus = .idle
    var terminalID: String?
    var createdAt = Date()
    var updatedAt = Date()
    var revision = 0
    var plan: [OrbitPlanStep] = []
    var items: [OrbitItem] = []
    /// The model's summary of `items[..<memoryCount]`, sent in their place.
    var memory: String?
    var memoryCount = 0
    var usage = OrbitUsage()
    var takenOverBy: String?
    /// Terminals Orbit made for this thread; only these may it end.
    var created: [String] = []
    /// Where the latest run started in `items`.
    var runStart = 0

    var summary: OrbitThreadSummary {
        OrbitThreadSummary(id: id, title: title, kind: kind, status: status, terminalID: terminalID,
                           updatedAt: updatedAt, revision: revision, takenOverBy: takenOverBy)
    }

    /// The record as people see it: words, actions with short output, notes.
    var detail: OrbitThreadDetail {
        let outputs = Dictionary(items.filter { $0.kind == .output }.compactMap { item in item.callID.map { ($0, item) } },
                                 uniquingKeysWith: { $1 })
        var entries: [OrbitEntry] = []
        for item in items {
            switch item.kind {
            case .user:
                entries.append(OrbitEntry(id: item.id, at: item.at, kind: .user, text: item.text, from: item.from))
            case .assistant:
                entries.append(OrbitEntry(id: item.id, at: item.at, kind: .assistant, text: item.text))
            case .call:
                guard let name = item.name, name != "update_plan", name != "finish_task" else { continue }
                let output = item.callID.flatMap { outputs[$0] }
                entries.append(OrbitEntry(id: item.id, at: item.at, kind: .action, tool: name, terminal: item.terminal,
                                          command: Self.command(of: item), detail: output?.output.map(Self.excerpt),
                                          failed: output?.failed))
            case .note:
                entries.append(OrbitEntry(id: item.id, at: item.at, kind: .note, text: item.text, from: item.from, note: item.note))
            case .error:
                entries.append(OrbitEntry(id: item.id, at: item.at, kind: .error, text: item.text, failure: item.failure))
            case .output, .reasoning:
                continue
            }
        }
        let shown = entries.suffix(OrbitThreadDetail.entryLimit)
        return OrbitThreadDetail(summary: summary, plan: plan, entries: Array(shown),
                                 earlierEntries: entries.count - shown.count, usage: usage, memory: memory)
    }

    /// What a call ran or typed, for people.
    static func command(of call: OrbitItem) -> String? {
        guard let raw = call.arguments, let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { return nil }
        switch call.name {
        case "run_command": return arguments["command"]?.string
        case "send_input":
            let keys = (arguments["keys"]?.array ?? []).compactMap(\.string)
            let parts = [arguments["text"]?.string].compactMap { $0 } + (keys.isEmpty ? [] : [keys.joined(separator: " ")])
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case "create_terminal": return arguments["name"]?.string
        case "wait_for_terminal": return arguments["text"]?.string
        default: return nil
        }
    }

    static func excerpt(_ text: String) -> String {
        text.count <= 2000 ? text : String(text.prefix(2000)) + "\n…"
    }
}

/// Threads as files in Orbit's private folder: one JSON file each, mode
/// 0600, replaced atomically. Threads untouched for 30 days are removed.
struct OrbitStore: Sendable {
    let directory: URL
    static let retention: TimeInterval = 30 * 24 * 3600
    static let maximumThreads = 200

    var threadsDirectory: URL { directory.appendingPathComponent("threads", isDirectory: true) }

    func prepare() throws {
        try OrbitDaemon.privateDirectory(threadsDirectory)
    }

    func load(now: Date = Date()) -> [OrbitRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: nil)) ?? []
        var records: [OrbitRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var record = try? OrbitWire.decoder().decode(OrbitRecord.self, from: data),
                  file.deletingPathExtension().lastPathComponent == record.id else { continue }
            if now.timeIntervalSince(record.updatedAt) > Self.retention { delete(record.id); continue }
            // A run doesn't survive the process; say where it stopped.
            if record.status == .running { record.status = record.kind == .task ? .stopped : .idle }
            records.append(record)
        }
        records.sort { $0.updatedAt > $1.updatedAt }
        for old in records.dropFirst(Self.maximumThreads) { delete(old.id) }
        return Array(records.prefix(Self.maximumThreads))
    }

    func save(_ record: OrbitRecord) throws {
        let data = try OrbitWire.encoder().encode(record)
        let file = threadsDirectory.appendingPathComponent(record.id + ".json")
        let temporary = threadsDirectory.appendingPathComponent(".\(record.id).\(UUID().uuidString.prefix(8)).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: threadsDirectory.appendingPathComponent(id + ".json"))
    }
}
