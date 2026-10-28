import Foundation

public enum LocalAgentOperation: String, Codable, Sendable {
  case status, list, create, close, attach, input, resize, detach, share, rename, access
  /// Local only: this Mac's invitations to single sessions.
  case guest
  /// From the relay endpoint: a recipient proving it holds an invitation's key.
  case redeem
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
  /// Present only in a local `list` response; never sent to a remote device.
  public let sharing: LocalSessionSharing?
  /// Present only in a `list` response for a paired device: the most that
  /// device may do in this session.
  public let access: LocalAttachmentMode?

  public init(
    id: String, name: String, createdAt: Date, columns: Int, rows: Int,
    sharing: LocalSessionSharing? = nil, access: LocalAttachmentMode? = nil
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.columns = columns
    self.rows = rows
    self.sharing = sharing
    self.access = access
  }

  /// The same session without local-only details.
  public var withoutSharing: LocalSessionInfo {
    LocalSessionInfo(id: id, name: name, createdAt: createdAt, columns: columns, rows: rows)
  }

  /// The same session as a paired device sees it.
  public func forPeer(access: LocalAttachmentMode) -> LocalSessionInfo {
    LocalSessionInfo(id: id, name: name, createdAt: createdAt, columns: columns, rows: rows, access: access)
  }

  enum CodingKeys: String, CodingKey {
    case id, name, columns, rows, sharing, access
    case createdAt = "created_at"
  }
}

/// Which paired devices may list and attach to a session, and who is attached.
public struct LocalSessionSharing: Codable, Sendable, Equatable {
  /// Every paired device may reach it, including those limited to shared sessions.
  public let shared: Bool
  /// No paired device may reach it, even those allowed every session.
  public let keepPrivate: Bool
  /// Whether paired devices with control may type. Turning it off returns
  /// them to view only; this Mac keeps typing.
  public let remoteTyping: Bool
  public let attachments: [LocalAttachmentInfo]

  public init(
    shared: Bool, keepPrivate: Bool = false, remoteTyping: Bool = true,
    attachments: [LocalAttachmentInfo]
  ) {
    self.shared = shared
    self.keepPrivate = keepPrivate
    self.remoteTyping = remoteTyping
    self.attachments = attachments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    shared = try container.decode(Bool.self, forKey: .shared)
    keepPrivate = try container.decodeIfPresent(Bool.self, forKey: .keepPrivate) ?? false
    remoteTyping = try container.decodeIfPresent(Bool.self, forKey: .remoteTyping) ?? true
    attachments = try container.decode([LocalAttachmentInfo].self, forKey: .attachments)
  }

  /// The first attachment that may type; several can when typing is shared.
  public var controller: LocalAttachmentInfo? { attachments.first { $0.mode == .control } }
  public var controllers: [LocalAttachmentInfo] { attachments.filter { $0.mode == .control } }

  enum CodingKeys: String, CodingKey {
    case shared, attachments
    case keepPrivate = "keep_private"
    case remoteTyping = "remote_typing"
  }
}

/// Which sessions a paired device may reach on this Mac.
public enum LocalSessionScope: String, Codable, Sendable, CaseIterable {
  /// Every session except those kept private.
  case all
  /// Only sessions explicitly shared.
  case shared
}

/// This Mac's own policy for one paired device. It can only narrow the
/// signed grant: a view-only grant never gains control here.
public struct LocalDeviceAccess: Codable, Sendable, Equatable, Identifiable {
  public let deviceID: String
  public let scope: LocalSessionScope
  public let permission: LocalAttachmentMode
  /// Whether this device may type while others (such as this Mac) also have control.
  public let coTyping: Bool

  public var id: String { deviceID }

  public init(
    deviceID: String, scope: LocalSessionScope, permission: LocalAttachmentMode, coTyping: Bool = true
  ) {
    self.deviceID = deviceID
    self.scope = scope
    self.permission = permission
    self.coTyping = coTyping
  }

  /// A paired device without an entry, such as one paired before this Mac
  /// kept a policy: shared sessions only, up to its grant, typing alongside.
  public static func `default`(for deviceID: String) -> LocalDeviceAccess {
    LocalDeviceAccess(deviceID: deviceID, scope: .shared, permission: .control)
  }

  enum CodingKeys: String, CodingKey {
    case scope, permission
    case deviceID = "device_id"
    case coTyping = "co_typing"
  }
}

/// One live attachment. A nil device means this Mac.
public struct LocalAttachmentInfo: Codable, Sendable, Equatable {
  public let mode: LocalAttachmentMode
  public let device: LocalRemotePeer?

  public init(mode: LocalAttachmentMode, device: LocalRemotePeer?) {
    self.mode = mode
    self.device = device
  }
}

/// The paired device a relayed request acts for. Only the Mac's relay
/// endpoint sets it; remote devices can never supply it.
public struct LocalRemotePeer: Codable, Sendable, Equatable {
  public let deviceID: String
  public let name: String
  /// The pairing whose grant the request arrived on: an invitation's grant
  /// reaches only its session.
  public let pairingID: String?
  /// The device's verified identity key, for checking an invitation proof.
  public let publicKey: String?

  public init(deviceID: String, name: String, pairingID: String? = nil, publicKey: String? = nil) {
    self.deviceID = deviceID
    self.name = name
    self.pairingID = pairingID
    self.publicKey = publicKey
  }

  /// Who is attached, as this Mac's own clients see it.
  public var identity: LocalRemotePeer { LocalRemotePeer(deviceID: deviceID, name: name) }

