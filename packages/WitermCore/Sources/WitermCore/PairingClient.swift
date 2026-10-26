import Foundation

public actor PairingClient {
  private struct Challenge: Decodable {
    let challengeID: String
    let nonce: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
      case nonce
      case challengeID = "challenge_id"
      case expiresAt = "expires_at"
    }
  }
  private struct Registration: Decodable {
    let device: PairedDevice
    let accessToken: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
      case device
      case accessToken = "access_token"
      case expiresAt = "expires_at"
    }
  }
  private struct CreatedPairing: Decodable {
    let pairing: DevicePairing
    let secret: String
  }
  private struct GrantList: Decodable { let grants: [DeviceGrant] }
  private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
  }
  private struct Empty: Encodable {}

  private let server: URL
  private let name: String
  private let platform: DevicePlatform
  private let identity: PairingIdentity
  private let store: any PairingSecureStore
  private let transport: any PairingTransport
  private let ledgerAccount: String
  private var ledger: PairingTrustLedger
  /// Several clients in one process may share a ledger, such as an iOS
  /// pairing sheet and the device list for the same server. Each update
  /// rereads the stored ledger, so serializing read-modify-write keeps one
  /// client from overwriting another's grants or local revocations. The Mac
  /// helper only reads the ledger; the app process is its only writer.
  private static let ledgerWrite = NSLock()
  private var registration: Registration?

  public init(serverAddress: String, deviceName: String, platform: DevicePlatform) throws {
    try self.init(
      serverAddress: serverAddress, deviceName: deviceName, platform: platform,
      store: KeychainPairingStore(), transport: URLSessionPairingTransport())
  }

  init(
    serverAddress: String, deviceName: String, platform: DevicePlatform,
    store: any PairingSecureStore, transport: any PairingTransport
  ) throws {
    server = try PairingServerAddress.normalized(serverAddress)
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.unicodeScalars.count <= 64,
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw PairingClientError.invalidDeviceName
    }
    self.name = name
    self.platform = platform
    self.store = store
    self.transport = transport
    // A malicious origin cannot relay another server's challenge for a
    // shared key: each normalized server gets an independent identity.
    identity = try PairingIdentity(
      store: store, account: PairingIdentity.account(server: server.absoluteString))
    ledgerAccount = PairingTrustLedger.account(
      server: server.absoluteString, publicKey: identity.publicKey)
    do {
      if let bytes = try store.read(account: ledgerAccount) {
        ledger = try Self.decoder().decode(PairingTrustLedger.self, from: bytes)
      } else {
        ledger = PairingTrustLedger()
      }
    } catch { throw PairingClientError.identityUnavailable }
  }

  public func register() async throws -> PairedDevice {
    try await authenticate(force: false).device
  }

  public func relayCredentials(forceRefresh: Bool = false) async throws -> RelayCredentials {
    let session = try await authenticate(force: forceRefresh)
    return RelayCredentials(
      server: server, device: session.device,
      accessToken: session.accessToken, expiresAt: session.expiresAt)
  }

  public func trustedRelayGrant(id: String) async throws -> DeviceGrant {
    guard PairingEncoding.canonicalID(id) == id else { throw RelayError.untrusted }
    let previous = ledger.grants[id]
    try reloadLedger()
    guard let grant = ledger.grants[id] else {
      if let previous, ledger.revokedPairings.contains(previous.pairingID) {
        throw RelayError.revoked
      }
      throw RelayError.untrusted
    }
    guard !ledger.revokedPairings.contains(grant.pairingID) else { throw RelayError.revoked }
    let own = platform == .macos ? grant.host : grant.client
    guard own.platform == platform, own.publicKey == identity.publicKey else {
      throw RelayError.untrusted
    }
    do {
      try PairingProof.validateGrant(
        grant, identity: own,
        pinnedHostKey: ledger.pinnedHosts[grant.pairingID])
    } catch { throw RelayError.untrusted }
    return grant
  }

  // Only a domain-separated relay proof for a freshly verified local grant can
  // reach the existing identity key. Raw key material never crosses this actor.
  func signRelayIdentity(grantID: String, role: RelayRole, handshakeHash: Data) async throws
    -> RelayIdentityProof
  {
    _ = try await trustedRelayGrant(id: grantID)
    guard (platform == .macos && role == .host) || (platform == .ios && role == .client) else {
      throw RelayError.untrusted
    }
    let message = try RelayIdentityProof.message(role: role, hash: handshakeHash)
    guard let signature = Data(base64Encoded: try identity.sign(message)) else {
      throw RelayError.untrusted
    }
    return RelayIdentityProof(role: role, signature: signature)
  }

  private func reloadLedger() throws {
    do {
      guard let bytes = try store.read(account: ledgerAccount) else { throw RelayError.untrusted }
      ledger = try Self.decoder().decode(PairingTrustLedger.self, from: bytes)
    } catch let error as RelayError { throw error } catch {
      throw PairingClientError.identityUnavailable
    }
  }

  public func createPairing() async throws -> PairingInvitation {
    guard platform == .macos else { throw PairingClientError.api(code: "forbidden") }
    let bytes = try await authorized(
      method: "POST", path: "v1/pairings", body: Self.encode(Empty()), expected: 201)
    let created: CreatedPairing = try Self.decode(bytes)
    let me = try await authenticate(force: false).device
    try validate(created.pairing, me: me)
    guard created.pairing.status == .waiting,
      PairingEncoding.randomValue(created.secret) != nil
    else { throw PairingClientError.invalidResponse }
    return PairingInvitation.make(
      server: server.absoluteString, pairingID: created.pairing.id, hostKey: identity.publicKey,
      secret: created.secret)
  }

  public func join(_ invitation: PairingInvitation) async throws -> DevicePairing {
    guard platform == .ios else { throw PairingClientError.api(code: "forbidden") }
    guard invitation.serverAddress == server.absoluteString else {
      throw PairingClientError.serverMismatch
    }
    let bytes = try await authorized(
      method: "POST", path: "v1/pairings/\(invitation.pairingID)/join",
      body: Self.encode(["secret": invitation.secret]), expected: 200)
    let pairing: DevicePairing = try Self.decode(bytes)
    let me = try await authenticate(force: false).device
    guard pairing.id == invitation.pairingID,
      pairing.status == .pending || pairing.status == .approved
    else {
      throw PairingClientError.invalidProof
    }
    try validate(pairing, me: me, hostPin: invitation.hostPublicKey)
    try update { next in
      if let prior = next.pinnedHosts[pairing.id], prior != invitation.hostPublicKey {
        throw PairingClientError.invalidProof
      }
      next.pinnedHosts[pairing.id] = invitation.hostPublicKey
      try record(pairing, into: &next)
    }
    return pairing
  }

  public func pairing(id: String) async throws -> DevicePairing {
    guard PairingEncoding.canonicalID(id) == id else { throw PairingClientError.invalidInvitation }
    let bytes = try await authorized(
      method: "GET", path: "v1/pairings/\(id)", body: nil, expected: 200)
    let pairing: DevicePairing = try Self.decode(bytes)
    guard pairing.id == id else { throw PairingClientError.invalidProof }
    let me = try await authenticate(force: false).device
    // Another client may have revoked this pairing since this one last read.
    if try store.read(account: ledgerAccount) != nil { try reloadLedger() }
    try validate(pairing, me: me)
    try update { try record(pairing, into: &$0) }
    return pairing
  }

  public func approve(_ pairing: DevicePairing, permission: PairingPermission) async throws
    -> DevicePairing
  {
    guard platform == .macos, pairing.status == .pending || pairing.status == .approved,
      let client = pairing.client
    else { throw PairingClientError.invalidProof }
    let me = try await authenticate(force: false).device
    try validate(pairing, me: me)
    let message = PairingEncoding.approvalMessage(
      pairingID: pairing.id, hostKey: identity.publicKey, clientKey: client.publicKey,
      permission: permission)
    let signature = try identity.sign(message)
    let bytes = try await authorized(
      method: "POST", path: "v1/pairings/\(pairing.id)/approve",
      body: Self.encode(["permission": permission.rawValue, "approval_signature": signature]),
      expected: 200)
    let approved: DevicePairing = try Self.decode(bytes)
    // An idempotent response may retain an earlier valid signature. Compare
    // the signed identities/permission, then verify its proof below.
    guard approved.id == pairing.id, approved.client?.id == client.id,
      approved.client?.publicKey == client.publicKey,
      approved.status == .approved,
      approved.grant?.permission == permission
    else { throw PairingClientError.invalidProof }
    try validate(approved, me: me)
    try update { try record(approved, into: &$0) }
    return approved
  }

  public func reject(id: String) async throws -> DevicePairing {
    guard PairingEncoding.canonicalID(id) == id else { throw PairingClientError.invalidInvitation }
    let bytes = try await authorized(
      method: "POST", path: "v1/pairings/\(id)/reject", body: Self.encode(Empty()), expected: 200)
    let pairing: DevicePairing = try Self.decode(bytes)
    guard pairing.id == id, pairing.status == .rejected || pairing.status == .expired else {
      throw PairingClientError.invalidProof
    }
    let me = try await authenticate(force: false).device
    try validate(pairing, me: me)
    try update { next in
      try record(pairing, into: &next)
      next.pinnedHosts.removeValue(forKey: id)
    }
    return pairing
  }

  public func grants() async throws -> [DeviceGrant] {
    // A grant recorded while this request is in flight postdates its response.
    // Its absence from that response is not a server revocation.
    if try store.read(account: ledgerAccount) != nil { try reloadLedger() }
    let known = Set(ledger.grants.keys)
    let bytes = try await authorized(method: "GET", path: "v1/grants", body: nil, expected: 200)
    let result: GrantList = try Self.decode(bytes)
    guard result.grants.count <= 1000,
      Set(result.grants.map(\.id)).count == result.grants.count,
      Set(result.grants.map(\.pairingID)).count == result.grants.count
    else { throw PairingClientError.invalidResponse }
    let me = try await authenticate(force: false).device
    if try store.read(account: ledgerAccount) != nil { try reloadLedger() }
    for grant in result.grants {
      guard !ledger.revokedPairings.contains(grant.pairingID) else {
        throw PairingClientError.invalidProof
      }
      try PairingProof.validateGrant(
        grant, identity: me, pinnedHostKey: ledger.pinnedHosts[grant.pairingID])
    }
    let activeIDs = Set(result.grants.map(\.id))
    try update { next in
      for old in next.grants.values where known.contains(old.id) && !activeIDs.contains(old.id) {
        next.revokedPairings.insert(old.pairingID)
      }
      var current = next.grants.filter { !known.contains($0.key) }
      for grant in result.grants {
        // A denial recorded by another client since validation still wins.
        guard !next.revokedPairings.contains(grant.pairingID) else {
          throw PairingClientError.invalidProof
        }
        current[grant.id] = grant
      }
      next.grants = current
    }
    return result.grants
  }

  /// Pass the grant's pairing ID when it is known, so the local denial holds
  /// even if this ledger never recorded the grant.
  public func revoke(grantID: String, pairingID: String? = nil) async throws {
    guard PairingEncoding.canonicalID(grantID) == grantID,
      pairingID.map({ PairingEncoding.canonicalID($0) == $0 }) ?? true
    else {
      throw PairingClientError.invalidInvitation
    }
    try update { next in
      let removed = next.grants.removeValue(forKey: grantID)
      for id in Set([removed?.pairingID, pairingID].compactMap { $0 }) {
        next.revokedPairings.insert(id)
      }
    }
    // Revoke local trust before the network call. A failed DELETE is retryable,
    // but cannot keep accepting a device the user has already revoked here.
    _ = try await authorized(
      method: "DELETE", path: "v1/grants/\(grantID)", body: nil, expected: 204)
  }

  private func validate(_ pairing: DevicePairing, me: PairedDevice, hostPin: String? = nil) throws {
    guard PairingEncoding.canonicalID(pairing.id) == pairing.id else {
      throw PairingClientError.invalidProof
    }
    try PairingProof.validateDevice(pairing.host)
    guard pairing.host.platform == .macos else { throw PairingClientError.invalidProof }
    if let client = pairing.client {
      try PairingProof.validateDevice(client)
      guard client.platform == .ios, client.id != pairing.host.id,
        client.publicKey != pairing.host.publicKey
      else { throw PairingClientError.invalidProof }
    }
    if platform == .macos {
      guard pairing.host.id == me.id, pairing.host.publicKey == identity.publicKey else {
        throw PairingClientError.invalidProof
      }
    } else {
      guard pairing.client?.id == me.id, pairing.client?.publicKey == identity.publicKey else {
        throw PairingClientError.invalidProof
      }
      if let pin = hostPin ?? ledger.pinnedHosts[pairing.id] {
        guard pairing.host.publicKey == pin else { throw PairingClientError.invalidProof }
      } else {
        // Revocation drops the pin along with the trust it anchored. A revoked
        // pairing can still be read, but only in a state that grants nothing.
        guard ledger.revokedPairings.contains(pairing.id), pairing.grant == nil else {
          throw PairingClientError.invalidProof
        }
      }
    }
    switch pairing.status {
    case .waiting:
      guard pairing.client == nil, pairing.grant == nil else {
        throw PairingClientError.invalidProof
      }
    case .pending:
      guard pairing.client != nil, pairing.grant == nil else {
        throw PairingClientError.invalidProof
      }
    case .approved:
      guard let client = pairing.client else { throw PairingClientError.invalidProof }
      if let grant = pairing.grant {
        guard !ledger.revokedPairings.contains(pairing.id), grant.pairingID == pairing.id,
          grant.host.id == pairing.host.id, grant.host.publicKey == pairing.host.publicKey,
          grant.client.id == client.id, grant.client.publicKey == client.publicKey
        else { throw PairingClientError.invalidProof }
        try PairingProof.validateGrant(
          grant, identity: me, pinnedHostKey: hostPin ?? ledger.pinnedHosts[pairing.id])
      }
    case .rejected, .expired:
      guard pairing.grant == nil else { throw PairingClientError.invalidProof }
    }
  }

  private func record(_ pairing: DevicePairing, into next: inout PairingTrustLedger) throws {
    if let grant = pairing.grant {
      guard !next.revokedPairings.contains(pairing.id) else {
        throw PairingClientError.invalidProof
      }
      next.grants[grant.id] = grant
    } else if pairing.status == .approved || pairing.status == .rejected
      || pairing.status == .expired
    {
      for old in next.grants.values where old.pairingID == pairing.id {
        next.grants.removeValue(forKey: old.id)
      }
      if pairing.status == .approved { next.revokedPairings.insert(pairing.id) }
    }
  }

  /// Applies `change` to the latest stored ledger, never to this client's
  /// snapshot, so grants and pins recorded by another client survive. A
  /// change may add trust but cannot undo a stored denial.
  private func update(_ change: (inout PairingTrustLedger) throws -> Void) throws {
    Self.ledgerWrite.lock()
    defer { Self.ledgerWrite.unlock() }
    var next: PairingTrustLedger
    do {
      if let bytes = try store.read(account: ledgerAccount) {
        next = try Self.decoder().decode(PairingTrustLedger.self, from: bytes)
      } else {
        next = ledger
      }
    } catch { throw PairingClientError.identityUnavailable }
    let denied = next.revokedPairings
    try change(&next)
    next.revokedPairings.formUnion(denied)
    next.grants = next.grants.filter { !next.revokedPairings.contains($0.value.pairingID) }
    for pairingID in next.revokedPairings {
      next.pinnedHosts.removeValue(forKey: pairingID)
    }
    do { try store.write(Self.encode(next), account: ledgerAccount) } catch {
      throw PairingClientError.identityUnavailable
    }
    ledger = next
  }

  private func authenticate(force: Bool) async throws -> Registration {
    if !force, let registration, registration.expiresAt > Date().addingTimeInterval(5) {
      return registration
    }
    let challengeBytes = try await raw(
      method: "POST", path: "v1/auth/challenges",
      body: Self.encode(["public_key": identity.publicKey]))
    guard challengeBytes.1 == 201 else {
      throw Self.apiError(challengeBytes.0, status: challengeBytes.1)
    }
    let challenge: Challenge = try Self.decode(challengeBytes.0)
    guard PairingEncoding.canonicalID(challenge.challengeID) == challenge.challengeID,
      PairingEncoding.randomValue(challenge.nonce) != nil, challenge.expiresAt > Date()
    else { throw PairingClientError.invalidResponse }
    let message = PairingEncoding.registrationMessage(
      challengeID: challenge.challengeID, nonce: challenge.nonce, name: name, platform: platform)
    let body = try Self.encode([
      "challenge_id": challenge.challengeID, "name": name, "platform": platform.rawValue,
      "signature": identity.sign(message),
    ])
    let result = try await raw(method: "POST", path: "v1/devices", body: body)
    guard result.1 == 200 else { throw Self.apiError(result.0, status: result.1) }
    let authenticated: Registration = try Self.decode(result.0)
    try PairingProof.validateDevice(authenticated.device)
    guard authenticated.device.publicKey == identity.publicKey,
      authenticated.device.platform == platform,
      PairingEncoding.randomValue(authenticated.accessToken) != nil,
      authenticated.expiresAt > Date()
    else { throw PairingClientError.invalidProof }
    registration = authenticated
    return authenticated
  }

  private func authorized(method: String, path: String, body: Data?, expected: Int) async throws
    -> Data
  {
    var session = try await authenticate(force: false)
    for attempt in 0...1 {
      let result = try await raw(method: method, path: path, body: body, token: session.accessToken)
      if result.1 == expected { return result.0 }
      if result.1 == 401 && attempt == 0 {
        registration = nil
        session = try await authenticate(force: true)
        continue
      }
      throw Self.apiError(result.0, status: result.1)
    }
    throw PairingClientError.api(code: "unauthorized")
  }

  private func raw(method: String, path: String, body: Data?, token: String? = nil) async throws
    -> (Data, Int)
  {
    try Task.checkCancellation()
    var request = URLRequest(url: server.appendingPathComponent(path))
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let result = try await transport.send(request)
    try Task.checkCancellation()
    return result
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func decode<T: Decodable>(_ data: Data) throws -> T {
    do { return try decoder().decode(T.self, from: data) } catch {
      throw PairingClientError.invalidResponse
    }
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  private static func apiError(_ data: Data, status: Int) -> PairingClientError {
    if let envelope = try? decoder().decode(ErrorEnvelope.self, from: data),
      [
        "invalid_request", "unauthorized", "forbidden", "pairing_unavailable", "not_found",
        "conflict", "rate_limited", "unavailable",
      ].contains(envelope.error.code)
    {
      return .api(code: envelope.error.code)
    }
    if status == 401 { return .api(code: "unauthorized") }
    if status == 429 { return .api(code: "rate_limited") }
    if status >= 500 { return .api(code: "unavailable") }
    return .invalidResponse
  }
}
