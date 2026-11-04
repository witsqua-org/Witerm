import Foundation

public enum LocalAgentOperation: String, Codable, Sendable {
  case status, list, create, close, attach, input, resize, detach, share, rename, access
  /// Local only: this Mac's invitations to single sessions.
  case guest
  /// From the relay endpoint: a recipient proving it holds an invitation's key.
  case redeem
  /// Relay only, never sent to the local service: a paired device
  /// acknowledging terminal frames on a flow-controlled attachment. Never
  /// answered.
  case ack
}

/// End-to-end flow control on relayed attachments (relay-v1 `flow`). The
/// device acknowledges the terminal frames it has handed to its renderer, and
/// the Mac keeps what is unacknowledged within a window that fits the relay's
/// per-leg queue, so a slow device slows its output instead of overflowing
/// the relay.
public enum RelayFlowControl {
  /// The version a device advertises in `attach` and the Mac confirms.
  public static let version = 1
  /// Unacknowledged terminal frames (output and geometry) the Mac may have
  /// sent. The relay queues 16 messages per leg; the rest is room for replies.
  public static let windowRecords = 8
  /// Their encrypted WebSocket message bytes. The relay queues 256 KiB per leg.
  public static let windowBytes = 128 * 1024
  /// Output bytes in one coalesced record (8 KiB without flow control).
  /// Base64 and JSON keep it near 22 KB, under the 49,152-byte record limit.
  public static let recordData = 16 * 1024
  /// How long the Mac waits for an acknowledgement while output is unacknowledged.
  public static let stallSeconds = 45
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
  /// Present only in a `list` response for a device paired with this Mac (not
  /// an invitation's guest): the others who can type here right now, so it can
  /// say where typing is. Absent from older services.
  public let writers: [LocalWriterInfo]?
  /// Present only in a `list` response for a device paired with this Mac (not
  /// an invitation's guest): every device attached to this session now, each
  /// once, the requesting device included, so it can count and list them.
  /// Names only. Absent from older services.
  public let attached: [LocalConnectedDevice]?

  public init(
    id: String, name: String, createdAt: Date, columns: Int, rows: Int,
    sharing: LocalSessionSharing? = nil, access: LocalAttachmentMode? = nil,
    writers: [LocalWriterInfo]? = nil, attached: [LocalConnectedDevice]? = nil
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.columns = columns
    self.rows = rows
    self.sharing = sharing
    self.access = access
    self.writers = writers
    self.attached = attached
  }

  /// The same session without local-only details.
  public var withoutSharing: LocalSessionInfo {
    LocalSessionInfo(id: id, name: name, createdAt: createdAt, columns: columns, rows: rows)
  }

  /// The same session as a paired device sees it.
  public func forPeer(
    access: LocalAttachmentMode, writers: [LocalWriterInfo]? = nil, attached: [LocalConnectedDevice]? = nil
  ) -> LocalSessionInfo {
    LocalSessionInfo(id: id, name: name, createdAt: createdAt, columns: columns, rows: rows, access: access,
                     writers: writers, attached: attached)
  }

  /// The same session limited to watching, keeping who can type and who is attached.
  public var watchOnly: LocalSessionInfo { forPeer(access: .view, writers: writers, attached: attached) }

  enum CodingKeys: String, CodingKey {
    case id, name, columns, rows, sharing, access, writers, attached
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
  /// Sessions this device may reach besides shared ones. Ignored when
  /// `scope` is `.all`; empty in policies stored before it existed.
  public let sessionIDs: [String]

  public var id: String { deviceID }

  public init(
    deviceID: String, scope: LocalSessionScope, permission: LocalAttachmentMode, coTyping: Bool = true,
    sessionIDs: [String] = []
  ) {
    self.deviceID = deviceID
    self.scope = scope
    self.permission = permission
    self.coTyping = coTyping
    self.sessionIDs = sessionIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    scope = try container.decode(LocalSessionScope.self, forKey: .scope)
    permission = try container.decode(LocalAttachmentMode.self, forKey: .permission)
    coTyping = try container.decode(Bool.self, forKey: .coTyping)
    sessionIDs = try container.decodeIfPresent([String].self, forKey: .sessionIDs) ?? []
  }

