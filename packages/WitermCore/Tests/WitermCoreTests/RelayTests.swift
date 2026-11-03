import CryptoKit
import Foundation
import XCTest

@testable import WitermCore

private final class RelayTestStore: PairingSecureStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var ledgerReadHook: (remaining: Int, run: @Sendable () -> Void)?
  /// Runs `hook` during the given ledger read, after its value is captured.
  func onLedgerRead(_ count: Int, _ hook: @escaping @Sendable () -> Void) {
    lock.withLock { ledgerReadHook = (count, hook) }
  }
  func read(account: String) throws -> Data? {
    let (value, hook) = lock.withLock { () -> (Data?, (@Sendable () -> Void)?) in
      guard account.hasPrefix("trust-"), let pending = ledgerReadHook else { return (values[account], nil) }
      ledgerReadHook = pending.remaining > 1 ? (pending.remaining - 1, pending.run) : nil
      return (values[account], pending.remaining > 1 ? nil : pending.run)
    }
    hook?()
    return value
  }
  func create(_ data: Data, account: String) throws -> Bool {
    lock.withLock {
      if values[account] != nil { return false }
      values[account] = data
      return true
    }
  }
  func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
  func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private struct RelayTestAuth: PairingTransport {
  let device: PairedDevice
  let staleGrant: DeviceGrant
  let failDelete: Bool
  var grants: (@Sendable () async -> [DeviceGrant])? = nil
  var pairing: DevicePairing? = nil
  func send(_ request: URLRequest) async throws -> (Data, Int) {
    let token = Data(repeating: 9, count: 32).base64EncodedString().replacingOccurrences(
      of: "=", with: "")
    switch request.url!.path {
    case "/v1/auth/challenges":
      return (
        try JSONSerialization.data(withJSONObject: [
          "challenge_id": "99999999-9999-4999-8999-999999999999",
          "nonce": token,
          "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
        ]), 201
      )
    case "/v1/devices":
      struct Registration: Encodable {
        let device: PairedDevice
        let access_token: String
        let expires_at: Date
      }
      return (
        try RemoteWire.encoder().encode(
          Registration(
            device: device, access_token: token, expires_at: Date().addingTimeInterval(3600))), 200
      )
    case let path where path.hasPrefix("/v1/pairings/") && pairing != nil:
      return (try RemoteWire.encoder().encode(pairing), 200)
    case "/v1/grants":
      let listed = await grants?() ?? [staleGrant]
      return (try RemoteWire.encoder().encode(["grants": listed]), 200)
    default:
      if failDelete { throw RelayError.transport }
      return (Data(), 204)
    }
  }
}

private struct RelayTestPeers {
  let server = URL(string: "https://relay.example")!
  let hostKey: Curve25519.Signing.PrivateKey
  let clientKey: Curve25519.Signing.PrivateKey
  let grant: DeviceGrant
  let hostStore: RelayTestStore
  let clientStore: RelayTestStore
  let host: PairingClient
  let client: PairingClient
  let hostCredentials: RelayCredentials
  let clientCredentials: RelayCredentials
  let tunnel = "33333333-3333-4333-8333-333333333333"

