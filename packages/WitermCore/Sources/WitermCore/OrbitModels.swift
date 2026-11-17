import Foundation

/// Orbit, Witerm's assistant: a conversation, or a task delegated to it, run
/// on this Mac by `witerm orbit serve` (protocol/orbit-v1.md). These are the
/// messages between that process and its local clients (the app and
/// `witerm mcp`). Terminal text in them never leaves this Mac except to the
/// model service the user configured.
public enum OrbitThreadKind: String, Codable, Sendable, CaseIterable {
  /// Back and forth: Orbit answers, using terminals when that helps.
  case chat
  /// Delegated: Orbit plans and works until it calls the task finished.
  case task
}

public enum OrbitThreadStatus: String, Codable, Sendable {
  /// A conversation waiting for the next message.
  case idle
  case running
  /// Orbit needs the user: a question, or it stopped short of finishing.
  case waiting
  case done
  case failed
  /// Stopped by the user.
  case stopped
  /// Another agent (Codex, Claude Code) took the task over through MCP.
  case takenOver = "taken_over"
}

public enum OrbitPlanStepStatus: String, Codable, Sendable { case pending, active, done }

public struct OrbitPlanStep: Codable, Sendable, Equatable {
  public let text: String
  public let status: OrbitPlanStepStatus

  public init(text: String, status: OrbitPlanStepStatus) {
    self.text = text
    self.status = status
  }
}

public enum OrbitEntryKind: String, Codable, Sendable {
  /// From the user, or guidance from another agent (`from`).
  case user
  /// Orbit's own words.
  case assistant
  /// A tool Orbit used: `tool`, `terminal`, `command`, and an excerpt of
  /// what came back in `detail`.
  case action
  /// Something that happened to the thread (`note`).
  case note
  case error
}

/// Thread events, named rather than worded, so the app says them in the
/// user's language.
public enum OrbitNote: String, Codable, Sendable {
  case stopped
  case takenOver = "taken_over"
  case finishedByAgent = "finished_by_agent"
  case stepLimit = "step_limit"
  case summarized
}

public enum OrbitFailure: String, Codable, Sendable {
  /// No OpenAI API key has been given to Orbit.
  case missingKey = "missing_key"
  /// The key was refused (401/403).
  case keyRejected = "key_rejected"
  /// Rate or quota limits (429).
  case limited
  /// Another error from the API; `detail` has its message.
  case api
  /// The API couldn't be reached.
  case network
  /// The background service for terminals isn't running.
  case terminalsUnavailable = "terminals_unavailable"
}

/// One line of a thread as people see it. The model's full context (tool
/// output, reasoning) stays in the thread's file and isn't sent to clients.
public struct OrbitEntry: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let at: Date
  public let kind: OrbitEntryKind
  /// The words, for `user` and `assistant`; a model message for `error`.
  public let text: String?
  /// `action`: the tool's name, such as `run_command`.
  public let tool: String?
  /// `action`: the terminal's name, when the tool used one.
  public let terminal: String?
  /// `action`: the command run, or the text typed.
  public let command: String?
  /// `action`: what came back, shortened.
  public let detail: String?
  /// `action`: the tool reported a failure.
  public let failed: Bool?
  /// `user`: the agent the message came from, when not the user.
  public let from: String?
  public let note: OrbitNote?
  public let failure: OrbitFailure?

  public init(
    id: String, at: Date, kind: OrbitEntryKind, text: String? = nil, tool: String? = nil,
    terminal: String? = nil, command: String? = nil, detail: String? = nil, failed: Bool? = nil,
    from: String? = nil, note: OrbitNote? = nil, failure: OrbitFailure? = nil
  ) {
    self.id = id
    self.at = at
    self.kind = kind
    self.text = text
    self.tool = tool
    self.terminal = terminal
    self.command = command
    self.detail = detail
    self.failed = failed
    self.from = from
    self.note = note
    self.failure = failure
  }
}

public struct OrbitUsage: Codable, Sendable, Equatable {
  public var inputTokens: Int
  public var cachedTokens: Int
  public var outputTokens: Int

  public init(inputTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0) {
    self.inputTokens = inputTokens
    self.cachedTokens = cachedTokens
    self.outputTokens = outputTokens
  }

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case cachedTokens = "cached_tokens"
    case outputTokens = "output_tokens"
  }
}

public struct OrbitThreadSummary: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let kind: OrbitThreadKind
  public let status: OrbitThreadStatus
  /// The terminal the thread was started from, if any.
  public let terminalID: String?
  public let updatedAt: Date
  /// Grows with every change, so a client refetches only what changed.
  public let revision: Int
  /// The agent that took the task over.
  public let takenOverBy: String?

  public init(
    id: String, title: String, kind: OrbitThreadKind, status: OrbitThreadStatus, terminalID: String?,
    updatedAt: Date, revision: Int, takenOverBy: String?
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.status = status
    self.terminalID = terminalID
    self.updatedAt = updatedAt
    self.revision = revision
    self.takenOverBy = takenOverBy
  }

  enum CodingKeys: String, CodingKey {
    case id, title, kind, status, revision
    case terminalID = "terminal_id"
    case updatedAt = "updated_at"
    case takenOverBy = "taken_over_by"
  }
}

