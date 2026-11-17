#if os(macOS)
  import Darwin
  import Foundation

  public enum OrbitClientError: Error, Equatable, Sendable {
    /// Orbit isn't running (no socket), or didn't answer.
    case unavailable
    /// The socket or its folder failed a safety check.
    case unsafeSocket
    case invalidResponse
    case rejected(OrbitErrorCode)
  }

  public enum OrbitPaths {
    /// `orbit/` in the app group's container, beside the terminal service's
    /// `local/`.
    public static func directory(appGroupID: String) throws -> URL {
      try LocalAgentPaths.stateDirectory(appGroupID: appGroupID)
        .deletingLastPathComponent().appendingPathComponent("orbit", isDirectory: true)
    }

    public static let socketName = "orbit.sock"
  }

  /// Talks to `witerm orbit serve` over its private Unix socket: one request
  /// and one reply per connection, both checked to belong to this user.
  public struct OrbitClient: Sendable {
    public let socketURL: URL
    public var timeout: TimeInterval = 15

    public init(socketURL: URL) { self.socketURL = socketURL }

    public func status() async throws -> OrbitStatus {
      guard let status = try await rpc(OrbitRequest(operation: .status)).status else {
        throw OrbitClientError.invalidResponse
      }
      return status
    }

    @discardableResult
    public func configure(apiKey: String?, model: String?) async throws -> OrbitStatus {
      guard let status = try await rpc(OrbitRequest(operation: .configure, apiKey: apiKey, model: model)).status
      else { throw OrbitClientError.invalidResponse }
      return status
    }

    public func threads() async throws -> [OrbitThreadSummary] {
      guard let threads = try await rpc(OrbitRequest(operation: .threads)).threads else {
        throw OrbitClientError.invalidResponse
      }
      return threads
    }

    public func thread(_ id: String) async throws -> OrbitThreadDetail {
      try await detail(OrbitRequest(operation: .thread, threadID: id))
    }

    public func start(text: String, kind: OrbitThreadKind, terminalID: String?) async throws -> OrbitThreadDetail {
      try await detail(OrbitRequest(operation: .start, text: text, kind: kind, terminalID: terminalID))
    }

    public func send(_ text: String, to id: String, agent: String? = nil) async throws -> OrbitThreadDetail {
      try await detail(OrbitRequest(operation: .send, threadID: id, text: text, agent: agent))
    }

    public func stop(_ id: String) async throws -> OrbitThreadDetail {
      try await detail(OrbitRequest(operation: .stop, threadID: id))
    }

    public func takeOver(_ id: String, agent: String) async throws -> OrbitThreadDetail {
      try await detail(OrbitRequest(operation: .takeOver, threadID: id, agent: agent))
    }

    public func finish(_ id: String, agent: String, summary: String, success: Bool) async throws -> OrbitThreadDetail {
      try await detail(OrbitRequest(operation: .finish, threadID: id, text: summary, agent: agent, success: success))
    }

    public func delete(_ id: String) async throws {
      _ = try await rpc(OrbitRequest(operation: .delete, threadID: id))
    }

    public func clear() async throws {
      _ = try await rpc(OrbitRequest(operation: .clear))
    }

    private func detail(_ request: OrbitRequest) async throws -> OrbitThreadDetail {
      guard let thread = try await rpc(request).thread else { throw OrbitClientError.invalidResponse }
      return thread
    }

    public func rpc(_ request: OrbitRequest) async throws -> OrbitResponse {
      let url = socketURL
      let timeout = timeout
      let line = try OrbitWire.encoder().encode(request) + Data([0x0a])
      let reply: Data = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result { try Self.exchange(line, socketURL: url, timeout: timeout) })
        }
      }
      guard let response = try? OrbitWire.decoder().decode(OrbitResponse.self, from: reply),
        response.version == 1, response.id == request.id
      else { throw OrbitClientError.invalidResponse }
      guard response.ok else { throw OrbitClientError.rejected(response.error ?? .unavailable) }
      return response
    }

    /// Connects, writes the request line, and reads one reply line.
    static func exchange(_ line: Data, socketURL: URL, timeout: TimeInterval) throws -> Data {
      let path = socketURL.standardizedFileURL.path
      let directory = socketURL.standardizedFileURL.deletingLastPathComponent().path
      var info = stat()
      guard lstat(directory, &info) == 0 else {
        throw errno == ENOENT ? OrbitClientError.unavailable : OrbitClientError.unsafeSocket
      }
      guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
        throw OrbitClientError.unsafeSocket
      }
      guard lstat(path, &info) == 0 else { throw OrbitClientError.unavailable }
      guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw OrbitClientError.unsafeSocket }
      var address = sockaddr_un()
      let bytes = Array(path.utf8)
      guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw OrbitClientError.unsafeSocket }
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw OrbitClientError.unavailable }
      defer { Darwin.close(descriptor) }
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      var noSignal: Int32 = 1
      _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
      _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
      _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else { throw OrbitClientError.unavailable }
      var user: uid_t = 0
      var group: gid_t = 0
      guard getpeereid(descriptor, &user, &group) == 0, user == geteuid() else { throw OrbitClientError.unsafeSocket }
      try line.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
          let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
          if count > 0 { offset += count } else if count < 0, errno == EINTR { continue } else {
            throw OrbitClientError.unavailable
          }
        }
      }
      var reply = Data()
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while !reply.contains(0x0a) {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
          reply.append(contentsOf: buffer[0..<count])
          guard reply.count <= OrbitWire.lineLimit else { throw OrbitClientError.invalidResponse }
        } else if count < 0, errno == EINTR {
          continue
        } else {
          throw OrbitClientError.unavailable
        }
      }
      return reply.prefix { $0 != 0x0a }
    }
  }
#endif