  /// The same policy reaching a different set of listed sessions.
  public func reaching(_ scope: LocalSessionScope, sessions: [String]) -> LocalDeviceAccess {
    LocalDeviceAccess(deviceID: deviceID, scope: scope, permission: permission, coTyping: coTyping, sessionIDs: sessions)
  }

  /// Whether this policy alone, without sharing, reaches the session.
  public func lists(_ sessionID: String) -> Bool { scope == .all || sessionIDs.contains(sessionID) }

  /// A paired device without an entry, such as one paired before this Mac
  /// kept a policy: shared sessions only, up to its grant, typing alongside.
  public static func `default`(for deviceID: String) -> LocalDeviceAccess {
    LocalDeviceAccess(deviceID: deviceID, scope: .shared, permission: .control)
  }

  enum CodingKeys: String, CodingKey {
    case scope, permission
    case deviceID = "device_id"
    case coTyping = "co_typing"
    case sessionIDs = "session_ids"
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

/// Someone else who can type in a session, as a paired device sees it: only
/// a name, never their keys or pairing.
public struct LocalWriterInfo: Codable, Sendable, Equatable {
  /// The other paired device's name; nil for this Mac itself (its app, a
  /// second window, or the `witerm` command).
  public let name: String?

  public init(name: String?) { self.name = name }
}

/// A device attached to a session, as a paired device sees it (`attached`):
/// a name, never keys or pairings. This Mac (its app, any window, or the
/// `witerm` command) is one entry without a name; each paired device is one
/// entry however many attachments it has.
public struct LocalConnectedDevice: Codable, Sendable, Equatable {
  /// The paired device's name; nil for this Mac itself.
  public let name: String?
  /// `control` when any of its attachments may type, otherwise `view`.
  public let mode: LocalAttachmentMode
  /// The session's grid is this device's: it typed last, or attached first
  /// to type (local-agent-v1, Grid owner). At most one entry; none once the
  /// grid's owner has gone, since the grid then stays as it was.
  public let gridOwner: Bool
  /// The device the list is for.
  public let thisDevice: Bool

  public init(name: String?, mode: LocalAttachmentMode, gridOwner: Bool = false, thisDevice: Bool = false) {
    self.name = name
    self.mode = mode
    self.gridOwner = gridOwner
    self.thisDevice = thisDevice
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    mode = try container.decode(LocalAttachmentMode.self, forKey: .mode)
    gridOwner = try container.decodeIfPresent(Bool.self, forKey: .gridOwner) ?? false
    thisDevice = try container.decodeIfPresent(Bool.self, forKey: .thisDevice) ?? false
  }

  /// False flags are left out, as in the shared fixture.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encode(mode, forKey: .mode)
    if gridOwner { try container.encode(true, forKey: .gridOwner) }
    if thisDevice { try container.encode(true, forKey: .thisDevice) }
  }

  enum CodingKeys: String, CodingKey {
    case name, mode
    case gridOwner = "grid_owner"
    case thisDevice = "this_device"
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
  /// Relay `attach` only: the flow-control version this device speaks
  /// (`RelayFlowControl.version`). Never forwarded to the local service.
  public let flow: Int?
  /// Relay `ack` only: how many terminal frames (output and geometry) after
  /// the attach response this device has handed to its renderer, in total.
  public let consumed: Int?

