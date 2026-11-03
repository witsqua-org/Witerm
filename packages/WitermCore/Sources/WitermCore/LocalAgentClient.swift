#if os(macOS)
  import Darwin
  import Foundation

  public enum LocalAgentPaths {
    public static func stateDirectory(appGroupID: String) throws -> URL {
      guard !appGroupID.isEmpty, appGroupID.utf8.count < 200,
        appGroupID.unicodeScalars.allSatisfy({
          CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"
          ).contains($0)
        }),
        let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: appGroupID)
      else {
        throw LocalAgentClientError.unsafeSocket
      }
      return container.appendingPathComponent("local", isDirectory: true)
    }

    public static func socketURL(appGroupID: String) throws -> URL {
      try stateDirectory(appGroupID: appGroupID).appendingPathComponent("agent.sock")
    }
  }

  public actor LocalAgentClient {
    private let socketURL: URL

    public init(socketURL: URL) { self.socketURL = socketURL }

    public func status() async throws -> LocalAgentStatus {
      let frame = try await rpc(LocalAgentRequest(operation: .status))
      guard let status = frame.status, status.version == 1 else {
        throw LocalAgentClientError.invalidResponse
      }
      return status
    }

    /// Every session with its sharing state, or, for the relay endpoint acting
    /// for `peer`, only the sessions shared with paired devices.
    public func sessions(peer: LocalRemotePeer? = nil) async throws -> [LocalSessionInfo] {
      try peer.map(LocalWire.validatePeer)
      let frame = try await rpc(LocalAgentRequest(operation: .list, peer: peer))
      guard let sessions = frame.sessions, sessions.count <= 16,
        Set(sessions.map(\.id)).count == sessions.count
      else { throw LocalAgentClientError.invalidResponse }
      try sessions.forEach(LocalWire.validateSession)
      return sessions
    }

    /// Creates a session. `cwd` is an absolute directory for the shell to start
    /// in; `shared` makes it reachable by paired devices from the start.
    public func create(
      name: String, columns: Int = 80, rows: Int = 24, cwd: String? = nil, shared: Bool = false
    ) async throws -> LocalSessionInfo {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard LocalWire.validName(trimmed), LocalWire.validSize(columns: columns, rows: rows),
        cwd.map(LocalWire.validDirectory) ?? true
      else {
        throw LocalAgentClientError.rejected(.invalidRequest)
      }
      let frame = try await rpc(
        LocalAgentRequest(
          operation: .create, name: trimmed, columns: columns, rows: rows, cwd: cwd,
          shared: shared ? true : nil))
      guard let session = frame.session else { throw LocalAgentClientError.invalidResponse }
      try LocalWire.validateSession(session)
      return session
    }

    /// Shares a session with paired devices, or stops sharing it. Stopping
    /// disconnects remote devices; the session keeps running. Returns the
    /// session with its sharing state.
    public func share(sessionID: String, shared: Bool) async throws -> LocalSessionInfo {
      try await configure(sessionID: sessionID, shared: shared)
    }

    /// Changes who may reach a session remotely. `shared` lets every paired
    /// device reach it; `keepPrivate` hides it even from devices allowed
    /// every session (the two exclude each other); `remoteTyping` false
    /// returns paired devices to view only. Each change that narrows access
    /// disconnects the remote attachments it affects; the session keeps running.
    @discardableResult
    public func configure(
      sessionID: String, shared: Bool? = nil, keepPrivate: Bool? = nil, remoteTyping: Bool? = nil
    ) async throws -> LocalSessionInfo {
      try LocalWire.validateID(sessionID)
      guard shared != nil || keepPrivate != nil || remoteTyping != nil,
        !(shared == true && keepPrivate == true)
      else { throw LocalAgentClientError.rejected(.invalidRequest) }
      let frame = try await rpc(
        LocalAgentRequest(
          operation: .share, sessionID: sessionID, shared: shared, keepPrivate: keepPrivate,
          remoteTyping: remoteTyping))
      guard let session = frame.session, session.id == sessionID, let sharing = session.sharing,
        shared.map({ sharing.shared == $0 }) ?? true,
        keepPrivate.map({ sharing.keepPrivate == $0 }) ?? true,
        remoteTyping.map({ sharing.remoteTyping == $0 }) ?? true
      else { throw LocalAgentClientError.invalidResponse }
      try LocalWire.validateSession(session)
      return session
    }

    /// Every paired device's policy on this Mac, or, with `access`, stores
    /// that device's policy first. Narrowing a policy disconnects the
    /// device's attachments it no longer allows.
    @discardableResult
    public func deviceAccess(_ access: LocalDeviceAccess? = nil) async throws -> [LocalDeviceAccess] {
      try access.map { try LocalWire.validateID($0.deviceID) }
      let frame = try await rpc(LocalAgentRequest(operation: .access, access: access))
      guard let accesses = frame.accesses, accesses.count <= 64,
        Set(accesses.map(\.deviceID)).count == accesses.count,
        access.map({ accesses.contains($0) }) ?? true
      else { throw LocalAgentClientError.invalidResponse }
      return accesses
    }

    /// This Mac's invitations to single sessions, after recording `adding`
    /// (with its proof key) or forgetting the one for `removing`.
    @discardableResult
    public func guests(adding: LocalGuestInvite? = nil, removing: String? = nil) async throws
      -> [LocalGuestInvite]
    {
      if let adding {
        try LocalWire.validateID(adding.pairingID)
        try LocalWire.validateID(adding.sessionID)
        guard adding.key?.count == 32, !adding.redeemed else {
          throw LocalAgentClientError.rejected(.invalidRequest)
        }
      }
      try removing.map(LocalWire.validateID)
      let frame = try await rpc(LocalAgentRequest(operation: .guest, guest: adding, pairingID: removing))
      guard let guests = frame.guests, guests.count <= 32, guests.allSatisfy({ $0.key == nil }) else {
        throw LocalAgentClientError.invalidResponse
      }
      return guests
    }

    /// For the relay endpoint: checks a recipient's invitation proof for the
    /// grant `peer` arrived on.
    public func redeem(proof: Data, peer: LocalRemotePeer) async throws {
      try LocalWire.validatePeer(peer)
      guard proof.count == 32, peer.pairingID != nil, peer.publicKey != nil else {
        throw LocalAgentClientError.rejected(.invalidRequest)
      }
      _ = try await rpc(LocalAgentRequest(operation: .redeem, proof: proof, peer: peer))
    }

    /// Changes a session's display name. Attached clients and the shell are
    /// unaffected. Returns the session with its sharing state.
    public func rename(sessionID: String, to name: String) async throws -> LocalSessionInfo {
      try LocalWire.validateID(sessionID)
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard LocalWire.validName(trimmed) else { throw LocalAgentClientError.rejected(.invalidRequest) }
      let frame = try await rpc(LocalAgentRequest(operation: .rename, sessionID: sessionID, name: trimmed))
      guard let session = frame.session, session.id == sessionID, session.name == trimmed
      else { throw LocalAgentClientError.invalidResponse }
      try LocalWire.validateSession(session)
      return session
    }

    public func close(sessionID: String) async throws {
      try LocalWire.validateID(sessionID)
      _ = try await rpc(LocalAgentRequest(operation: .close, sessionID: sessionID))
    }

    /// Attaches to a session. Only the relay endpoint passes `peer`, which
    /// limits the attach to what this Mac lets that device reach. `history`
    /// is for renderers with their own scrollback, never a real terminal.
    /// `outputStall` is how long the attachment waits while its consumer
    /// takes nothing before giving up; the relay endpoint, which applies its
    /// own limit to the device, passes a longer one.
    public func attach(
      sessionID: String, columns: Int = 80, rows: Int = 24, mode: LocalAttachmentMode = .control,
      history: Bool = false, peer: LocalRemotePeer? = nil, outputStall: Duration = .seconds(30)
    ) async throws -> LocalTerminalAttachment {
      try LocalWire.validateID(sessionID)
      try peer.map(LocalWire.validatePeer)
      guard LocalWire.validSize(columns: columns, rows: rows) else {
        throw LocalAgentClientError.rejected(.invalidRequest)
      }
      let connection = try await LocalSocketConnection.open(socketURL: socketURL, outputStall: outputStall)
      do {
        let request = LocalAgentRequest(
          operation: .attach, sessionID: sessionID, columns: columns, rows: rows, mode: mode,
          history: history ? true : nil, peer: peer)
        let frame = try await connection.request(request)
        guard let session = frame.session, session.id == sessionID, frame.mode == mode else {
          throw LocalAgentClientError.invalidResponse
        }
        try LocalWire.validateSession(session)
        return LocalTerminalAttachment(connection: connection, mode: mode, session: session)
      } catch {
        connection.finish(throwing: error)
        throw error
      }
    }

    private func rpc(_ request: LocalAgentRequest) async throws -> LocalAgentFrame {
      let connection = try await LocalSocketConnection.open(socketURL: socketURL)
      defer { connection.finish(throwing: nil) }
      return try await connection.request(request)
    }
  }

  public final class LocalTerminalAttachment: Sendable {
    /// Select either events or legacy output and consume it with one iterator.
    public var events: AsyncThrowingStream<LocalTerminalEvent, Error> { connection.events }
    public var output: AsyncThrowingStream<Data, Error> { connection.output }
    /// Snapshot from the attach ACK. Later dimensions arrive through events.
    public let session: LocalSessionInfo
    private let connection: LocalSocketConnection
    private let mode: LocalAttachmentMode

    fileprivate init(
      connection: LocalSocketConnection, mode: LocalAttachmentMode, session: LocalSessionInfo
    ) {
      self.connection = connection
      self.mode = mode
      self.session = session
    }

    deinit { connection.finish(throwing: nil) }

    /// `automatic` marks the terminal's own answers to queries in its
    /// output, which never move the session's grid the way typing does.
    public func send(_ data: Data, automatic: Bool = false) async throws {
      guard mode == .control else { throw LocalAgentClientError.rejected(.readOnly) }
      guard data.count <= 16_384 else { throw LocalAgentClientError.rejected(.invalidRequest) }
      _ = try await connection.request(
        LocalAgentRequest(operation: .input, data: data, automatic: automatic ? true : nil))
    }

    public func resize(columns: Int, rows: Int) async throws {
      guard mode == .control else { throw LocalAgentClientError.rejected(.readOnly) }
      guard LocalWire.validSize(columns: columns, rows: rows) else {
        throw LocalAgentClientError.rejected(.invalidRequest)
      }
      _ = try await connection.request(
        LocalAgentRequest(operation: .resize, columns: columns, rows: rows))
    }

    public func detach() async throws {
      do {
        _ = try await connection.request(LocalAgentRequest(operation: .detach))
        connection.finish(throwing: nil)
      } catch {
        connection.finish(throwing: error)
        throw error
      }
    }

    public func disconnect() async { try? await detach() }
  }

  enum LocalWire {
    static let maximumLineBytes = 65_536

    static func validName(_ name: String) -> Bool {
      !name.isEmpty && name.unicodeScalars.count <= 64
        && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
        && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func validSize(columns: Int, rows: Int) -> Bool {
      (20...500).contains(columns) && (5...200).contains(rows)
    }

    static func validateID(_ id: String) throws {
      guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
        throw LocalAgentClientError.rejected(.invalidRequest)
      }
    }

    static func validateSession(_ session: LocalSessionInfo) throws {
      guard UUID(uuidString: session.id)?.uuidString.lowercased() == session.id,
        validName(session.name), validSize(columns: session.columns, rows: session.rows),
        session.createdAt.timeIntervalSince1970.isFinite
      else {
        throw LocalAgentClientError.invalidResponse
      }
      if let sharing = session.sharing {
        guard sharing.attachments.count <= 32, !(sharing.shared && sharing.keepPrivate)
        else { throw LocalAgentClientError.invalidResponse }
        for attachment in sharing.attachments {
          do { try attachment.device.map(validatePeer) } catch {
            throw LocalAgentClientError.invalidResponse
          }
        }
      }
    }

    static func validatePeer(_ peer: LocalRemotePeer) throws {
      try validateID(peer.deviceID)
      try peer.pairingID.map(validateID)
      if let key = peer.publicKey, PairingEncoding.publicKey(key) == nil {
        throw LocalAgentClientError.rejected(.invalidRequest)
      }
      guard validName(peer.name) else { throw LocalAgentClientError.rejected(.invalidRequest) }
    }

    /// An absolute, normalized path without control characters. The service
    /// checks that it is an accessible directory.
    static func validDirectory(_ path: String) -> Bool {
      path.hasPrefix("/") && path.utf8.count <= 1024
        && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        && !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }

    static func encode(_ request: LocalAgentRequest) throws -> Data {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      var data = try encoder.encode(request)
      guard data.count < maximumLineBytes else {
        throw LocalAgentClientError.rejected(.invalidRequest)
      }
      data.append(10)
      return data
    }

    static func decode(_ data: Data) throws -> LocalAgentFrame {
      guard !data.isEmpty, data.count < maximumLineBytes else {
        throw LocalAgentClientError.invalidResponse
      }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      do {
        let frame = try decoder.decode(LocalAgentFrame.self, from: data)
        guard frame.version == 1 else { throw LocalAgentClientError.invalidResponse }
        return frame
      } catch { throw LocalAgentClientError.invalidResponse }
    }
  }

  final class LocalSocketConnection: @unchecked Sendable {
    struct Pending {
      let request: LocalAgentRequest
      let continuation: CheckedContinuation<LocalAgentFrame, Error>
      let timeout: DispatchWorkItem
    }

    private let terminal: LocalTerminalStreams
    var output: AsyncThrowingStream<Data, Error> { terminal.output() }
    var events: AsyncThrowingStream<LocalTerminalEvent, Error> { terminal.events() }
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "com.witerm.local.write", qos: .userInitiated)
    private let descriptor: Int32
    private var closed = false
    private var attached = false
    private var attachedSession: LocalSessionInfo?
    private var pending: [String: Pending] = [:]

    private init(descriptor: Int32, readDescriptor: Int32, outputStall: Duration) {
      self.descriptor = descriptor
      terminal = LocalTerminalStreams(
        conflictError: LocalAgentClientError.invalidResponse, stallLimit: outputStall)
      terminal.onTermination { [weak self] in self?.finish(throwing: nil) }
      DispatchQueue(label: "com.witerm.local.read", qos: .userInitiated).async { [self] in
        defer { Darwin.close(readDescriptor) }
        readFrames(from: readDescriptor)
      }
    }

    static func open(socketURL: URL, outputStall: Duration = .seconds(30)) async throws
      -> LocalSocketConnection
    {
      let operation = LocalSocketOpenOperation()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          operation.start(socketURL: socketURL, outputStall: outputStall, continuation: continuation)
        }
      } onCancel: {
        operation.cancel()
      }
    }

    fileprivate static func connect(socketURL: URL, outputStall: Duration) throws
      -> LocalSocketConnection
    {
      guard socketURL.isFileURL, socketURL.path.hasPrefix("/"), !socketURL.path.utf8.contains(0)
      else {
        throw LocalAgentClientError.unsafeSocket
      }
      let path = socketURL.standardizedFileURL.path
      let directory = socketURL.standardizedFileURL.deletingLastPathComponent().path
      var directoryStat = stat()
      guard lstat(directory, &directoryStat) == 0 else {
        if errno == ENOENT { throw LocalAgentClientError.unavailable }
        throw LocalAgentClientError.unsafeSocket
      }
      guard directoryStat.st_mode & S_IFMT == S_IFDIR,
        directoryStat.st_uid == geteuid(), directoryStat.st_mode & 0o7777 == 0o700
      else {
        throw LocalAgentClientError.unsafeSocket
      }
      var socketStat = stat()
      guard lstat(path, &socketStat) == 0 else { throw LocalAgentClientError.unavailable }
      guard socketStat.st_mode & S_IFMT == S_IFSOCK, socketStat.st_uid == geteuid(),
        socketStat.st_mode & 0o7777 == 0o600
      else { throw LocalAgentClientError.unsafeSocket }
      var address = sockaddr_un()
      let bytes = Array(path.utf8)
      guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw LocalAgentClientError.unsafeSocket
      }
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: bytes + [0])
      }
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw LocalAgentClientError.unavailable }
      var transferred = false
      defer { if !transferred { Darwin.close(descriptor) } }
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw LocalAgentClientError.unavailable
      }
      let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      if result != 0 {
        guard errno == EINPROGRESS || errno == EAGAIN else {
          throw LocalAgentClientError.unavailable
        }
        var pollFD = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, 3000) > 0 else { throw LocalAgentClientError.unavailable }
        var socketError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
          socketError == 0
        else {
          throw LocalAgentClientError.unavailable
        }
      }
      guard fcntl(descriptor, F_SETFL, flags) == 0 else { throw LocalAgentClientError.unavailable }
      var peerUID: uid_t = 0
      var peerGID: gid_t = 0
      guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
        throw LocalAgentClientError.unsafeSocket
      }
      var afterDirectory = stat()
      var afterSocket = stat()
      guard lstat(directory, &afterDirectory) == 0, lstat(path, &afterSocket) == 0,
        afterDirectory.st_dev == directoryStat.st_dev,
        afterDirectory.st_ino == directoryStat.st_ino,
        afterDirectory.st_mode & 0o7777 == 0o700, afterDirectory.st_uid == geteuid(),
        afterSocket.st_dev == socketStat.st_dev, afterSocket.st_ino == socketStat.st_ino,
        afterSocket.st_mode & 0o7777 == 0o600, afterSocket.st_uid == geteuid()
      else {
        throw LocalAgentClientError.unsafeSocket
      }
      var noSignal: Int32 = 1
      _ = setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
      _ = setsockopt(
        descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
      let readDescriptor = dup(descriptor)
      guard readDescriptor >= 0 else { throw LocalAgentClientError.unavailable }
      _ = fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
      let connection = LocalSocketConnection(
        descriptor: descriptor, readDescriptor: readDescriptor, outputStall: outputStall)
      transferred = true
      return connection
    }

    func request(_ request: LocalAgentRequest) async throws -> LocalAgentFrame {
      let data = try LocalWire.encode(request)
      try Task.checkCancellation()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { callback in
          let timeout = DispatchWorkItem { [weak self] in self?.timeout(requestID: request.id) }
          lock.lock()
          guard !closed, pending.count < 32, pending[request.id] == nil else {
            lock.unlock()
            callback.resume(throwing: LocalAgentClientError.unavailable)
            return
          }
          pending[request.id] = Pending(request: request, continuation: callback, timeout: timeout)
          writer.async { [self] in write(data) }
          lock.unlock()
          DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 5, execute: timeout)
        }
      } onCancel: {
        self.finish(throwing: CancellationError())
      }
    }

    private func timeout(requestID: String) {
      lock.lock()
      let waiting = !closed && pending[requestID] != nil
      lock.unlock()
      if waiting { finish(throwing: LocalAgentClientError.unavailable) }
    }

    func finish(throwing error: Error?) {
      lock.lock()
      if closed {
        lock.unlock()
        return
      }
      closed = true
      let waiting = Array(pending.values)
      pending.removeAll()
      _ = shutdown(descriptor, SHUT_RDWR)
      _ = Darwin.close(descriptor)
      lock.unlock()
      for item in waiting {
        item.timeout.cancel()
        item.continuation.resume(throwing: error ?? LocalAgentClientError.unavailable)
      }
      terminal.finish(throwing: error)
    }

    private func write(_ data: Data) {
      var offset = 0
      while offset < data.count {
        lock.lock()
        if closed {
          lock.unlock()
          return
        }
        let count = data.withUnsafeBytes { bytes in
          Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
        }
        let failure = errno
        lock.unlock()
        if count > 0 {
          offset += count
          continue
        }
        if count < 0 && failure == EINTR { continue }
        finish(throwing: LocalAgentClientError.unavailable)
        return
      }
    }

    private func readFrames(from descriptor: Int32) {
      var buffer = Data()
      var bytes = [UInt8](repeating: 0, count: 16_384)
      while true {
        let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else {
          finish(throwing: LocalAgentClientError.unavailable)
          return
        }
        buffer.append(contentsOf: bytes.prefix(count))
        while let end = buffer.firstIndex(of: 10) {
          guard end < LocalWire.maximumLineBytes else {
            finish(throwing: LocalAgentClientError.invalidResponse)
            return
          }
          let line = Data(buffer.prefix(upTo: end))
          buffer.removeSubrange(...end)
          do { try receive(LocalWire.decode(line)) } catch {
            finish(throwing: error)
            return
          }
          // A slow renderer slows this reader, and so the socket and the
          // service, instead of losing output. Only one that takes nothing
          // for a long while is let go.
          guard terminal.waitForRoom() else {
            finish(throwing: LocalAgentClientError.backpressure)
            return
          }
        }
        guard buffer.count < LocalWire.maximumLineBytes else {
          finish(throwing: LocalAgentClientError.invalidResponse)
          return
        }
        lock.lock()
        let stopped = closed
        lock.unlock()
        if stopped { return }
      }
    }

    private func receive(_ frame: LocalAgentFrame) throws {
      switch frame.kind {
      case .response:
        guard let id = frame.id, UUID(uuidString: id)?.uuidString.lowercased() == id,
          frame.data == nil, frame.ok != nil
        else { throw LocalAgentClientError.invalidResponse }
        lock.lock()
        guard let item = pending.removeValue(forKey: id) else {
          lock.unlock()
          throw LocalAgentClientError.invalidResponse
        }
        lock.unlock()
        item.timeout.cancel()
        if frame.ok == true && frame.error == nil {
          if item.request.operation == .attach {
            do {
              guard let session = frame.session, session.id == item.request.sessionID,
                frame.mode == item.request.mode, frame.status == nil, frame.sessions == nil
              else { throw LocalAgentClientError.invalidResponse }
              try LocalWire.validateSession(session)
              lock.withLock {
                attached = true
                attachedSession = session
              }
            } catch {
              item.continuation.resume(throwing: error)
              throw error
            }
          }
          item.continuation.resume(returning: frame)
          if item.request.operation == .detach { finish(throwing: nil) }
        } else if frame.ok == false, let error = frame.error {
          item.continuation.resume(throwing: LocalAgentClientError.rejected(error))
        } else {
          item.continuation.resume(throwing: LocalAgentClientError.invalidResponse)
          throw LocalAgentClientError.invalidResponse
        }
      case .output:
        lock.lock()
        let ready = attached && !closed
        lock.unlock()
        guard ready, frame.id == nil, frame.ok == nil, frame.error == nil,
          frame.status == nil, frame.sessions == nil, frame.session == nil, frame.mode == nil,
          let data = frame.data, !data.isEmpty, data.count <= 8192
        else { throw LocalAgentClientError.invalidResponse }
        try emit(.output(data))
      case .geometry:
        let previous = lock.withLock { !closed ? attachedSession : nil }
        guard let previous, let session = frame.session,
          frame.id == nil, frame.ok == nil, frame.error == nil, frame.data == nil,
          frame.status == nil, frame.sessions == nil, frame.mode == nil,
          // The ID and creation time identify the session. Its name may have
          // changed: a terminal can be renamed while it's open.
          session.id == previous.id, session.createdAt == previous.createdAt
        else { throw LocalAgentClientError.invalidResponse }
        try LocalWire.validateSession(session)
        lock.withLock { attachedSession = session }
        try emit(.geometry(session))
      case .closed:
        lock.lock()
        let ready = attached
        lock.unlock()
        guard ready, frame.id == nil, frame.data == nil, frame.ok == nil,
          frame.status == nil, frame.sessions == nil, frame.session == nil, frame.mode == nil
        else {
          throw LocalAgentClientError.invalidResponse
        }
        if frame.error == .backpressure { throw LocalAgentClientError.backpressure }
        if let error = frame.error { throw LocalAgentClientError.rejected(error) }
        finish(throwing: nil)
      }
    }

    private func emit(_ event: LocalTerminalEvent) throws {
      switch terminal.yield(event) {
      case .enqueued: break
      case .dropped: throw LocalAgentClientError.backpressure
      case .terminated: finish(throwing: nil)
      }
    }
  }

  private final class LocalSocketOpenOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var callback: CheckedContinuation<LocalSocketConnection, Error>?

    func start(
      socketURL: URL, outputStall: Duration,
      continuation: CheckedContinuation<LocalSocketConnection, Error>
    ) {
      lock.lock()
      if cancelled {
        lock.unlock()
        continuation.resume(throwing: CancellationError())
        return
      }
      callback = continuation
      lock.unlock()
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        let result = Result {
          try LocalSocketConnection.connect(socketURL: socketURL, outputStall: outputStall)
        }
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        if let callback {
          callback.resume(with: result)
        } else if case .success(let connection) = result {
          connection.finish(throwing: nil)
        }
      }
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let callback = self.callback
      self.callback = nil
      lock.unlock()
      callback?.resume(throwing: CancellationError())
    }
  }
#endif
