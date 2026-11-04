import Foundation

protocol RelaySocketIO: Sendable {
  func send(_ data: Data) async throws
  func receive() async throws -> Data
  func close()
}

// One completion wins, including cancellation before a native ping callback.
// The callback never retains a WebSocket wrapper or a heartbeat loop.
private final class RelayPingCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Void, Error>?
  private var continuation: CheckedContinuation<Void, Error>?

  func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  @discardableResult func finish(_ result: Result<Void, Error>) -> Bool {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return false
    }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
    return true
  }
}

enum RelayPing {
  static func wait(
    start: @escaping @Sendable (@escaping @Sendable (Error?) -> Void) -> Void,
    cancel: @escaping @Sendable () -> Void
  ) async throws {
    let completion = RelayPingCompletion()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        if completion.install(continuation) {
          start { error in
            completion.finish(error.map { .failure($0) } ?? .success(()))
          }
        }
      }
    } onCancel: {
      if completion.finish(.failure(CancellationError())) { cancel() }
    }
  }
}

final class RelayHealthLoop: Sendable {
  private let worker: Task<Void, Never>
  init(
    interval: Double = 5, timeout: Double = 3,
    ping: @escaping @Sendable () async throws -> Void,
    failed: @escaping @Sendable () -> Void
  ) {
    worker = Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(interval))
          try await relayDeadline(timeout) { try await ping() }
        } catch {
          if !Task.isCancelled { failed() }
          return
        }
      }
    }
  }
  deinit { worker.cancel() }
  func stop() { worker.cancel() }
  func wait() async { await worker.value }
}

final class RelayNetworkDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

enum RelayNetwork {
  static func session(resourceTimeout: TimeInterval = 86_400) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = resourceTimeout
    return URLSession(configuration: config, delegate: RelayNetworkDelegate(), delegateQueue: nil)
  }

  static func request(credentials: RelayCredentials, path: String, websocket: Bool) throws
    -> URLRequest
  {
    let server = try PairingServerAddress.normalized(credentials.server.absoluteString)
    guard server == credentials.server, credentials.expiresAt > Date(),
      PairingEncoding.randomValue(credentials.accessToken) != nil
    else { throw RelayError.unauthorized }
    var parts = URLComponents(
      url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if websocket { parts.scheme = server.scheme == "https" ? "wss" : "ws" }
    guard let url = parts.url else { throw RelayError.invalidMessage }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    return request
  }

  static func createTunnel(
    credentials: RelayCredentials, grantID: String,
    session suppliedSession: URLSession? = nil, deadline: Double = 10
  ) async throws -> String {
    guard PairingEncoding.canonicalID(grantID) == grantID else { throw RelayError.untrusted }
    let session = suppliedSession ?? Self.session(resourceTimeout: 10)
    defer { session.invalidateAndCancel() }
    var request = try request(credentials: credentials, path: "v1/relay/tunnels", websocket: false)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try RelayMetadata.createRequest(grantID: grantID)
    let finalRequest = request
    do {
      return try await relayDeadline(min(10, max(0, deadline))) {
        try await withTaskCancellationHandler {
          let (bytes, response) = try await session.bytes(for: finalRequest)
          guard let response = response as? HTTPURLResponse else { throw RelayError.invalidMessage }
          var data = Data()
          for try await byte in bytes {
            guard data.count < 4096 else { throw RelayError.invalidMessage }
            data.append(byte)
          }
          guard response.statusCode == 201 else {
            throw apiError(data: data, status: response.statusCode)
          }
          return try RelayMetadata.createdTunnel(data)
        } onCancel: {
          session.invalidateAndCancel()
        }
      }
    } catch is CancellationError { throw CancellationError() } catch {
      RelayTrace.event("http", "create-failed", error: error)
      throw RelayContext.map(error)
    }
  }

  static func apiError(data: Data, status: Int) -> RelayError {
    struct Envelope: Decodable {
      struct Detail: Decodable { let code: String }
      let error: Detail
    }
    if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
      return RelayContext.api(envelope.error.code)
    }
    return status == 401 ? .unauthorized : (status == 403 ? .revoked : .unavailable)
  }
}

final class RelayWebSocket: RelaySocketIO, Sendable {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let expiry: Task<Void, Never>
  private let health: RelayHealthLoop
  private let traceID: String

  init(credentials: RelayCredentials, path: String) throws {
    let request = try RelayNetwork.request(credentials: credentials, path: path, websocket: true)
    let session = RelayNetwork.session()
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = 65_536
    self.session = session
    self.task = task
    traceID =
      String(path.split(separator: "/").last!.prefix(8)) + "/"
      + credentials.device.platform.rawValue
    let seconds = max(0, credentials.expiresAt.timeIntervalSinceNow)
    expiry = Task {
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      task.cancel(with: .policyViolation, reason: nil)
      session.invalidateAndCancel()
    }
    health = RelayHealthLoop(
      ping: {
        try await RelayPing.wait(
          start: { callback in task.sendPing(pongReceiveHandler: callback) },
          cancel: {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
          })
      },
      failed: {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
      })
    task.resume()
  }

  deinit {
    RelayTrace.event(traceID, "socket-deinit")
    expiry.cancel()
    health.stop()
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
  func close() {
    RelayTrace.event(traceID, "socket-close")
    expiry.cancel()
    health.stop()
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
  func send(_ data: Data) async throws {
    guard data.count <= 65_536 else {
      close()
      throw RelayError.invalidMessage
    }
    try await withTaskCancellationHandler {
      do { try await task.send(.data(data)) } catch {
        RelayTrace.event(traceID, "socket-send-failed", error: error)
        close()
        throw failure(error)
      }
    } onCancel: {
      RelayTrace.event(self.traceID, "socket-send-cancel")
      self.close()
    }
  }
  /// A text message (presence's watch request).
  func sendText(_ data: Data) async throws {
    guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw RelayError.invalidMessage }
    do { try await task.send(.string(text)) } catch {
      close()
      throw failure(error)
    }
  }
  /// The server answered the upgrade with 404: it has no such endpoint.
  var unsupported: Bool { (task.response as? HTTPURLResponse)?.statusCode == 404 }
  func receive() async throws -> Data {
    try await withTaskCancellationHandler {
      do {
        guard case .data(let data) = try await task.receive(), data.count <= 65_536 else {
          throw RelayError.invalidMessage
        }
        return data
      } catch {
        RelayTrace.event(traceID, "socket-receive-failed", error: error)
        close()
        throw failure(error)
      }
    } onCancel: {
      RelayTrace.event(self.traceID, "socket-receive-cancel")
      self.close()
    }
  }
  func control() async throws -> Data {
    try await withTaskCancellationHandler {
      do {
        guard case .string(let text) = try await task.receive(), text.utf8.count <= 4096 else {
          throw RelayError.invalidMessage
        }
        return Data(text.utf8)
      } catch {
        close()
        throw failure(error)
      }
    } onCancel: {
      self.close()
    }
  }
  private func failure(_ error: Error) -> Error {
    if Task.isCancelled { return CancellationError() }
    if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
      return RelayNetwork.apiError(data: Data(), status: response.statusCode)
    }
    return RelayContext.map(error)
  }
}

func relayDeadline<T: Sendable>(
  _ seconds: Double, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw RelayError.transport
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw RelayError.transport }
    return result
  }
}
