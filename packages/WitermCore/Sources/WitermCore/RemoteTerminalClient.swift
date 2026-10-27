import Foundation

public actor RemoteTerminalClient {
  private let pairing: PairingClient
  private let grantID: String
  public init(pairing: PairingClient, grantID: String) {
    self.pairing = pairing
    self.grantID = grantID
  }

  public func sessions() async throws -> [LocalSessionInfo] {
    let channel = try await RelaySecureChannel.client(pairing: pairing, grantID: grantID)
    let rpc = RemoteRPCConnection(channel: channel)
    await rpc.start()
    do {
      let frame = try await rpc.request(LocalAgentRequest(operation: .list))
      await rpc.close()
      guard let sessions = frame.sessions else { throw RelayError.invalidMessage }
      return sessions
    } catch {
      await rpc.close()
      throw RelayContext.map(error)
    }
  }

  public func attach(
    sessionID: String, columns: Int = 80, rows: Int = 24,
    mode: LocalAttachmentMode = .control
  ) async throws -> RemoteTerminalAttachment {
    guard RemoteWire.validID(sessionID), RemoteWire.validSize(columns, rows) else {
      throw RelayError.invalidMessage
    }
    let grant = try await pairing.trustedRelayGrant(id: grantID)
    guard grant.permission == .control || mode == .view else { throw RelayError.readOnly }
    let channel = try await RelaySecureChannel.client(pairing: pairing, grantID: grantID)
    let rpc = RemoteRPCConnection(channel: channel)
    await rpc.start()
    do {
      let frame = try await rpc.request(
        LocalAgentRequest(
          operation: .attach,
          sessionID: sessionID, columns: columns, rows: rows, mode: mode))
      guard let session = frame.session else { throw RelayError.invalidMessage }
      return RemoteTerminalAttachment(connection: rpc, session: session, mode: mode)
    } catch {
      await rpc.close()
      throw RelayContext.map(error)
    }
  }
}

public final class RemoteTerminalAttachment: Sendable {
  /// Select either events or legacy output and consume it with one iterator.
  public var events: AsyncThrowingStream<LocalTerminalEvent, Error> { connection.events }
  public var output: AsyncThrowingStream<Data, Error> { connection.output }
  /// Snapshot from the attach ACK. Later dimensions arrive through events.
  public let session: LocalSessionInfo
  private let connection: RemoteRPCConnection
  private let mode: LocalAttachmentMode

  init(connection: RemoteRPCConnection, session: LocalSessionInfo, mode: LocalAttachmentMode) {
    self.connection = connection
    self.session = session
    self.mode = mode
  }
  deinit {
    let connection = connection
    Task { await connection.close() }
  }

  public func send(_ data: Data) async throws {
    guard mode == .control else { throw RelayError.readOnly }
    guard data.count <= 16_384 else { throw RelayError.invalidMessage }
    _ = try await connection.request(LocalAgentRequest(operation: .input, data: data))
  }
  public func resize(columns: Int, rows: Int) async throws {
    guard mode == .control else { throw RelayError.readOnly }
    guard RemoteWire.validSize(columns, rows) else { throw RelayError.invalidMessage }
    _ = try await connection.request(
      LocalAgentRequest(operation: .resize, columns: columns, rows: rows))
  }
  public func disconnect() async {
    try? await detach()
  }

  public func detach() async throws { try await connection.detach() }
  public func abort() async { await connection.abort() }
}

enum RemoteWire {
  static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }
  static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }
  static func validID(_ id: String) -> Bool { PairingEncoding.canonicalID(id) == id }
  static func validSize(_ columns: Int, _ rows: Int) -> Bool {
    (20...500).contains(columns) && (5...200).contains(rows)
  }
  static func validate(_ session: LocalSessionInfo) throws {
    guard validID(session.id), validSize(session.columns, session.rows),
      !session.name.isEmpty, session.name.unicodeScalars.count <= 64,
      session.name == session.name.trimmingCharacters(in: .whitespacesAndNewlines),
      session.name.rangeOfCharacter(from: .controlCharacters) == nil,
      session.createdAt.timeIntervalSince1970.isFinite
    else { throw RelayError.invalidMessage }
  }
  static func error(_ code: LocalAgentErrorCode?) -> RelayError {
    switch code {
    case .readOnly: return .readOnly
    case .sessionBusy: return .sessionBusy
    case .notFound: return .sessionUnavailable
    case .backpressure: return .backpressure
    case .invalidRequest, .unsupportedVersion: return .invalidMessage
    default: return .unavailable
    }
  }
}