  public init(
    version: Int = 1, id: String = UUID().uuidString.lowercased(), operation: LocalAgentOperation,
    sessionID: String? = nil, name: String? = nil, columns: Int? = nil, rows: Int? = nil,
    mode: LocalAttachmentMode? = nil, data: Data? = nil, cwd: String? = nil,
    shared: Bool? = nil, keepPrivate: Bool? = nil, remoteTyping: Bool? = nil,
    access: LocalDeviceAccess? = nil, guest: LocalGuestInvite? = nil, pairingID: String? = nil,
    proof: Data? = nil, automatic: Bool? = nil, history: Bool? = nil, peer: LocalRemotePeer? = nil,
    flow: Int? = nil, consumed: Int? = nil
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
    self.flow = flow
    self.consumed = consumed
  }

  enum CodingKeys: String, CodingKey {
    case version, id, operation, name, columns, rows, mode, data, cwd, shared, access, guest, proof,
      automatic, history, peer, flow, consumed
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
  /// Relay `attach` replies only: the flow-control version the Mac enforces
  /// on this attachment. Absent when it doesn't (an older Mac, or a device
  /// that didn't ask).
  public let flow: Int?

  public init(
    version: Int = 1, id: String? = nil, kind: LocalFrameKind, ok: Bool? = nil,
    error: LocalAgentErrorCode? = nil, status: LocalAgentStatus? = nil,
    sessions: [LocalSessionInfo]? = nil, session: LocalSessionInfo? = nil,
    mode: LocalAttachmentMode? = nil, data: Data? = nil, accesses: [LocalDeviceAccess]? = nil,
    guests: [LocalGuestInvite]? = nil, flow: Int? = nil
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
    self.flow = flow
  }
}

public enum LocalAgentClientError: Error, Equatable, Sendable {
  case unavailable, invalidResponse, unsafeSocket, backpressure
  case rejected(LocalAgentErrorCode)
}

// One lazily selected consumer route, with backpressure counted in bytes.
// Events wait in one ordered queue until the consumer takes them; legacy
// output ignores geometry without queueing it. Each selected stream supports
// one iterator. A producer never drops an event for being early or fast: it
// waits for room (`waitForRoom` on a reader thread, `room()` in a task) while
// more than `byteLimit` is unread, so a slow renderer slows the socket
// instead of losing or reordering output. Only a consumer that takes nothing
// for `stallLimit` is given up on, and `yield` refuses an event past
// `hardLimit`, which a waiting producer never reaches.
final class LocalTerminalStreams: @unchecked Sendable {
  enum YieldResult { case enqueued, dropped, terminated }
  private enum Route { case undecided, events, output }
  /// Unread bytes before producers wait.
  let byteLimit: Int
  /// A producer that doesn't wait is refused here.
  let hardLimit: Int
  /// How long a producer waits while the consumer takes nothing.
  let stallLimit: Duration

  private let condition = NSCondition()
  private let conflictError: Error
  private var route: Route = .undecided
  private var queue: [LocalTerminalEvent] = []
  private var head = 0
  private var queuedBytes = 0
  private var completed = false
  private var terminalError: Error?
  private var consumerGone = false
  private var notifiedTermination = false
  private var waiter: CheckedContinuation<LocalTerminalEvent?, Error>?
  private var roomWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  private var lastProgress = ContinuousClock.now
  /// The iterator taking events; a second one is refused.
  private var activeConsumer: UUID?
  private var termination: (@Sendable () -> Void)?
  /// Events handed to the consumer (or, on the output route, geometry it
  /// never needed), in total. A relayed attachment acknowledges these.
  private var consumedEvents = 0
  private var consumption: (@Sendable () -> Void)?

  init(conflictError: Error, byteLimit: Int = 1 << 20, stallLimit: Duration = .seconds(30)) {
    self.conflictError = conflictError
    self.byteLimit = byteLimit
    self.hardLimit = byteLimit * 8
    self.stallLimit = stallLimit
  }

  func onTermination(_ callback: @escaping @Sendable () -> Void) {
    condition.withLock { termination = callback }
  }

  /// Called (outside the lock) each time `consumed` grows.
  func onConsumption(_ callback: @escaping @Sendable () -> Void) {
    condition.withLock { consumption = callback }
  }