public struct OrbitThreadDetail: Codable, Sendable, Equatable {
  public let summary: OrbitThreadSummary
  /// Tasks: Orbit's plan, as it last set it.
  public let plan: [OrbitPlanStep]
  /// The latest entries, oldest first (at most `entryLimit`).
  public let entries: [OrbitEntry]
  /// Entries left out before the first one here.
  public let earlierEntries: Int
  public let usage: OrbitUsage
  /// The model's own summary of turns it no longer keeps verbatim.
  public let memory: String?

  public static let entryLimit = 300

  public init(
    summary: OrbitThreadSummary, plan: [OrbitPlanStep], entries: [OrbitEntry], earlierEntries: Int,
    usage: OrbitUsage, memory: String?
  ) {
    self.summary = summary
    self.plan = plan
    self.entries = entries
    self.earlierEntries = earlierEntries
    self.usage = usage
    self.memory = memory
  }

  enum CodingKeys: String, CodingKey {
    case summary, plan, entries, usage, memory
    case earlierEntries = "earlier_entries"
  }
}

public struct OrbitStatus: Codable, Sendable, Equatable {
  public let version: Int
  /// Whether Orbit holds an API key now (only in its memory).
  public let hasKey: Bool
  public let model: String
  /// Threads running now.
  public let running: Int

  public init(version: Int = 1, hasKey: Bool, model: String, running: Int) {
    self.version = version
    self.hasKey = hasKey
    self.model = model
    self.running = running
  }

  enum CodingKeys: String, CodingKey {
    case version, model, running
    case hasKey = "has_key"
  }
}

public enum OrbitOperation: String, Codable, Sendable {
  case status
  /// Gives Orbit the API key (kept in its memory only) and the model.
  case configure
  case threads
  case thread
  /// Starts a thread with its first message.
  case start
  /// Another message: from the user, or guidance from an agent (`agent`).
  case send
  case stop
  /// An agent takes a thread over: Orbit stops working on it.
  case takeOver = "take_over"
  /// An agent that took a thread over reports it finished.
  case finish
  case delete
  /// Deletes every thread.
  case clear
}

public enum OrbitErrorCode: String, Codable, Sendable {
  case invalidRequest = "invalid_request"
  case unsupportedVersion = "unsupported_version"
  case notFound = "not_found"
  /// The thread is running (for `delete`), or another agent has it.
  case busy
  case unavailable
}

public struct OrbitRequest: Codable, Sendable, Equatable {
  public let version: Int
  public let id: String
  public let operation: OrbitOperation
  public let threadID: String?
  public let text: String?
  public let kind: OrbitThreadKind?
  public let terminalID: String?
  /// `configure` only. Never written anywhere by Orbit.
  public let apiKey: String?
  public let model: String?
  /// `send`, `take_over`, `finish`: the agent acting ("Codex").
  public let agent: String?
  /// `finish`: whether the task succeeded.
  public let success: Bool?

  public init(
    version: Int = 1, id: String = UUID().uuidString.lowercased(), operation: OrbitOperation,
    threadID: String? = nil, text: String? = nil, kind: OrbitThreadKind? = nil, terminalID: String? = nil,
    apiKey: String? = nil, model: String? = nil, agent: String? = nil, success: Bool? = nil
  ) {
    self.version = version
    self.id = id
    self.operation = operation
    self.threadID = threadID
    self.text = text
    self.kind = kind
    self.terminalID = terminalID
    self.apiKey = apiKey
    self.model = model
    self.agent = agent
    self.success = success
  }

  enum CodingKeys: String, CodingKey {
    case version, id, operation, text, kind, model, agent, success
    case threadID = "thread_id"
    case terminalID = "terminal_id"
    case apiKey = "api_key"
  }
}

public struct OrbitResponse: Codable, Sendable, Equatable {
  public let version: Int
  public let id: String?
  public let ok: Bool
  public let error: OrbitErrorCode?
  public let status: OrbitStatus?
  public let threads: [OrbitThreadSummary]?
  public let thread: OrbitThreadDetail?

  public init(
    version: Int = 1, id: String?, ok: Bool, error: OrbitErrorCode? = nil, status: OrbitStatus? = nil,
    threads: [OrbitThreadSummary]? = nil, thread: OrbitThreadDetail? = nil
  ) {
    self.version = version
    self.id = id
    self.ok = ok
    self.error = error
    self.status = status
    self.threads = threads
    self.thread = thread
  }
}

public enum OrbitWire {
  /// Requests and replies are one JSON line each.
  public static let lineLimit = 4 << 20
  /// Messages people and agents send.
  public static let textLimit = 32 * 1024
  public static let defaultModel = "gpt-6.1-sol"

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// A model name: letters, digits and `.-_:`, at most 64.
  public static func validModel(_ model: String) -> Bool {
    (1...64).contains(model.utf8.count)
      && model.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".-_:".unicodeScalars.contains($0)
      }
  }

  /// An agent's display name: 1–64 characters, no controls.
  public static func validAgent(_ name: String) -> Bool {
    !name.isEmpty && name.unicodeScalars.count <= 64
      && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
      && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}
