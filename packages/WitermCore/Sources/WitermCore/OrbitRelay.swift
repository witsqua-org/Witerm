import Foundation

/// Orbit from a paired iPhone or iPad (relay-v1 `orbit`, Round 32). The Mac's
/// relay endpoint forwards a narrow part of Orbit v1 to Orbit's own socket;
/// both ends apply these rules. The API key never crosses the relay in either
/// direction, and nothing here can configure Orbit, act as an agent, or delete.
public enum OrbitRelay {
  /// What a device may ask Orbit.
  public static let operations: Set<OrbitOperation> = [.status, .threads, .thread, .start, .send, .stop]

  /// A plaintext relay record (relay-v1 Transport).
  public static let recordLimit = 49_152
  /// What a reply may use of a record, leaving room for the frame around it.
  public static let replyBudget = 46_000
  /// An action's excerpt as a device gets it at first.
  public static let detailLimit = 600

  /// The request a device may send, or nil: only the operations above, with
  /// only the fields each takes, and never `api_key`, `model`, `agent` or
  /// `success`.
  public static func admit(_ request: OrbitRequest) -> OrbitRequest? {
    guard request.version == 1, operations.contains(request.operation), validID(request.id),
      request.apiKey == nil, request.model == nil, request.agent == nil, request.success == nil
    else { return nil }
    let needsThread: Bool
    switch request.operation {
    case .status, .threads:
      guard request.threadID == nil, request.text == nil, request.kind == nil, request.terminalID == nil else { return nil }
      needsThread = false
    case .thread, .stop:
      guard request.text == nil, request.kind == nil, request.terminalID == nil else { return nil }
      needsThread = true
    case .start:
      guard request.threadID == nil, request.kind != nil, validText(request.text),
        request.terminalID.map(validID) ?? true
      else { return nil }
      needsThread = false
    case .send:
      guard request.kind == nil, request.terminalID == nil, validText(request.text) else { return nil }
      needsThread = true
    default:
      return nil
    }
    if needsThread {
      guard let thread = request.threadID, validID(thread) else { return nil }
    }
    return request
  }

  /// The reply a device gets: Orbit's own, cut to fit one relay record. A
  /// list keeps its newest `threadLimit`. A thread first shortens each
  /// action's excerpt, then leaves out its oldest entries, and
  /// `earlier_entries` counts what was left out.
  public static func fit(_ response: OrbitResponse, budget: Int = replyBudget) -> OrbitResponse {
    if let threads = response.threads, threads.count > threadLimit {
      return OrbitResponse(id: response.id, ok: response.ok, error: response.error, status: response.status,
                           threads: Array(threads.prefix(threadLimit)), thread: response.thread)
    }
    guard let thread = response.thread else { return response }
    func size(_ detail: OrbitThreadDetail) -> Int {
      (try? RelayOrbitCoding.encoder().encode(
        OrbitResponse(id: response.id, ok: response.ok, error: response.error, status: response.status,
                      threads: response.threads, thread: detail)).count) ?? .max
    }
    var detail = thread
    guard size(detail) > budget else { return response }
    detail = OrbitThreadDetail(summary: detail.summary, plan: detail.plan,
                               entries: detail.entries.map { shortened($0, to: detailLimit) },
                               earlierEntries: detail.earlierEntries, usage: detail.usage, memory: detail.memory)
    // Halving, then one by one, keeps the number of encodings small.
    var keep = detail.entries.count
    func trimmed(_ count: Int) -> OrbitThreadDetail {
      OrbitThreadDetail(summary: detail.summary, plan: detail.plan, entries: Array(detail.entries.suffix(count)),
                        earlierEntries: detail.earlierEntries + detail.entries.count - count,
                        usage: detail.usage, memory: detail.memory)
    }
    while keep > 1, size(trimmed(keep)) > budget, size(trimmed(keep / 2)) > budget { keep /= 2 }
    while keep > 0, size(trimmed(keep)) > budget { keep -= 1 }
    var fitted = trimmed(keep)
    // A memory or plan too long for the record: shorten what's left.
    if size(fitted) > budget {
      fitted = OrbitThreadDetail(summary: fitted.summary, plan: Array(fitted.plan.prefix(20)), entries: [],
                                 earlierEntries: fitted.earlierEntries, usage: fitted.usage,
                                 memory: fitted.memory.map { String($0.prefix(4_000)) })
    }
    return OrbitResponse(id: response.id, ok: response.ok, error: response.error, status: response.status,
                         threads: response.threads, thread: fitted)
  }

  /// A device gets at most this many summaries, newest first (Orbit keeps
  /// up to 200), so a list always fits one record.
  public static let threadLimit = 100

  static func shortened(_ entry: OrbitEntry, to limit: Int) -> OrbitEntry {
    func cut(_ text: String?) -> String? {
      guard let text, text.count > limit else { return text }
      return String(text.prefix(limit)) + "\n…"
    }
    return OrbitEntry(id: entry.id, at: entry.at, kind: entry.kind, text: entry.text,
                      tool: entry.tool, terminal: entry.terminal, command: entry.command, detail: cut(entry.detail),
                      failed: entry.failed, from: entry.from, note: entry.note, failure: entry.failure)
  }

  static func validID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }

  static func validText(_ text: String?) -> Bool {
    guard let text else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && text.utf8.count <= OrbitWire.textLimit
  }
}

/// Relay frames carry Orbit's objects with the relay's own JSON settings.
enum RelayOrbitCoding {
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