  /// How many yielded events the consumer has taken, or no longer needs.
  var consumed: Int { condition.withLock { consumedEvents } }

  /// Must hold the lock. Returns the callback to run once it's released.
  private func consume(_ count: Int) -> (@Sendable () -> Void)? {
    guard count > 0 else { return nil }
    consumedEvents += count
    return consumption
  }

  /// What an event costs against the limits: its bytes plus framing.
  private static func cost(_ event: LocalTerminalEvent) -> Int {
    switch event {
    case .output(let data): data.count + 64
    case .geometry: 256
    }
  }

  /// Ends the consumer when the iterator that took events goes away, as an
  /// abandoned stream's termination did.
  private final class ConsumerToken: @unchecked Sendable {
    let id = UUID()
    weak var streams: LocalTerminalStreams?
    init(_ streams: LocalTerminalStreams) { self.streams = streams }
    deinit { streams?.released(id) }
  }

  func events() -> AsyncThrowingStream<LocalTerminalEvent, Error> {
    condition.lock()
    defer { condition.unlock() }
    if route == .output { return AsyncThrowingStream { $0.finish(throwing: conflictError) } }
    route = .events
    let token = ConsumerToken(self)
    return AsyncThrowingStream<LocalTerminalEvent, Error>(unfolding: { [token] in
      guard let streams = token.streams else { return nil }
      return try await streams.next(token.id)
    })
  }

  func output() -> AsyncThrowingStream<Data, Error> {
    condition.lock()
    defer { condition.unlock() }
    if route == .events { return AsyncThrowingStream { $0.finish(throwing: conflictError) } }
    var skipped: (@Sendable () -> Void)?
    if route == .undecided {
      route = .output
      // Geometry waiting from before the choice isn't output.
      let waiting = queue.count - head
      queue = queue[head...].filter { if case .output = $0 { true } else { false } }
      head = 0
      queuedBytes = queue.reduce(0) { $0 + Self.cost($1) }
      skipped = consume(waiting - queue.count)
    }
    defer { if let skipped { DispatchQueue.global().async(execute: skipped) } }
    let token = ConsumerToken(self)
    return AsyncThrowingStream<Data, Error>(unfolding: { [token] in
      guard let streams = token.streams else { return nil }
      while let event = try await streams.next(token.id) {
        if case .output(let data) = event { return data }
      }
      return nil
    })
  }

  private func released(_ id: UUID) {
    let mine = condition.withLock { activeConsumer == id }
    if mine { consumerEnded() }
  }

  func yield(_ event: LocalTerminalEvent) -> YieldResult {
    condition.lock()
    if completed || consumerGone {
      condition.unlock()
      return .terminated
    }
    if route == .output, case .geometry = event {
      let consumed = consume(1)
      condition.unlock()
      consumed?()
      return .enqueued
    }
    if let waiter {
      // Nothing is queued while a consumer waits.
      self.waiter = nil
      lastProgress = .now
      let consumed = consume(1)
      condition.unlock()
      waiter.resume(returning: event)
      consumed?()
      return .enqueued
    }
    let cost = Self.cost(event)
    guard queuedBytes + cost <= hardLimit else {
      condition.unlock()
      return .dropped
    }
    queue.append(event)
    queuedBytes += cost
    condition.unlock()
    return .enqueued
  }

  /// Blocks a reader thread until there's room. False when the consumer
  /// took nothing for `stallLimit`; true once there's room, or once the
  /// streams ended (the next `yield` says so).
  func waitForRoom() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    while queuedBytes > byteLimit, !completed, !consumerGone {
      let idle = ContinuousClock.now - lastProgress
      if idle >= stallLimit { return false }
      let remaining = stallLimit - idle
      let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
      _ = condition.wait(until: Date().addingTimeInterval(min(seconds, 1)))
    }
    return true
  }