  init(permission: PairingPermission = .control, failDelete: Bool = false) throws {
    // TEST ONLY identities, never read or written to the user's Keychain.
    hostKey = try .init(rawRepresentation: Data(repeating: 1, count: 32))
    clientKey = try .init(rawRepresentation: Data(repeating: 2, count: 32))
    let hostDevice = PairedDevice(
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "Host", platform: .macos,
      publicKey: hostKey.publicKey.rawRepresentation.base64EncodedString())
    let clientDevice = PairedDevice(
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", name: "Client", platform: .ios,
      publicKey: clientKey.publicKey.rawRepresentation.base64EncodedString())
    let pairingID = "11111111-1111-4111-8111-111111111111"
    let message = PairingEncoding.approvalMessage(
      pairingID: pairingID, hostKey: hostDevice.publicKey,
      clientKey: clientDevice.publicKey, permission: permission)
    grant = DeviceGrant(
      id: "22222222-2222-4222-8222-222222222222", pairingID: pairingID,
      host: hostDevice, client: clientDevice, permission: permission,
      approvalSignature: try hostKey.signature(for: message).base64EncodedString(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    hostStore = RelayTestStore()
    clientStore = RelayTestStore()
    try hostStore.write(
      hostKey.rawRepresentation, account: PairingIdentity.account(server: server.absoluteString))
    try clientStore.write(
      clientKey.rawRepresentation, account: PairingIdentity.account(server: server.absoluteString))
    let ledger = PairingTrustLedger(
      pinnedHosts: [pairingID: hostDevice.publicKey], grants: [grant.id: grant])
    for (store, key) in [(hostStore, hostDevice.publicKey), (clientStore, clientDevice.publicKey)] {
      try store.write(
        RemoteWire.encoder().encode(ledger),
        account: PairingTrustLedger.account(server: server.absoluteString, publicKey: key))
    }
    host = try PairingClient(
      serverAddress: server.absoluteString, deviceName: "Host", platform: .macos,
      store: hostStore,
      transport: RelayTestAuth(device: hostDevice, staleGrant: grant, failDelete: failDelete))
    client = try PairingClient(
      serverAddress: server.absoluteString, deviceName: "Client", platform: .ios,
      store: clientStore,
      transport: RelayTestAuth(device: clientDevice, staleGrant: grant, failDelete: failDelete))
    let token = Data(repeating: 9, count: 32).base64EncodedString().replacingOccurrences(
      of: "=", with: "")
    hostCredentials = RelayCredentials(
      server: server, device: hostDevice, accessToken: token,
      expiresAt: Date().addingTimeInterval(3600))
    clientCredentials = RelayCredentials(
      server: server, device: clientDevice, accessToken: token,
      expiresAt: Date().addingTimeInterval(3600))
  }
  func ledger(client: Bool = true) throws -> PairingTrustLedger {
    let account = PairingTrustLedger.account(
      server: server.absoluteString,
      publicKey: client ? grant.client.publicKey : grant.host.publicKey)
    let data = try XCTUnwrap(try (client ? clientStore : hostStore).read(account: account))
    return try RemoteWire.decoder().decode(PairingTrustLedger.self, from: data)
  }
  func writeLedger(_ ledger: PairingTrustLedger, client: Bool = true) throws {
    try (client ? clientStore : hostStore).write(
      RemoteWire.encoder().encode(ledger),
      account: PairingTrustLedger.account(
        server: server.absoluteString,
        publicKey: client ? grant.client.publicKey : grant.host.publicKey))
  }
  /// Another client for the same identity and store, as the iOS pairing
  /// settings and device list each hold their own.
  func secondClient(
    grants: (@Sendable () async -> [DeviceGrant])? = nil, pairing: DevicePairing? = nil
  ) throws -> PairingClient {
    try PairingClient(
      serverAddress: server.absoluteString, deviceName: "Client", platform: .ios,
      store: clientStore,
      transport: RelayTestAuth(
        device: grant.client, staleGrant: grant, failDelete: true, grants: grants, pairing: pairing))
  }
  func revokeInStore(client: Bool = true) throws {
    let ledger = PairingTrustLedger(revokedPairings: [grant.pairingID])
    try (client ? clientStore : hostStore).write(
      RemoteWire.encoder().encode(ledger),
      account: PairingTrustLedger.account(
        server: server.absoluteString,
        publicKey: client ? grant.client.publicKey : grant.host.publicKey))
  }
  func channels() async throws -> (
    RelaySecureChannel, RelaySecureChannel, RelayTestSocket, RelayTestSocket
  ) {
    let (c, h) = RelayTestSocket.pair()
    async let clientChannel = RelaySecureChannel.establish(
      pairing: client, credentials: clientCredentials,
      grant: grant, tunnelID: tunnel, role: .client, socket: c)
    async let hostChannel = RelaySecureChannel.establish(
      pairing: host, credentials: hostCredentials,
      grant: grant, tunnelID: tunnel, role: .host, socket: h)
    return try await (clientChannel, hostChannel, c, h)
  }
}

private actor RelayTestMailbox {
  private var queue: [Data] = []
  private var receiver: CheckedContinuation<Data, Error>?
  private var blocked: [CheckedContinuation<Void, Error>] = []
  private var closed = false
  var pause = false
  func put(_ data: Data) async throws {
    guard !closed else { throw RelayError.transport }
    if pause { try await withCheckedThrowingContinuation { blocked.append($0) } }
    guard !closed else { throw RelayError.transport }
    if let receiver {
      self.receiver = nil
      receiver.resume(returning: data)
    } else {
      queue.append(data)
    }
  }
  func get() async throws -> Data {
    if !queue.isEmpty { return queue.removeFirst() }
    guard !closed else { throw RelayError.transport }
    return try await withCheckedThrowingContinuation { receiver = $0 }
  }
  func setPause() { pause = true }
  func isClosed() -> Bool { closed }
  func close() {
    closed = true
    receiver?.resume(throwing: RelayError.transport)
    receiver = nil
    for item in blocked { item.resume(throwing: RelayError.transport) }
    blocked.removeAll()
  }
}

private final class RelayTestSocket: RelaySocketIO, Sendable {
  let inbox: RelayTestMailbox
  let outbox: RelayTestMailbox
  init(inbox: RelayTestMailbox, outbox: RelayTestMailbox) {
    self.inbox = inbox
    self.outbox = outbox
  }
  static func pair() -> (RelayTestSocket, RelayTestSocket) {
    let a = RelayTestMailbox()
    let b = RelayTestMailbox()
    return (RelayTestSocket(inbox: a, outbox: b), RelayTestSocket(inbox: b, outbox: a))
  }
  func send(_ data: Data) async throws {
    try await withTaskCancellationHandler {
      try await outbox.put(data)
    } onCancel: {
      self.close()
    }
  }
  func receive() async throws -> Data {
    try await withTaskCancellationHandler {
      try await inbox.get()
    } onCancel: {
      self.close()
    }
  }
  func close() {
    Task {
      await inbox.close()
      await outbox.close()
    }
  }
}

private final class RelayTestCounters: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Int] = [:]
  func bump(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
  func count(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
}

private final class RelayTestPong: @unchecked Sendable {
  private let lock = NSLock()
  private var callback: (@Sendable (Error?) -> Void)?
  func install(_ callback: @escaping @Sendable (Error?) -> Void) {
    lock.withLock { self.callback = callback }
  }
  func complete() {
    let callback = lock.withLock { self.callback }
    callback?(nil)
  }
}

private final class RelayWeakReference<Object: AnyObject>: @unchecked Sendable {
  weak var value: Object?
  init(_ value: Object) { self.value = value }
}

final class RelayTests: XCTestCase {
  private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    try await relayDeadline(1) {
      while !(await condition()) { try await Task.sleep(for: .milliseconds(2)) }
    }
  }
  private func hex(_ value: String) -> Data {
    Data(
      stride(from: 0, to: value.count, by: 2).map { i in
        let a = value.index(value.startIndex, offsetBy: i)
        return UInt8(value[a..<value.index(a, offsetBy: 2)], radix: 16)!
      })
  }
  private func fixture(_ name: String = "noise-xx-reference.json") throws -> [String: Any] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/\(name)")))
        as? [String: Any])
  }
  private func handshakes(_ first: Data, _ second: Data? = nil) throws -> (
    RelayNoiseHandshake, RelayNoiseHandshake
  ) {
    var client = RelayNoiseHandshake(initiator: true, prologue: first)
    var host = RelayNoiseHandshake(initiator: false, prologue: second ?? first)
    XCTAssertEqual(try host.read(client.write()), Data())
    XCTAssertEqual(try client.read(host.write()), Data())
    XCTAssertEqual(try host.read(client.write()), Data())
    return (client, host)
  }

  func testCacophonyReferenceEveryMessageAndFinalHash() throws {
    let v = try fixture()
    func bytes(_ key: String) throws -> Data { hex(try XCTUnwrap(v[key] as? String)) }
    var client = try RelayNoiseHandshake(
      initiator: true, prologue: bytes("init_prologue"),
      staticKey: .init(rawRepresentation: bytes("init_static")),
      ephemeral: .init(rawRepresentation: bytes("init_ephemeral")))
    var host = try RelayNoiseHandshake(
      initiator: false, prologue: bytes("resp_prologue"),
      staticKey: .init(rawRepresentation: bytes("resp_static")),
      ephemeral: .init(rawRepresentation: bytes("resp_ephemeral")))
    let messages = try XCTUnwrap(v["messages"] as? [[String: String]])
    for index in 0..<3 {
      let payload = hex(messages[index]["payload"]!)
      let cipher =
        try index % 2 == 0 ? client.write(payload: payload) : host.write(payload: payload)
      XCTAssertEqual(cipher, hex(messages[index]["ciphertext"]!))
      let decoded = try index % 2 == 0 ? host.read(cipher) : client.read(cipher)
      XCTAssertEqual(decoded, payload)
    }
    XCTAssertEqual(client.hash, try bytes("handshake_hash"))
    XCTAssertEqual(client.hash, host.hash)
    var (clientSend, clientReceive) = try client.split()
    var (hostSend, hostReceive) = try host.split()
    for index in 3..<6 {
      let payload = hex(messages[index]["payload"]!)
      let cipher = try index % 2 == 0 ? clientSend.encrypt(payload) : hostSend.encrypt(payload)
      XCTAssertEqual(cipher, hex(messages[index]["ciphertext"]!))
      XCTAssertEqual(
        try index % 2 == 0 ? hostReceive.decrypt(cipher) : clientReceive.decrypt(cipher), payload)
    }
  }

  func testSharedRelayMetadataContractAndStrictControlFrames() throws {
    let fixture = try fixture("relay-metadata-v1.json")
    let ready = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["host_ready"]))
    XCTAssertNoThrow(try RelayMetadata.ready(ready))
    let offer = try RelayMetadata.offer(
      JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["host_offer"])))
    let create = try XCTUnwrap(fixture["create_request"] as? [String: String])
    let decodedRequest =
      try JSONSerialization.jsonObject(with: RelayMetadata.createRequest(grantID: offer.grantID))
      as? [String: String]
    XCTAssertEqual(decodedRequest, create)
    let tunnel = try RelayMetadata.createdTunnel(
      JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["create_response"])))
    XCTAssertEqual(offer.tunnelID, tunnel)
    XCTAssertThrowsError(
      try RelayMetadata.ready(Data("{\"type\":\"ready\",\"extra\":\"value\"}".utf8)))
    XCTAssertThrowsError(
      try RelayMetadata.offer(
        Data("{\"type\":\"offer\",\"tunnel_id\":\"bad\",\"grant_id\":\"bad\"}".utf8)))
    XCTAssertThrowsError(try RelayMetadata.createdTunnel(Data(repeating: 32, count: 4097)))
  }

  func testReplayReorderReflectionTamperAndNonceExhaustionFailClosed() throws {
    let (a, b) = try handshakes(Data("context".utf8))
    let (sender, clientReceiver) = try a.split()
    let (_, receiver) = try b.split()
    var send = sender
    let first = try send.encrypt(Data("one".utf8))
    let second = try send.encrypt(Data("two".utf8))
    var receive = receiver
    XCTAssertEqual(try receive.decrypt(first), Data("one".utf8))
    XCTAssertThrowsError(try receive.decrypt(first))
    XCTAssertThrowsError(try receive.decrypt(second))  // Poisoned after the first tag error.
    var reordered = receiver
    XCTAssertThrowsError(try reordered.decrypt(second))
    var reflected = clientReceiver
    XCTAssertThrowsError(try reflected.decrypt(first))
    var tampered = receiver
    var altered = first
    altered[altered.startIndex] ^= 1
    XCTAssertThrowsError(try tampered.decrypt(altered))
    var exhausted = RelayNoiseCipher(key: Data(repeating: 3, count: 32), nonce: UInt64.max - 1)
    _ = try exhausted.encrypt(Data())
    XCTAssertThrowsError(try exhausted.encrypt(Data()))
    var oversized = sender
    XCTAssertThrowsError(try oversized.encrypt(Data(repeating: 0, count: 49_153)))
    var truncated = receiver
    XCTAssertThrowsError(try truncated.decrypt(Data(repeating: 0, count: 15)))
  }

  func testX25519LowOrderAndMalformedHandshakeFailClosed() throws {
    for lowOrder in [Data(repeating: 0, count: 32), Data([1]) + Data(repeating: 0, count: 31)] {
      var host = RelayNoiseHandshake(initiator: false, prologue: Data())
      _ = try host.read(lowOrder)
      XCTAssertThrowsError(try host.write())
      XCTAssertThrowsError(try host.write())
      var client = RelayNoiseHandshake(initiator: true, prologue: Data())
      _ = try client.write()
      XCTAssertThrowsError(try client.read(lowOrder + Data(repeating: 0, count: 64)))
    }
    var host = RelayNoiseHandshake(initiator: false, prologue: Data())
    XCTAssertThrowsError(try host.read(Data(repeating: 0, count: 31)))
    XCTAssertThrowsError(try host.read(Data(repeating: 0, count: 32)))
    var early = RelayNoiseHandshake(initiator: true, prologue: Data())
    XCTAssertThrowsError(try early.split())
    XCTAssertThrowsError(try early.read(Data()))
  }

  func testContextBindsOriginTunnelGrantPairingPermissionAndDeviceKeys() throws {
    let peers = try RelayTestPeers()
    let original = try RelayContext.prologue(
      server: peers.server, tunnelID: peers.tunnel, grant: peers.grant)
    var contexts = [
      try RelayContext.prologue(
        server: URL(string: "https://other.example")!, tunnelID: peers.tunnel, grant: peers.grant),
      try RelayContext.prologue(
        server: peers.server, tunnelID: "44444444-4444-4444-8444-444444444444", grant: peers.grant),
    ]
    let view = try RelayTestPeers(permission: .view)
    contexts.append(
      try RelayContext.prologue(server: peers.server, tunnelID: peers.tunnel, grant: view.grant))
    let g = peers.grant
    let otherID = DeviceGrant(
      id: "44444444-4444-4444-8444-444444444444", pairingID: g.pairingID,
      host: g.host, client: g.client, permission: g.permission,
      approvalSignature: g.approvalSignature, createdAt: g.createdAt)
    contexts.append(
      try RelayContext.prologue(server: peers.server, tunnelID: peers.tunnel, grant: otherID))
    let changedPairing = "55555555-5555-4555-8555-555555555555"
    let changedMessage = PairingEncoding.approvalMessage(
      pairingID: changedPairing, hostKey: g.host.publicKey,
      clientKey: g.client.publicKey, permission: g.permission)
    let otherPairing = DeviceGrant(
      id: g.id, pairingID: changedPairing, host: g.host, client: g.client,
      permission: g.permission,
      approvalSignature: try peers.hostKey.signature(for: changedMessage).base64EncodedString(),
      createdAt: g.createdAt)
    contexts.append(
      try RelayContext.prologue(server: peers.server, tunnelID: peers.tunnel, grant: otherPairing))
    let renamedHostID = PairedDevice(
      id: "66666666-6666-4666-8666-666666666666", name: g.host.name,
      platform: .macos, publicKey: g.host.publicKey)
    let otherDevice = DeviceGrant(
      id: g.id, pairingID: g.pairingID, host: renamedHostID, client: g.client,
      permission: g.permission, approvalSignature: g.approvalSignature, createdAt: g.createdAt)
    contexts.append(
      try RelayContext.prologue(server: peers.server, tunnelID: peers.tunnel, grant: otherDevice))
    for context in contexts {
      var client = RelayNoiseHandshake(initiator: true, prologue: original)
      var host = RelayNoiseHandshake(initiator: false, prologue: context)
      _ = try host.read(client.write())
      XCTAssertThrowsError(try client.read(host.write()))
    }
    XCTAssertThrowsError(
      try RelayContext.prologue(
        server: URL(string: "http://remote.example")!, tunnelID: peers.tunnel, grant: g))
    XCTAssertThrowsError(
      try RelayContext.prologue(server: peers.server, tunnelID: "not-a-uuid", grant: g))
  }

  func testIdentityProofRejectsWrongRoleHashAndKey() async throws {
    let p = try RelayTestPeers()
    let hash = Data(repeating: 7, count: 32)
    let proof = try await p.client.signRelayIdentity(
      grantID: p.grant.id, role: .client, handshakeHash: hash)
    XCTAssertNoThrow(try proof.verify(expectedRole: .client, hash: hash, grant: p.grant))
    XCTAssertThrowsError(try proof.verify(expectedRole: .host, hash: hash, grant: p.grant))
    XCTAssertThrowsError(
      try proof.verify(expectedRole: .client, hash: Data(repeating: 8, count: 32), grant: p.grant))
    let forged = RelayIdentityProof(
      role: .client,
      signature: try p.hostKey.signature(for: RelayIdentityProof.message(role: .client, hash: hash))
    )
    XCTAssertThrowsError(try forged.verify(expectedRole: .client, hash: hash, grant: p.grant))
    do {
      _ = try await p.client.signRelayIdentity(
        grantID: p.grant.id, role: .host, handshakeHash: hash)
      XCTFail("wrong role signed")
    } catch { XCTAssertEqual(error as? RelayError, .untrusted) }
    do {
      _ = try await p.host.signRelayIdentity(
        grantID: p.grant.id, role: .host, handshakeHash: Data(repeating: 0, count: 31))
      XCTFail("invalid hash signed")
    } catch { XCTAssertEqual(error as? RelayError, .invalidMessage) }
  }

  func testFreshLedgerRevocationAndFailedDeleteCannotRestoreTrust() async throws {
    let p = try RelayTestPeers(failDelete: true)
    _ = try await p.client.trustedRelayGrant(id: p.grant.id)
    try p.revokeInStore()
    do {
      _ = try await p.client.trustedRelayGrant(id: p.grant.id)
      XCTFail("cached grant accepted")
    } catch { XCTAssertEqual(error as? RelayError, .revoked) }
    do {
      _ = try await p.client.grants()
      XCTFail("stale server grant restored trust")
    } catch { XCTAssertEqual(error as? PairingClientError, .invalidProof) }
    let h = try RelayTestPeers(failDelete: true)
    do {
      try await h.host.revoke(grantID: h.grant.id)
      XCTFail("DELETE should fail")
    } catch {}
    do {
      _ = try await h.host.trustedRelayGrant(id: h.grant.id)
      XCTFail("failed DELETE retained trust")
    } catch {
      XCTAssertTrue(error as? RelayError == .revoked || error as? RelayError == .untrusted)
    }
    do {
      _ = try await h.host.signRelayIdentity(
        grantID: h.grant.id, role: .host, handshakeHash: Data(repeating: 0, count: 32))
      XCTFail("revoked proof signed")
    } catch {}
  }

  func testConcurrentRefreshCannotOverwriteLocalRevocation() async throws {
    let p = try RelayTestPeers(failDelete: true)
    let refreshing = try p.secondClient()
    let (entered, signal) = AsyncStream<Void>.makeStream()
    // grants() checks and reloads the ledger before and after its request,
    // then rereads it to merge. Hold that fifth read open while the other
    // client revokes and the server is down.
    p.clientStore.onLedgerRead(5) {
      signal.yield()
      Thread.sleep(forTimeInterval: 0.3)
    }
    async let refreshed = refreshing.grants()
    for await _ in entered { break }
    do {
      try await p.client.revoke(grantID: p.grant.id, pairingID: p.grant.pairingID)
      XCTFail("DELETE should fail")
    } catch {}
    let listed = try await refreshed
    XCTAssertEqual(listed.map(\.id), [p.grant.id])
    XCTAssertTrue(try p.ledger().revokedPairings.contains(p.grant.pairingID))
    for client in [p.client, refreshing] {
      do {
        _ = try await client.trustedRelayGrant(id: p.grant.id)
        XCTFail("a concurrent refresh restored a locally revoked grant")
      } catch {
        XCTAssertTrue(error as? RelayError == .revoked || error as? RelayError == .untrusted)
      }
    }
  }

  func testRevokeRecordsDenialForGrantMissingFromLedger() async throws {
    let p = try RelayTestPeers(failDelete: true)
    try p.writeLedger(PairingTrustLedger(pinnedHosts: [p.grant.pairingID: p.grant.host.publicKey]))
    do {
      try await p.client.revoke(grantID: p.grant.id, pairingID: p.grant.pairingID)
      XCTFail("DELETE should fail")
    } catch {}
    do {
      _ = try await p.client.grants()
      XCTFail("a grant the server still lists restored trust after local revocation")
    } catch { XCTAssertEqual(error as? PairingClientError, .invalidProof) }
    do {
      _ = try await p.client.trustedRelayGrant(id: p.grant.id)
      XCTFail("revoked grant trusted")
    } catch {
      XCTAssertTrue(error as? RelayError == .revoked || error as? RelayError == .untrusted)
    }
  }

  func testStaleGrantListDoesNotRevokeGrantRecordedDuringRequest() async throws {
    let p = try RelayTestPeers()
    let pinned = PairingTrustLedger(pinnedHosts: [p.grant.pairingID: p.grant.host.publicKey])
    try p.writeLedger(pinned)
    // The response was produced before approval; another client records the
    // approved grant while it is in flight.
    let store = p, grant = p.grant
    let stale = try p.secondClient(grants: {
      try? store.writeLedger(PairingTrustLedger(
        pinnedHosts: [grant.pairingID: grant.host.publicKey], grants: [grant.id: grant]))
      return []
    })
    let listed = try await stale.grants()
    XCTAssertTrue(listed.isEmpty)
    XCTAssertFalse(try p.ledger().revokedPairings.contains(p.grant.pairingID))
    _ = try await p.client.trustedRelayGrant(id: p.grant.id)
    let current = try await p.client.grants()
    XCTAssertEqual(current.map(\.id), [p.grant.id])
  }

  func testRefreshSnapshotCannotDropGrantRecordedBeforeItsWrite() async throws {
    let p = try RelayTestPeers()
    try p.writeLedger(PairingTrustLedger(pinnedHosts: [p.grant.pairingID: p.grant.host.publicKey]))
    let stale = try p.secondClient(grants: { [] })
    let recorded = PairingTrustLedger(
      pinnedHosts: [p.grant.pairingID: p.grant.host.publicKey], grants: [p.grant.id: p.grant])
    let peers = p
    // The fourth ledger read is the refresh's reload after its request. The
    // other client records the approved grant once that snapshot is taken.
    p.clientStore.onLedgerRead(4) { try? peers.writeLedger(recorded) }
    let listed = try await stale.grants()
    XCTAssertTrue(listed.isEmpty)
    let ledger = try p.ledger()
    XCTAssertEqual(ledger.grants[p.grant.id], p.grant, "a stale refresh dropped a newly recorded grant")
    XCTAssertFalse(ledger.revokedPairings.contains(p.grant.pairingID))
    _ = try await p.client.trustedRelayGrant(id: p.grant.id)
    _ = try await stale.trustedRelayGrant(id: p.grant.id)
  }

  func testRevokedPairingStatusIsReadableButGrantsNothing() async throws {
    let p = try RelayTestPeers()
    let revoked = DevicePairing(
      id: p.grant.pairingID, status: .approved, expiresAt: Date().addingTimeInterval(300),
      host: p.grant.host, client: p.grant.client, grant: nil)
    let phone = try p.secondClient(grants: { [] }, pairing: revoked)
    do {
      try await phone.revoke(grantID: p.grant.id, pairingID: p.grant.pairingID)
      XCTFail("DELETE should fail")
    } catch {}
    let listed = try await phone.grants()
    XCTAssertTrue(listed.isEmpty)
    // A legitimate revocation is a state, not evidence of tampering.
    let status = try await phone.pairing(id: p.grant.pairingID)
    XCTAssertEqual(status.status, .approved)
    XCTAssertNil(status.grant)
    XCTAssertTrue(try p.ledger().revokedPairings.contains(p.grant.pairingID))
    do {
      _ = try await phone.trustedRelayGrant(id: p.grant.id)
      XCTFail("revoked grant trusted")
    } catch {
      XCTAssertTrue(error as? RelayError == .revoked || error as? RelayError == .untrusted)
    }
    // Without its pin, a revoked pairing that still claims a grant is refused.
    let restored = try p.secondClient(pairing: DevicePairing(
      id: p.grant.pairingID, status: .approved, expiresAt: Date().addingTimeInterval(300),
      host: p.grant.host, client: p.grant.client, grant: p.grant))
    do {
      _ = try await restored.pairing(id: p.grant.pairingID)
      XCTFail("a revoked pairing restored its grant")
    } catch { XCTAssertEqual(error as? PairingClientError, .invalidProof) }
  }

  func testPairedChannelsAuthenticateAndCarryActualVTBytes() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let bytes = Data([0, 27, 91, 50, 74, 255, 13, 10])
    try await client.send(bytes)
    let decoded = try await host.receive()
    XCTAssertEqual(decoded, bytes)
    try await host.send(bytes)
    let back = try await client.receive()
    XCTAssertEqual(back, bytes)
    try p.revokeInStore()
    do {
      try await client.send(bytes)
      XCTFail("revoked route sent data")
    } catch {}
    await client.close()
    await host.close()
  }

  func testSerialSendBackpressureClosesInsteadOfDropping() async throws {
    let p = try RelayTestPeers()
    let (client, host, c, _) = try await p.channels()
    await c.outbox.setPause()
    let errors = await withTaskGroup(of: RelayError?.self) { group in
      for _ in 0..<8 {
        group.addTask {
          do {
            try await client.send(Data(repeating: 9, count: 49_152))
            return nil
          } catch { return error as? RelayError }
        }
      }
      var errors: [RelayError] = []
      for await error in group { if let error { errors.append(error) } }
      return errors
    }
    XCTAssertTrue(errors.contains(.backpressure))
    XCTAssertEqual(errors.count, 8)
    await client.close()
    await host.close()
  }

  func testDeadlineCancelsUnderlyingReceive() async throws {
    let (socket, _) = RelayTestSocket.pair()
    let start = Date()
    do {
      _ = try await relayDeadline(0.03) { try await socket.receive() }
      XCTFail("deadline ignored")
    } catch { XCTAssertEqual(error as? RelayError, .transport) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  func testIdleLocalRevocationInterruptsReceiveAndRetainsFirstError() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let waiting = Task { try await relayDeadline(1) { try await client.receive() } }
    try await Task.sleep(for: .milliseconds(10))
    let began = Date()
    try p.revokeInStore()
    do {
      _ = try await waiting.value
      XCTFail("idle revoked channel stayed readable")
    } catch { XCTAssertEqual(error as? RelayError, .revoked) }
    XCTAssertLessThan(Date().timeIntervalSince(began), 0.8)
    await client.close()
    do {
      try await client.send(Data([1]))
      XCTFail("revoked terminal cause lost")
    } catch { XCTAssertEqual(error as? RelayError, .revoked) }
    do {
      _ = try await client.receive()
      XCTFail("revoked channel reopened")
    } catch { XCTAssertEqual(error as? RelayError, .revoked) }
    await host.close()
  }

  func testTrustWatchDoesNotRetainAnUnusedChannel() async throws {
    let p = try RelayTestPeers()
    var channels: (RelaySecureChannel, RelaySecureChannel, RelayTestSocket, RelayTestSocket)? =
      try await p.channels()
    let host = channels!.1
    let weakClient = RelayWeakReference(channels!.0)
    channels = nil
    try await eventually { weakClient.value == nil }
    await host.close()
  }

  func testBlackholePingHasDeadlineAndCloseCancelsHealthLoop() async throws {
    let counts = RelayTestCounters()
    let health = RelayHealthLoop(
      interval: 0.01, timeout: 0.03,
      ping: {
        try await RelayPing.wait(
          start: { _ in counts.bump("ping") }, cancel: { counts.bump("cancel") })
      }, failed: { counts.bump("failed") })
    let began = Date()
    await health.wait()
    XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    XCTAssertEqual(counts.count("ping"), 1)
    XCTAssertEqual(counts.count("cancel"), 1)
    XCTAssertEqual(counts.count("failed"), 1)
    health.stop()
    health.stop()
    await health.wait()

    let callback = RelayTestPong()
    let stopped = RelayTestCounters()
    var active: RelayHealthLoop? = RelayHealthLoop(
      interval: 0.01, timeout: 3,
      ping: {
        try await RelayPing.wait(
          start: { handler in
            callback.install(handler)
            stopped.bump("ping")
          }, cancel: { stopped.bump("cancel") })
      }, failed: { stopped.bump("failed") })
    let probe = RelayWeakReference(active!)
    try await eventually { stopped.count("ping") == 1 }
    active = nil
    XCTAssertNil(probe.value)
    try await eventually { stopped.count("cancel") == 1 }
    callback.complete()
    callback.complete()  // Late/double pong cannot resume a cancelled waiter.
    XCTAssertEqual(stopped.count("failed"), 0)
  }

  func testHealthyPongsDoNotCancelTheConnectionAfterSuccessfulDeadlines() async throws {
    let counts = RelayTestCounters()
    let health = RelayHealthLoop(
      interval: 0.01, timeout: 0.03,
      ping: {
        try await RelayPing.wait(
          start: { callback in
            counts.bump("ping")
            callback(nil)
          },
          cancel: { counts.bump("cancel") })
      }, failed: { counts.bump("failed") })
    try await eventually { counts.count("ping") >= 2 }
    health.stop()
    await health.wait()
    XCTAssertEqual(counts.count("cancel"), 0)
    XCTAssertEqual(counts.count("failed"), 0)
  }

  func testIdleAttachmentRevocationEndsOutputAndPreservesDetachError() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let session = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let server = Task {
      let attach = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      try await host.send(
        RemoteWire.encoder().encode(
          LocalAgentFrame(
            id: attach.id, kind: .response,
            ok: true, session: session, mode: .view)))
      do {
        _ = try await host.receive()
        XCTFail("revoked idle attachment sent data")
      } catch {}
    }
    let rpc = RemoteRPCConnection(channel: client)
    await rpc.start()
    _ = try await rpc.request(
      LocalAgentRequest(
        operation: .attach, sessionID: session.id,
        columns: 80, rows: 24, mode: .view))
    let attachment = RemoteTerminalAttachment(connection: rpc, session: session, mode: .view)
    try p.revokeInStore()
    do {
      _ = try await relayDeadline(1) {
        var output = attachment.output.makeAsyncIterator()
        return try await output.next()
      }
      XCTFail("idle attachment remained open after local revocation")
    } catch { XCTAssertEqual(error as? RelayError, .revoked) }
    await attachment.abort()
    do {
      try await attachment.detach()
      XCTFail("detach replaced the revocation reason")
    } catch { XCTAssertEqual(error as? RelayError, .revoked) }
    try await server.value
    await host.close()
  }

  func testDetachSharesAckWaitsForInputAndSurvivesConsumerCancellation() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let session = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let counts = RelayTestCounters()
    let inputRelease = RelayTestMailbox()
    let detachRelease = RelayTestMailbox()
    let server = Task {
      let attach = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      try await host.send(
        RemoteWire.encoder().encode(
          LocalAgentFrame(
            id: attach.id, kind: .response,
            ok: true, session: session, mode: .control)))
      let input = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      XCTAssertEqual(input.operation, .input)
      counts.bump("input")
      _ = try await inputRelease.get()
      try await host.send(
        RemoteWire.encoder().encode(LocalAgentFrame(id: input.id, kind: .response, ok: true)))
      let detach = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      XCTAssertEqual(detach.operation, .detach)
      counts.bump("detach")
      _ = try await detachRelease.get()
      counts.bump("released")
      try await host.send(
        RemoteWire.encoder().encode(LocalAgentFrame(id: detach.id, kind: .response, ok: true)))
      do {
        _ = try await host.receive()
        XCTFail("extra command after detach")
      } catch {}
    }
    let rpc = RemoteRPCConnection(channel: client)
    await rpc.start()
    _ = try await rpc.request(
      LocalAgentRequest(
        operation: .attach, sessionID: session.id, columns: 80, rows: 24, mode: .control))
    let attachment = RemoteTerminalAttachment(connection: rpc, session: session, mode: .control)
    let consumer = Task { for try await _ in attachment.output {} }
    let input = Task { try await attachment.send(Data([97])) }
    try await eventually { counts.count("input") == 1 }
    let first = Task {
      try await attachment.detach()
      counts.bump("done")
    }
    let second = Task {
      try await attachment.detach()
      counts.bump("done")
    }
    XCTAssertEqual(counts.count("detach"), 0)
    try await inputRelease.put(Data())
    try await input.value
    try await eventually { counts.count("detach") == 1 }
    consumer.cancel()
    let bestEffort = Task { await attachment.disconnect() }
    XCTAssertEqual(counts.count("done"), 0)
    try await detachRelease.put(Data())
    try await first.value
    try await second.value
    await bestEffort.value
    XCTAssertEqual(counts.count("done"), 2)
    XCTAssertEqual(counts.count("released"), 1)
    try await attachment.detach()
    await attachment.disconnect()
    await attachment.abort()
    XCTAssertEqual(counts.count("detach"), 1)
    try await server.value
    await host.close()
  }

  func testAbortDuringDetachReleasesLocalWorkersAndIsIdempotent() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let session = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let counts = RelayTestCounters()
    let server = Task {
      let attach = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      try await host.send(
        RemoteWire.encoder().encode(
          LocalAgentFrame(
            id: attach.id, kind: .response,
            ok: true, session: session, mode: .control)))
      let detach = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      XCTAssertEqual(detach.operation, .detach)
      counts.bump("detach")
      do {
        _ = try await host.receive()
        XCTFail("abort sent another command")
      } catch {}
    }
    var rpc: RemoteRPCConnection? = RemoteRPCConnection(channel: client)
    let weakRPC = RelayWeakReference(rpc!)
    await rpc!.start()
    _ = try await rpc!.request(
      LocalAgentRequest(
        operation: .attach, sessionID: session.id, columns: 80, rows: 24, mode: .control))
    var attachment: RemoteTerminalAttachment? = RemoteTerminalAttachment(
      connection: rpc!, session: session, mode: .control)
    rpc = nil
    let detaching = Task { [weak held = attachment] in
      guard let held else { throw RelayError.transport }
      try await held.detach()
    }
    try await eventually { counts.count("detach") == 1 }
    let began = Date()
    await attachment!.abort()
    await attachment!.abort()
    XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    do {
      try await detaching.value
      XCTFail("aborted detach succeeded")
    } catch { XCTAssertEqual(error as? RelayError, .transport) }
    attachment = nil
    try await server.value
    await host.close()
    try await eventually { weakRPC.value == nil }
  }

  func testDetachTimeoutIsBoundedAndRetainsItsSharedFailure() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let rpc = RemoteRPCConnection(channel: client)
    await rpc.start()
    let server = Task {
      _ = try await host.receive()
      do { _ = try await host.receive() } catch {}
    }
    let began = Date()
    do {
      try await rpc.detach(timeout: 0.03)
      XCTFail("silent detach acknowledged")
    } catch { XCTAssertEqual(error as? RelayError, .transport) }
    XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    do {
      try await rpc.detach()
      XCTFail("failed detach result discarded")
    } catch { XCTAssertEqual(error as? RelayError, .transport) }
    await rpc.abort()
    try await server.value
    await host.close()
  }

  func testConcurrentSendsPreserveCipherOrderingAndReceiveCancellationCloses() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let receive = Task { () throws -> Set<Data> in
      var values = Set<Data>()
      for _ in 0..<16 { values.insert(try await host.receive()) }
      return values
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for value in UInt8(0)..<16 { group.addTask { try await client.send(Data([value])) } }
      try await group.waitForAll()
    }
    let values = try await receive.value
    XCTAssertEqual(values, Set((UInt8(0)..<16).map { Data([$0]) }))
    let waiting = Task { try await client.receive() }
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("cancelled receive succeeded")
    } catch {}
    do {
      try await client.send(Data([99]))
      XCTFail("cancelled route reused")
    } catch {}
    await client.close()
    await host.close()
  }

  func testInvalidPairedHostProofCannotAuthenticateAValidNoisePeer() async throws {
    let p = try RelayTestPeers()
    let (clientSocket, hostSocket) = RelayTestSocket.pair()
    let attacker = Task {
      var noise = RelayNoiseHandshake(
        initiator: false,
        prologue: try RelayContext.prologue(server: p.server, tunnelID: p.tunnel, grant: p.grant))
      _ = try noise.read(await hostSocket.receive())
      try await hostSocket.send(noise.write())
      _ = try noise.read(await hostSocket.receive())
      var (send, receive) = try noise.split()
      _ = try receive.decrypt(await hostSocket.receive())
      let wrong = RelayIdentityProof(
        role: .host,
        signature: try p.clientKey.signature(
          for: RelayIdentityProof.message(role: .host, hash: noise.hash)))
      try await hostSocket.send(send.encrypt(JSONEncoder().encode(wrong)))
    }
    do {
      _ = try await RelaySecureChannel.establish(
        pairing: p.client, credentials: p.clientCredentials,
        grant: p.grant, tunnelID: p.tunnel, role: .client, socket: clientSocket)
      XCTFail("Noise alone authenticated an unpaired host")
    } catch { XCTAssertEqual(error as? RelayError, .untrusted) }
    try await attacker.value
    clientSocket.close()
    hostSocket.close()
  }

  func testRemoteRPCSeparatesOutputAcksAndUsesAuthoritativeSession() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let session = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let initial = Data([27, 91, 50, 74, 0, 255])
    let input = Data([97, 13, 27, 91, 65])
    let server = Task {
      for _ in 0..<4 {
        let request = try RemoteWire.decoder().decode(
          LocalAgentRequest.self, from: await host.receive())
        if request.operation == .input {
          try await host.send(
            RemoteWire.encoder().encode(LocalAgentFrame(kind: .output, data: request.data)))
        }
        try await host.send(
          RemoteWire.encoder().encode(
            LocalAgentFrame(
              id: request.id, kind: .response, ok: true,
              session: request.operation == .attach ? session : nil,
              mode: request.operation == .attach ? request.mode : nil)))
        if request.operation == .attach {
          XCTAssertEqual(request.columns, 120)
          try await host.send(
            RemoteWire.encoder().encode(LocalAgentFrame(kind: .output, data: initial)))
        }
      }
    }
    let rpc = RemoteRPCConnection(channel: client)
    await rpc.start()
    let frame = try await rpc.request(
      LocalAgentRequest(
        operation: .attach, sessionID: session.id,
        columns: 120, rows: 40, mode: .control))
    let attachment = RemoteTerminalAttachment(
      connection: rpc, session: try XCTUnwrap(frame.session), mode: .control)
    XCTAssertEqual(attachment.session, session)
    var iterator = attachment.output.makeAsyncIterator()
    let first = try await iterator.next()
    XCTAssertEqual(first, initial)
    try await attachment.send(input)
    let second = try await iterator.next()
    XCTAssertEqual(second, input)
    try await attachment.resize(columns: 100, rows: 30)
    await attachment.disconnect()
    let end = try await iterator.next()
    XCTAssertNil(end)
    try await server.value
    await host.close()
  }

  func testRemoteGeometryAndVTKeepTheirAuthenticatedWireOrder() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let original = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let resized = LocalSessionInfo(
      id: original.id, name: original.name, createdAt: original.createdAt, columns: 111, rows: 39)
    let before = Data([27, 91])
    let after = Data([50, 74, 0, 255])
    let server = Task {
      let request = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      try await host.send(
        RemoteWire.encoder().encode(
          LocalAgentFrame(
            id: request.id, kind: .response,
            ok: true, session: original, mode: .view)))
      try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(kind: .output, data: before)))
      try await host.send(
        RemoteWire.encoder().encode(LocalAgentFrame(kind: .geometry, session: resized)))
      try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(kind: .output, data: after)))
      let detach = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      try await host.send(
        RemoteWire.encoder().encode(LocalAgentFrame(id: detach.id, kind: .response, ok: true)))
    }
    let rpc = RemoteRPCConnection(channel: client)
    await rpc.start()
    let response = try await rpc.request(
      LocalAgentRequest(
        operation: .attach, sessionID: original.id,
        columns: 80, rows: 24, mode: .view))
    let attachment = RemoteTerminalAttachment(
      connection: rpc, session: try XCTUnwrap(response.session), mode: .view)
    var events = attachment.events.makeAsyncIterator()
    let first = try await events.next()
    let second = try await events.next()
    let third = try await events.next()
    XCTAssertEqual(first, .output(before))
    XCTAssertEqual(second, .geometry(resized))
    XCTAssertEqual(third, .output(after))
    XCTAssertEqual(attachment.session, original)
    var rejected = attachment.output.makeAsyncIterator()
    do {
      _ = try await rejected.next()
      XCTFail("mixed remote terminal consumers accepted")
    } catch { XCTAssertEqual(error as? RelayError, .invalidMessage) }
    try await attachment.detach()
    let end = try await events.next()
    XCTAssertNil(end)
    try await server.value
    await host.close()
  }

  func testRemoteGeometryRequiresAttachAndUnchangedSessionIdentity() async throws {
    let original = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let otherID = LocalSessionInfo(
      id: "88888888-8888-4888-8888-888888888888", name: original.name,
      createdAt: original.createdAt, columns: 100, rows: 30)
    let otherDate = LocalSessionInfo(
      id: original.id, name: original.name,
      createdAt: original.createdAt.addingTimeInterval(1), columns: 100, rows: 30)
    let invalidSize = LocalSessionInfo(
      id: original.id, name: original.name, createdAt: original.createdAt, columns: 100, rows: 201)
    let variants = [
      LocalAgentFrame(kind: .geometry, session: otherID),
      LocalAgentFrame(kind: .geometry, session: otherDate),
      LocalAgentFrame(kind: .geometry, session: invalidSize),
      LocalAgentFrame(kind: .geometry, session: original, data: Data([0])),
      LocalAgentFrame(kind: .geometry, ok: true, session: original),
    ]
    for index in -1..<variants.count {
      let p = try RelayTestPeers()
      let (client, host, _, _) = try await p.channels()
      let server = Task {
        let request = try RemoteWire.decoder().decode(
          LocalAgentRequest.self, from: await host.receive())
        if index >= 0 {
          try await host.send(
            RemoteWire.encoder().encode(
              LocalAgentFrame(
                id: request.id, kind: .response,
                ok: true, session: original, mode: .view)))
        }
        try await host.send(
          RemoteWire.encoder().encode(
            index < 0 ? LocalAgentFrame(kind: .geometry, session: original) : variants[index]))
      }
      let rpc = RemoteRPCConnection(channel: client)
      await rpc.start()
      do {
        _ = try await rpc.request(
          LocalAgentRequest(
            operation: .attach, sessionID: original.id,
            columns: 80, rows: 24, mode: .view))
        var events = rpc.events.makeAsyncIterator()
        _ = try await events.next()
        XCTFail("invalid remote geometry accepted")
      } catch { XCTAssertEqual(error as? RelayError, .invalidMessage) }
      try await server.value
      await rpc.close()
      await host.close()
    }
  }

  /// A terminal renamed on the Mac while a paired device has it open: the
  /// next geometry carries the new name and the attachment stays.
  func testRemoteGeometryAfterRenameKeepsTheAttachment() async throws {
    let original = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let renamed = LocalSessionInfo(
      id: original.id, name: "Renamed", createdAt: original.createdAt, columns: 100, rows: 30)
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let server = Task {
      let request = try RemoteWire.decoder().decode(LocalAgentRequest.self, from: await host.receive())
      try await host.send(RemoteWire.encoder().encode(
        LocalAgentFrame(id: request.id, kind: .response, ok: true, session: original, mode: .view)))
      try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(kind: .geometry, session: renamed)))
    }
    let rpc = RemoteRPCConnection(channel: client)
    await rpc.start()
    _ = try await rpc.request(
      LocalAgentRequest(operation: .attach, sessionID: original.id, columns: 80, rows: 24, mode: .view))
    var events = rpc.events.makeAsyncIterator()
    let event = try await events.next()
    XCTAssertEqual(event, .geometry(renamed))
    try await server.value
    await rpc.close()
    await host.close()
  }

  func testViewGrantRejectsControlBeforeOpeningNetwork() async throws {
    let p = try RelayTestPeers(permission: .view)
    let client = RemoteTerminalClient(pairing: p.client, grantID: p.grant.id)
    do {
      _ = try await client.attach(sessionID: "77777777-7777-4777-8777-777777777777", mode: .control)
      XCTFail("view grant requested control")
    } catch { XCTAssertEqual(error as? RelayError, .readOnly) }
  }

  func testRemoteOutputBeforeAttachAckAndUnknownResponsesFailClosed() async throws {
    for frame in [
      LocalAgentFrame(kind: .output, data: Data([27])),
      LocalAgentFrame(id: "88888888-8888-4888-8888-888888888888", kind: .response, ok: true),
      LocalAgentFrame(version: 2, kind: .closed),
    ] {
      let p = try RelayTestPeers()
      let (client, host, _, _) = try await p.channels()
      let rpc = RemoteRPCConnection(channel: client)
      await rpc.start()
      let server = Task {
        _ = try await host.receive()
        try await host.send(RemoteWire.encoder().encode(frame))
      }
      do {
        _ = try await rpc.request(LocalAgentRequest(operation: .list))
        XCTFail("invalid frame accepted")
      } catch { XCTAssertEqual(error as? RelayError, .invalidMessage) }
      try await server.value
      await rpc.close()
      await host.close()
    }
  }

  /// Output that arrives before anyone reads it is kept whole and in order,
  /// however many frames: the reader waits on bytes, never drops.
  func testRemoteEarlyOutputIsKeptWholeAndInOrder() async throws {
    let p = try RelayTestPeers()
    let (client, host, _, _) = try await p.channels()
    let session = LocalSessionInfo(
      id: "77777777-7777-4777-8777-777777777777", name: "Shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
    let rpc = RemoteRPCConnection(channel: client)
    await rpc.start()
    let frames = 300
    let server = Task {
      let request = try RemoteWire.decoder().decode(
        LocalAgentRequest.self, from: await host.receive())
      try await host.send(
        RemoteWire.encoder().encode(
          LocalAgentFrame(
            id: request.id, kind: .response,
            ok: true, session: session, mode: .view)))
      for index in 0..<frames {
        try await host.send(
          RemoteWire.encoder().encode(LocalAgentFrame(kind: .output, data: Data([UInt8(index % 256)]))))
      }
      try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(kind: .closed)))
    }
    _ = try await rpc.request(
      LocalAgentRequest(
        operation: .attach, sessionID: session.id,
        columns: 80, rows: 24, mode: .view))
    try await server.value
    var chunks: [Data] = []
    for try await bytes in rpc.output { chunks.append(bytes) }
    XCTAssertEqual(chunks, (0..<frames).map { Data([UInt8($0 % 256)]) })
    await rpc.close()
    await host.close()
  }

  func testHTTPBodyBoundAbsoluteDeadlineAndValidTunnelResponse() async throws {
    let p = try RelayTestPeers()
    func credentials(_ host: String) -> RelayCredentials {
      RelayCredentials(
        server: URL(string: "https://\(host)")!, device: p.grant.client,
        accessToken: p.clientCredentials.accessToken, expiresAt: p.clientCredentials.expiresAt)
    }
    func session() -> URLSession {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [RelayTestURLProtocol.self]
      return URLSession(configuration: config, delegate: RelayNetworkDelegate(), delegateQueue: nil)
    }
    let id = try await RelayNetwork.createTunnel(
      credentials: credentials("valid.example"), grantID: p.grant.id, session: session())
    XCTAssertEqual(id, p.tunnel)
    do {
      _ = try await RelayNetwork.createTunnel(
        credentials: credentials("oversize.example"), grantID: p.grant.id, session: session())
      XCTFail("oversized HTTP body accepted")
    } catch { XCTAssertEqual(error as? RelayError, .invalidMessage) }
    let start = Date()
    do {
      _ = try await RelayNetwork.createTunnel(
        credentials: credentials("slow.example"), grantID: p.grant.id, session: session(),
        deadline: 0.05)
      XCTFail("stalled HTTP ignored absolute deadline")
    } catch { XCTAssertEqual(error as? RelayError, .transport) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  func testNetworkHasNoCredentialsCookiesOrRedirectsAndRequiresSecureOrigin() throws {
    let p = try RelayTestPeers()
    let session = RelayNetwork.session()
    defer { session.invalidateAndCancel() }
    XCTAssertNil(session.configuration.httpCookieStorage)
    XCTAssertNil(session.configuration.urlCredentialStorage)
    XCTAssertNil(session.configuration.urlCache)
    XCTAssertFalse(session.configuration.httpShouldSetCookies)
    let request = try RelayNetwork.request(
      credentials: p.clientCredentials, path: "v1/relay/host", websocket: true)
    XCTAssertEqual(request.url?.scheme, "wss")
    XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    let insecure = RelayCredentials(
      server: URL(string: "http://remote.example")!, device: p.grant.client,
      accessToken: p.clientCredentials.accessToken, expiresAt: p.clientCredentials.expiresAt)
    XCTAssertThrowsError(
      try RelayNetwork.request(credentials: insecure, path: "v1/relay/host", websocket: true))
    let callback = expectation(description: "redirect denied")
    let task = session.dataTask(with: URL(string: "https://relay.example")!)
    RelayNetworkDelegate().urlSession(
      session, task: task,
      willPerformHTTPRedirection: HTTPURLResponse(
        url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!,
      newRequest: URLRequest(url: URL(string: "https://attacker.example")!)
    ) { request in
      XCTAssertNil(request)
      callback.fulfill()
    }
    wait(for: [callback], timeout: 1)
  }
}

private final class RelayTestURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if request.url?.host == "slow.example" { return }
    let body =
      request.url?.host == "oversize.example"
      ? Data(repeating: 32, count: 4097)
      : Data("{\"tunnel_id\":\"33333333-3333-4333-8333-333333333333\"}".utf8)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