  enum CodingKeys: String, CodingKey {
    case name
    case deviceID = "device_id"
    case pairingID = "pairing_id"
    case publicKey = "public_key"
  }
}

/// This Mac's invitation to one session for a device that hasn't paired.
/// Recorded before anyone can join, so its grant never reaches more.
public struct LocalGuestInvite: Codable, Sendable, Equatable, Identifiable {
  public let pairingID: String
  public let sessionID: String
  public let permission: LocalAttachmentMode
  public let expiresAt: Date
  /// The proof key; present only when recording the invitation.
  public let key: Data?
  /// Whether the recipient has proved it holds the key.
  public let redeemed: Bool

  public var id: String { pairingID }

  /// The expiry of an invitation this Mac has forgotten: its grant reaches
  /// nothing, and it is never listed.
  public static let ended = Date(timeIntervalSince1970: 0)

  public init(
    pairingID: String, sessionID: String, permission: LocalAttachmentMode, expiresAt: Date,
    key: Data? = nil, redeemed: Bool = false
  ) {
    self.pairingID = pairingID
    self.sessionID = sessionID
    self.permission = permission
    self.expiresAt = expiresAt
    self.key = key
    self.redeemed = redeemed
  }

  enum CodingKeys: String, CodingKey {
    case permission, key, redeemed
    case pairingID = "pairing_id"
    case sessionID = "session_id"
    case expiresAt = "expires_at"
  }
}

/// Remote access through one server, as the Mac's relay endpoint sees it.
public struct LocalRelayStatus: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable { case connecting, ready }
  public let server: String
  public let state: State

  public init(server: String, state: State) {
    self.server = server
    self.state = state
  }
}

public struct LocalAgentStatus: Codable, Sendable, Equatable {
  public let version: Int
  public let tmuxAvailable: Bool
  /// One entry per server with remote access turned on; empty when it is off.
  /// Present only in a local `status` response.
  public let relays: [LocalRelayStatus]?

  public init(version: Int = 1, tmuxAvailable: Bool, relays: [LocalRelayStatus]? = nil) {
    self.version = version
    self.tmuxAvailable = tmuxAvailable
    self.relays = relays
  }

  enum CodingKeys: String, CodingKey {
    case version, relays
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
  /// `create` only: the absolute directory the shell starts in.
  public let cwd: String?
  /// `create` and `share`: whether paired devices may reach the session.
  public let shared: Bool?
  /// `share`: keep the session from every paired device.
  public let keepPrivate: Bool?
  /// `share`: whether paired devices with control may type.
  public let remoteTyping: Bool?
  /// `access`: one paired device's policy to store.
  public let access: LocalDeviceAccess?
  /// `guest`: an invitation to record.
  public let guest: LocalGuestInvite?
  /// `guest`: the invitation to forget.
  public let pairingID: String?
  /// `redeem`: the recipient's proof of the invitation key.
  public let proof: Data?
  /// `input`: the terminal's own answer to a query in the output (such as
  /// its size or colors), not typing. It never moves the session's grid.
  public let automatic: Bool?
  /// `attach`: the renderer keeps its own scrollback. Earlier output arrives
  /// first, above the live screen, and tmux stays on the normal screen so new
  /// output scrolls into that scrollback.
  public let history: Bool?
  /// `list` and `attach` from the Mac's relay endpoint only.
  public let peer: LocalRemotePeer?

  public init(
    version: Int = 1, id: String = UUID().uuidString.lowercased(), operation: LocalAgentOperation,
    sessionID: String? = nil, name: String? = nil, columns: Int? = nil, rows: Int? = nil,
    mode: LocalAttachmentMode? = nil, data: Data? = nil, cwd: String? = nil,
    shared: Bool? = nil, keepPrivate: Bool? = nil, remoteTyping: Bool? = nil,
    access: LocalDeviceAccess? = nil, guest: LocalGuestInvite? = nil, pairingID: String? = nil,
    proof: Data? = nil, automatic: Bool? = nil, history: Bool? = nil, peer: LocalRemotePeer? = nil
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
    self.cwd = cwd
    self.shared = shared
    self.keepPrivate = keepPrivate
    self.remoteTyping = remoteTyping
    self.access = access
    self.guest = guest
    self.pairingID = pairingID
    self.proof = proof
    self.automatic = automatic
    self.history = history
    self.peer = peer
  }

  enum CodingKeys: String, CodingKey {
    case version, id, operation, name, columns, rows, mode, data, cwd, shared, access, guest, proof,
      automatic, history, peer
    case pairingID = "pairing_id"
    case sessionID = "session_id"
    case keepPrivate = "keep_private"
    case remoteTyping = "remote_typing"
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
  /// `access` replies: every stored device policy.
  public let accesses: [LocalDeviceAccess]?
  /// `guest` replies: every invitation, without keys.
  public let guests: [LocalGuestInvite]?

  public init(
    version: Int = 1, id: String? = nil, kind: LocalFrameKind, ok: Bool? = nil,
    error: LocalAgentErrorCode? = nil, status: LocalAgentStatus? = nil,
    sessions: [LocalSessionInfo]? = nil, session: LocalSessionInfo? = nil,
    mode: LocalAttachmentMode? = nil, data: Data? = nil, accesses: [LocalDeviceAccess]? = nil,
    guests: [LocalGuestInvite]? = nil
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
    self.accesses = accesses
    self.guests = guests
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