  /// The same for a task: suspends until there's room. False when the
  /// consumer took nothing for `stallLimit`.
  func room() async -> Bool {
    let id = UUID()
    let deadline = Task { [weak self] in
      guard let limit = self?.stallLimit else { return }
      try? await Task.sleep(for: limit)
      self?.resumeRoomWaiter(id, false)
    }
    defer { deadline.cancel() }
    return await withCheckedContinuation { continuation in
      condition.lock()
      guard queuedBytes > byteLimit, !completed, !consumerGone else {
        condition.unlock()
        continuation.resume(returning: true)
        return
      }
      roomWaiters[id] = continuation
      condition.unlock()
    }
  }

  private func resumeRoomWaiter(_ id: UUID, _ value: Bool) {
    let continuation = condition.withLock { roomWaiters.removeValue(forKey: id) }
    continuation?.resume(returning: value)
  }

  /// The consumer's next event, or nil at the end.
  private func next(_ consumer: UUID) async throws -> LocalTerminalEvent? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LocalTerminalEvent?, Error>) in
        condition.lock()
        if activeConsumer == nil { activeConsumer = consumer }
        guard activeConsumer == consumer else {
          condition.unlock()
          continuation.resume(throwing: conflictError)
          return
        }
        if Task.isCancelled || consumerGone {
          consumerGone = true
          condition.unlock()
          continuation.resume(returning: nil)
          notifyTermination()
          return
        }
        if head < queue.count {
          let event = queue[head]
          head += 1
          queuedBytes -= Self.cost(event)
          if head > 256, head * 2 > queue.count {
            queue.removeFirst(head)
            head = 0
          }
          lastProgress = .now
          let released = queuedBytes <= byteLimit ? takeRoomWaiters() : []
          let consumed = consume(1)
          condition.broadcast()
          condition.unlock()
          released.forEach { $0.resume(returning: true) }
          continuation.resume(returning: event)
          consumed?()
          return
        }
        if completed {
          let error = terminalError
          condition.unlock()
          if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
          return
        }
        guard waiter == nil else {
          condition.unlock()
          continuation.resume(throwing: conflictError)
          return
        }
        waiter = continuation
        lastProgress = .now
        let released = takeRoomWaiters()
        condition.broadcast()
        condition.unlock()
        released.forEach { $0.resume(returning: true) }
      }
    } onCancel: {
      consumerEnded()
    }
  }

  /// Must hold the lock.
  private func takeRoomWaiters() -> [CheckedContinuation<Bool, Never>] {
    let all = Array(roomWaiters.values)
    roomWaiters.removeAll()
    return all
  }

  func finish(throwing error: Error?) {
    condition.lock()
    guard !completed else {
      condition.unlock()
      return
    }
    completed = true
    terminalError = error
    // What's queued is still delivered; the end comes after it.
    let waiting = head < queue.count ? nil : waiter
    if waiting != nil { waiter = nil }
    let released = takeRoomWaiters()
    let selected = route != .undecided
    condition.broadcast()
    condition.unlock()
    released.forEach { $0.resume(returning: true) }
    if let waiting {
      if let error { waiting.resume(throwing: error) } else { waiting.resume(returning: nil) }
    }
    if selected { notifyTermination() }
  }

  /// The consumer stopped (its task was cancelled): nothing more is queued.
  private func consumerEnded() {
    condition.lock()
    consumerGone = true
    let waiting = waiter
    waiter = nil
    queue.removeAll()
    head = 0
    queuedBytes = 0
    let released = takeRoomWaiters()
    condition.broadcast()
    condition.unlock()
    released.forEach { $0.resume(returning: true) }
    waiting?.resume(returning: nil)
    notifyTermination()
  }

  private func notifyTermination() {
    let callback: (@Sendable () -> Void)? = condition.withLock {
      guard !notifiedTermination else { return nil }
      notifiedTermination = true
      return termination
    }
    callback?()
  }
}