actor RemoteRPCConnection {
  private nonisolated let terminal = LocalTerminalStreams(conflictError: RelayError.invalidMessage)
  nonisolated var output: AsyncThrowingStream<Data, Error> { terminal.output() }
  nonisolated var events: AsyncThrowingStream<LocalTerminalEvent, Error> { terminal.events() }
  private let channel: RelaySecureChannel
  private var reader: Task<Void, Never>?
  private var closed = false
  private var terminalError: RelayError?
  private var attached = false
  private var attachedSession: LocalSessionInfo?
  private var detaching = false
  private var detachTask: Task<Void, Error>?
  private var senders: [String: Task<Void, Never>] = [:]
  private var drainWaiters: [CheckedContinuation<Void, Error>] = []
  private struct Pending {
    let request: LocalAgentRequest
    let continuation: CheckedContinuation<LocalAgentFrame, Error>
    let timer: Task<Void, Never>
  }
  private var pending: [String: Pending] = [:]

  init(channel: RelaySecureChannel) {
    self.channel = channel
  }
  func start() {
    guard reader == nil else { return }
    terminal.onTermination { [weak self] in Task { await self?.consumerEnded() } }
    reader = Task { await self.readLoop() }
  }

  func request(_ request: LocalAgentRequest) async throws -> LocalAgentFrame {
    RelayTrace.event(channel.traceID, "rpc-request-" + request.operation.rawValue)
    guard !closed else { throw terminalError ?? RelayError.transport }
    guard !detaching || request.operation == .detach else { throw RelayError.transport }
    guard [.status, .list, .attach, .input, .resize, .detach].contains(request.operation),
      RemoteWire.validID(request.id), pending[request.id] == nil
    else { throw RelayError.invalidMessage }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        guard pending.count < 32 else {
          continuation.resume(throwing: RelayError.backpressure)
          return
        }
        let timer = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          await self?.timeout(id: request.id)
        }
        pending[request.id] = Pending(request: request, continuation: continuation, timer: timer)
        senders[request.id] = Task {
          do { try await channel.send(RemoteWire.encoder().encode(request)) } catch {
            await self.finish(RelayContext.map(error))
          }
          self.senders.removeValue(forKey: request.id)
        }
      }
    } onCancel: {
      Task { await self.finish(.transport) }
    }
  }

  private func timeout(id: String) async {
    if pending[id] != nil { await finish(.transport) }
  }

  private func readLoop() async {
    do {
      while !closed {
        let bytes = try await channel.receive()
        let frame = try RemoteWire.decoder().decode(LocalAgentFrame.self, from: bytes)
        guard frame.version == 1 else { throw RelayError.invalidMessage }
        switch frame.kind {
        case .response:
          guard let id = frame.id, let item = pending[id], let ok = frame.ok, frame.data == nil
          else { throw RelayError.invalidMessage }
          if !ok {
            RelayTrace.event(
              channel.traceID, "rpc-reply-error", error: RemoteWire.error(frame.error))
            guard frame.error != nil, frame.status == nil, frame.sessions == nil,
              frame.session == nil, frame.mode == nil
            else { throw RelayError.invalidMessage }
            pending.removeValue(forKey: id)
            notifyDrained()
            item.timer.cancel()
            item.continuation.resume(throwing: RemoteWire.error(frame.error))
            continue
          }
          guard frame.error == nil else { throw RelayError.invalidMessage }
          try validate(frame, for: item.request)
          RelayTrace.event(channel.traceID, "rpc-reply-" + item.request.operation.rawValue)
          if item.request.operation == .attach {
            attached = true
            attachedSession = frame.session
          }
          pending.removeValue(forKey: id)
          notifyDrained()
          item.timer.cancel()
          item.continuation.resume(returning: frame)
          if item.request.operation == .detach {
            await finish(nil)
            return
          }
        case .output:
          guard attached, frame.id == nil, frame.ok == nil, frame.error == nil,
            frame.status == nil, frame.sessions == nil, frame.session == nil, frame.mode == nil,
            let bytes = frame.data, !bytes.isEmpty, bytes.count <= 8192
          else { throw RelayError.invalidMessage }
          if !(try await emit(.output(bytes))) { return }
        case .geometry:
          guard attached, let previous = attachedSession, let session = frame.session,
            frame.id == nil, frame.ok == nil, frame.error == nil, frame.data == nil,
            frame.status == nil, frame.sessions == nil, frame.mode == nil,
            session.id == previous.id, session.name == previous.name,
            session.createdAt == previous.createdAt
          else { throw RelayError.invalidMessage }
          try RemoteWire.validate(session)
          attachedSession = session
          if !(try await emit(.geometry(session))) { return }
        case .closed:
          guard attached, frame.id == nil, frame.ok == nil, frame.data == nil,
            frame.status == nil, frame.sessions == nil, frame.session == nil, frame.mode == nil
          else { throw RelayError.invalidMessage }
          await finish(frame.error.map { RemoteWire.error($0) })
          return
        }
      }
    } catch { await finish(RelayContext.map(error)) }
  }

  private func emit(_ event: LocalTerminalEvent) async throws -> Bool {
    switch terminal.yield(event) {
    case .enqueued: return true
    case .dropped: throw RelayError.backpressure
    case .terminated:
      // A handoff's cancelled renderer must not cancel the ACK reader.
      if detaching { return true }
      await finish(nil)
      return false
    }
  }

  private func validate(_ frame: LocalAgentFrame, for request: LocalAgentRequest) throws {
    switch request.operation {
    case .status:
      guard frame.status?.version == 1, frame.sessions == nil, frame.session == nil,
        frame.mode == nil
      else { throw RelayError.invalidMessage }
    case .list:
      guard let sessions = frame.sessions, sessions.count <= 16,
        Set(sessions.map(\.id)).count == sessions.count, frame.status == nil, frame.session == nil,
        frame.mode == nil
      else { throw RelayError.invalidMessage }
      try sessions.forEach(RemoteWire.validate)
    case .attach:
      guard let session = frame.session, session.id == request.sessionID,
        frame.mode == request.mode,
        frame.status == nil, frame.sessions == nil
      else { throw RelayError.invalidMessage }
      try RemoteWire.validate(session)
    default:
      guard frame.status == nil, frame.sessions == nil, frame.session == nil, frame.mode == nil
      else { throw RelayError.invalidMessage }
    }
  }

  private func finish(_ error: RelayError?) async {
    guard !closed else { return }
    closed = true
    terminalError = error
    RelayTrace.event(channel.traceID, "rpc-finish", error: error)
    reader?.cancel()
    for sender in senders.values { sender.cancel() }
    terminal.finish(throwing: error)
    for item in pending.values {
      item.timer.cancel()
      item.continuation.resume(throwing: error ?? RelayError.transport)
    }
    pending.removeAll()
    for waiter in drainWaiters { waiter.resume(throwing: error ?? RelayError.transport) }
    drainWaiters.removeAll()
    await channel.close()
  }

  private func consumerEnded() async {
    if !detaching { await close() }
  }

  private func notifyDrained() {
    guard pending.isEmpty else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForPending() async throws {
    guard !closed else { throw terminalError ?? RelayError.transport }
    if pending.isEmpty { return }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { drainWaiters.append($0) }
    } onCancel: {
      Task { await self.abort() }
    }
  }

  func detach(timeout: Double = 5) async throws {
    if let detachTask { return try await detachTask.value }
    guard !closed else { throw terminalError ?? RelayError.transport }
    detaching = true
    let task = Task {
      do {
        _ = try await relayDeadline(min(5, max(0, timeout))) {
          try await self.waitForPending()
          return try await self.request(LocalAgentRequest(operation: .detach))
        }
        await self.close()
      } catch {
        let first = self.terminalError ?? RelayContext.map(error)
        await self.finish(first)
        await self.close()
        throw first
      }
    }
    detachTask = task
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      Task { await self.abort() }
    }
  }

  func close() async {
    let oldReader = reader
    let oldSenders = Array(senders.values)
    let reason = await channel.terminalFailure()
    await finish(reason == .transport ? nil : reason)
    await oldReader?.value
    for sender in oldSenders { await sender.value }
    reader = nil
  }

  func abort() async {
    let oldDetach = detachTask
    oldDetach?.cancel()
    await close()
    _ = try? await oldDetach?.value
  }
}
