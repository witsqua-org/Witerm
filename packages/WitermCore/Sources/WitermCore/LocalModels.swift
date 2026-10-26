import Foundation

public enum LocalAgentOperation: String, Codable, Sendable {
  case status, list, create, close, attach, input, resize, detach
}

public enum LocalAttachmentMode: String, Codable, Sendable { case control, view }
public enum LocalFrameKind: String, Codable, Sendable { case response, output, geometry, closed }

public enum LocalTerminalEvent: Sendable, Equatable {
  case output(Data)
  case geometry(LocalSessionInfo)
}
public enum LocalAgentErrorCode: String, Codable, Sendable {
  case invalidRequest = "invalid_request"
  case unsupportedVersion = "unsupported_version"
  case notFound = "not_found"
  case sessionBusy = "session_busy"
  case readOnly = "read_only"
  case dependencyMissing = "dependency_missing"
  case unavailable
  case backpressure
}

public struct LocalSessionInfo: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let createdAt: Date
  public let columns: Int
  public let rows: Int

  public init(id: String, name: String, createdAt: Date, columns: Int, rows: Int) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.columns = columns
    self.rows = rows
  }

  enum CodingKeys: String, CodingKey {
    case id, name, columns, rows
    case createdAt = "created_at"
  }
}

public struct LocalAgentStatus: Codable, Sendable, Equatable {
  public let version: Int
  public let tmuxAvailable: Bool

  public init(version: Int = 1, tmuxAvailable: Bool) {
    self.version = version
    self.tmuxAvailable = tmuxAvailable
  }

  enum CodingKeys: String, CodingKey {
    case version
    case tmuxAvailable = "tmux_available"
  }
}

public struct LocalAgentRequest: Codable, Sendable, Equatable {
  public let version: Int
  public let id: String
  public let operation: LocalAgentOperation
  public let sessionID: String?
  public let name: String?
  public let columns: Int?
  public let rows: Int?
  public let mode: LocalAttachmentMode?
  public let data: Data?

  public init(
    version: Int = 1, id: String = UUID().uuidString.lowercased(), operation: LocalAgentOperation,
    sessionID: String? = nil, name: String? = nil, columns: Int? = nil, rows: Int? = nil,
    mode: LocalAttachmentMode? = nil, data: Data? = nil
  ) {
    self.version = version
    self.id = id
    self.operation = operation
    self.sessionID = sessionID
    self.name = name
    self.columns = columns
    self.rows = rows
    self.mode = mode
    self.data = data
  }

  enum CodingKeys: String, CodingKey {
    case version, id, operation, name, columns, rows, mode, data
    case sessionID = "session_id"
  }
}

public struct LocalAgentFrame: Codable, Sendable, Equatable {
  public let version: Int
  public let id: String?
  public let kind: LocalFrameKind
  public let ok: Bool?
  public let error: LocalAgentErrorCode?
  public let status: LocalAgentStatus?
  public let sessions: [LocalSessionInfo]?
  public let session: LocalSessionInfo?
  public let mode: LocalAttachmentMode?
  public let data: Data?

  public init(
    version: Int = 1, id: String? = nil, kind: LocalFrameKind, ok: Bool? = nil,
    error: LocalAgentErrorCode? = nil, status: LocalAgentStatus? = nil,
    sessions: [LocalSessionInfo]? = nil, session: LocalSessionInfo? = nil,
    mode: LocalAttachmentMode? = nil, data: Data? = nil
  ) {
    self.version = version
    self.id = id
    self.kind = kind
    self.ok = ok
    self.error = error
    self.status = status
    self.sessions = sessions
    self.session = session
    self.mode = mode
    self.data = data
  }
}

public enum LocalAgentClientError: Error, Equatable, Sendable {
  case unavailable, invalidResponse, unsafeSocket, backpressure
  case rejected(LocalAgentErrorCode)
}

// One lazily selected consumer route. Before selection, retain at most 64
// ordered events. Legacy output ignores geometry without creating a second
// queue or a projection task. Each selected stream supports one iterator.
final class LocalTerminalStreams: @unchecked Sendable {
  enum YieldResult { case enqueued, dropped, terminated }
  private enum Route { case undecided, events, output }
  private let lock = NSRecursiveLock()
  private let conflictError: Error
  private var route: Route = .undecided
  private var buffered: [LocalTerminalEvent] = []
  private var completed = false
  private var terminalError: Error?
  private var eventsStream: AsyncThrowingStream<LocalTerminalEvent, Error>?
  private var outputStream: AsyncThrowingStream<Data, Error>?
  private var eventsContinuation: AsyncThrowingStream<LocalTerminalEvent, Error>.Continuation?
  private var outputContinuation: AsyncThrowingStream<Data, Error>.Continuation?
  private var termination: (@Sendable () -> Void)?

  init(conflictError: Error) { self.conflictError = conflictError }

  func onTermination(_ callback: @escaping @Sendable () -> Void) {
    lock.withLock { termination = callback }
  }

  func events() -> AsyncThrowingStream<LocalTerminalEvent, Error> {
    lock.lock()
    if route == .output {
      lock.unlock()
      return AsyncThrowingStream { $0.finish(throwing: conflictError) }
    }
    if let eventsStream {
      lock.unlock()
      return eventsStream
    }
    route = .events
    let (stream, continuation) = AsyncThrowingStream<LocalTerminalEvent, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(64))
    eventsStream = stream
    eventsContinuation = continuation
    continuation.onTermination = { [weak self] _ in self?.consumerEnded() }
    for event in buffered { continuation.yield(event) }
    buffered.removeAll()
    let finished = completed
    let error = terminalError
    lock.unlock()
    if finished { continuation.finish(throwing: error) }
    return stream
  }

  func output() -> AsyncThrowingStream<Data, Error> {
    lock.lock()
    if route == .events {
      lock.unlock()
      return AsyncThrowingStream { $0.finish(throwing: conflictError) }
    }
    if let outputStream {
      lock.unlock()
      return outputStream
    }
    route = .output
    let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(64))
    outputStream = stream
    outputContinuation = continuation
    continuation.onTermination = { [weak self] _ in self?.consumerEnded() }
    for case .output(let data) in buffered { continuation.yield(data) }
    buffered.removeAll()
    let finished = completed
    let error = terminalError
    lock.unlock()
    if finished { continuation.finish(throwing: error) }
    return stream
  }

  func yield(_ event: LocalTerminalEvent) -> YieldResult {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return .terminated }
    switch route {
    case .undecided:
      guard buffered.count < 64 else { return .dropped }
      buffered.append(event)
      return .enqueued
    case .events:
      switch eventsContinuation!.yield(event) {
      case .enqueued: return .enqueued
      case .dropped: return .dropped
      case .terminated: return .terminated
      @unknown default: return .dropped
      }
    case .output:
      guard case .output(let data) = event else { return .enqueued }
      switch outputContinuation!.yield(data) {
      case .enqueued: return .enqueued
      case .dropped: return .dropped
      case .terminated: return .terminated
      @unknown default: return .dropped
      }
    }
  }

  func finish(throwing error: Error?) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    terminalError = error
    let events = eventsContinuation
    let output = outputContinuation
    lock.unlock()
    events?.finish(throwing: error)
    output?.finish(throwing: error)
  }

  private func consumerEnded() {
    let callback = lock.withLock { termination }
    callback?()
  }
}
