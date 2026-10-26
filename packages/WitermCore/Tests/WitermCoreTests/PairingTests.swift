import CryptoKit
import Foundation
import XCTest

@testable import WitermCore

private final class MemoryPairingStore: PairingSecureStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  var failReads = false
  private(set) var createCount = 0

  func read(account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if failReads { throw PairingClientError.identityUnavailable }
    return values[account]
  }
  func create(_ data: Data, account: String) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    createCount += 1
    if values[account] != nil { return false }
    values[account] = data
    return true
  }
  func write(_ data: Data, account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values[account] = data
  }
  func delete(account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: account)
  }
}

private actor UnauthorizedTransport: PairingTransport {
  private let key: String
  private var challengeCount = 0
  private var grantCount = 0
  init(key: String) { self.key = key }

  func counts() -> (Int, Int) { (challengeCount, grantCount) }

  func send(_ request: URLRequest) async throws -> (Data, Int) {
    let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
    let random = Data(repeating: 9, count: 32).base64EncodedString().replacingOccurrences(
      of: "=", with: "")
    var object: [String: Any]
    let status: Int
    switch request.url!.path {
    case "/v1/auth/challenges":
      challengeCount += 1
      object = [
        "challenge_id": "11111111-1111-4111-8111-111111111111", "nonce": random, "expires_at": date,
      ]
      status = 201
    case "/v1/devices":
      object = [
        "device": [
          "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "name": "Test Mac", "platform": "macos",
          "public_key": key,
        ], "access_token": random, "expires_at": date,
      ]
      status = 200
    default:
      grantCount += 1
      object = ["error": ["code": "unauthorized", "message": "expired"]]
      status = 401
    }
    return (try JSONSerialization.data(withJSONObject: object), status)
  }
}

final class PairingTests: XCTestCase {
  private func fixture() throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appendingPathComponent("protocol/fixtures/pairing-signatures-v1.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func seed(_ value: String) -> Data {
    Data(
      stride(from: 0, to: value.count, by: 2).map { offset in
        let start = value.index(value.startIndex, offsetBy: offset)
        return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
      })
  }

  func testSharedSignaturesAndFieldBinding() throws {
    let values = try fixture()
    let key = try Curve25519.Signing.PrivateKey(
      rawRepresentation: seed(try XCTUnwrap(values["host_seed_hex"] as? String)))
    XCTAssertEqual(
      key.publicKey.rawRepresentation.base64EncodedString(), values["host_public_key"] as? String)
    let registration = try XCTUnwrap(values["registration"] as? [String: String])
    let message = PairingEncoding.registrationMessage(
      challengeID: registration["challenge_id"]!, nonce: registration["nonce"]!,
      name: registration["name"]!, platform: .macos)
    XCTAssertEqual(String(data: message, encoding: .utf8), registration["message"])
    // CryptoKit's generated signature bytes differed from the fixed vector
    // on this SDK; interoperability depends on verification, not byte identity.
    XCTAssertTrue(
      key.publicKey.isValidSignature(Data(base64Encoded: registration["signature"]!)!, for: message)
    )
    XCTAssertTrue(key.publicKey.isValidSignature(try key.signature(for: message), for: message))
    let approval = try XCTUnwrap(values["approval"] as? [String: String])
    let approvalMessage = PairingEncoding.approvalMessage(
      pairingID: approval["pairing_id"]!, hostKey: approval["host_public_key"]!,
      clientKey: approval["client_public_key"]!, permission: .control)
    XCTAssertEqual(String(data: approvalMessage, encoding: .utf8), approval["message"])
    XCTAssertTrue(
      key.publicKey.isValidSignature(
        Data(base64Encoded: approval["signature"]!)!, for: approvalMessage))
    XCTAssertTrue(
      key.publicKey.isValidSignature(
        Data(base64Encoded: approval["alternate_signature"]!)!, for: approvalMessage))
    XCTAssertNotEqual(approval["signature"], approval["alternate_signature"])
    XCTAssertTrue(
      key.publicKey.isValidSignature(try key.signature(for: approvalMessage), for: approvalMessage))
    let tampered = PairingEncoding.approvalMessage(
      pairingID: approval["pairing_id"]!, hostKey: approval["host_public_key"]!,
      clientKey: approval["client_public_key"]!, permission: .view)
    XCTAssertFalse(
      key.publicKey.isValidSignature(Data(base64Encoded: approval["signature"]!)!, for: tampered))
  }

  func testInvitationPinsServerAndRejectsAmbiguity() throws {
    let values = try fixture()
    let key = try XCTUnwrap(values["host_public_key"] as? String)
    let secret = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(
      of: "=", with: "")
    let original = PairingInvitation.make(
      server: "https://example.com", pairingID: "22222222-2222-4222-8222-222222222222",
      hostKey: key, secret: secret)
    let parsed = try PairingInvitation(
      urlString: original.urlString, expectedServer: "HTTPS://EXAMPLE.COM:443/")
    XCTAssertEqual(parsed.hostPublicKey, key)
    XCTAssertEqual(parsed.pairingID, original.pairingID)
    XCTAssertThrowsError(
      try PairingInvitation(
        urlString: original.urlString, expectedServer: "https://other.example.com")
    ) {
      XCTAssertEqual($0 as? PairingClientError, .serverMismatch)
    }
    for invalid in [
      original.urlString + "&id=22222222-2222-4222-8222-222222222222",
      original.urlString + "&extra=x", original.urlString + "#fragment",
      original.urlString.replacingOccurrences(of: "witerm://", with: "https://"),
    ] {
      XCTAssertThrowsError(
        try PairingInvitation(urlString: invalid, expectedServer: "https://example.com"))
    }
  }

  func testIdentityTransportRejectsDowngrades() throws {
    for address in [
      "http://example.com", "http://192.168.1.2", "http://localhost.example.com",
      "http://127.0.0.1.example.com", "http://127.0.0.999",
    ] {
      XCTAssertThrowsError(try PairingServerAddress.normalized(address))
    }
    for address in [
      "https://example.com", "http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080",
    ] {
      XCTAssertNoThrow(try PairingServerAddress.normalized(address))
    }
  }

  func testKeychainReadFailureDoesNotReplaceIdentity() throws {
    let store = MemoryPairingStore()
    store.failReads = true
    XCTAssertThrowsError(try PairingIdentity(store: store))
    XCTAssertEqual(store.createCount, 0)
    store.failReads = false
    let first = try PairingIdentity(store: store)
    let second = try PairingIdentity(store: store)
    XCTAssertEqual(first.publicKey, second.publicKey)
    XCTAssertEqual(store.createCount, 1)
    try store.write(Data([1, 2, 3]), account: "device-signing-key")
    XCTAssertThrowsError(try PairingIdentity(store: store))
    XCTAssertEqual(store.createCount, 1)
  }

  func testGrantNeedsPinnedHostAndCannotChangePermission() throws {
    let values = try fixture()
    let approval = try XCTUnwrap(values["approval"] as? [String: String])
    let host = PairedDevice(
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "Test Mac", platform: .macos,
      publicKey: approval["host_public_key"]!)
    let client = PairedDevice(
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", name: "Test iOS", platform: .ios,
      publicKey: approval["client_public_key"]!)
    let grant = DeviceGrant(
      id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", pairingID: approval["pairing_id"]!, host: host,
      client: client, permission: .control, approvalSignature: approval["signature"]!,
      createdAt: .now)
    XCTAssertNoThrow(
      try PairingProof.validateGrant(grant, identity: client, pinnedHostKey: host.publicKey))
    XCTAssertThrowsError(
      try PairingProof.validateGrant(grant, identity: client, pinnedHostKey: nil))
    XCTAssertThrowsError(
      try PairingProof.validateGrant(grant, identity: client, pinnedHostKey: client.publicKey))
    let changed = DeviceGrant(
      id: grant.id, pairingID: grant.pairingID, host: host, client: client, permission: .view,
      approvalSignature: grant.approvalSignature, createdAt: grant.createdAt)
    XCTAssertThrowsError(
      try PairingProof.validateGrant(changed, identity: client, pinnedHostKey: host.publicKey))
  }

  func testUnauthorizedRenewsOnlyOnce() async throws {
    let store = MemoryPairingStore()
    let server = try PairingServerAddress.normalized("http://localhost:8080")
    let identity = try PairingIdentity(
      store: store, account: PairingIdentity.account(server: server.absoluteString))
    let transport = UnauthorizedTransport(key: identity.publicKey)
    let client = try PairingClient(
      serverAddress: "http://localhost:8080", deviceName: "Test Mac", platform: .macos,
      store: store, transport: transport)
    do {
      _ = try await client.grants()
      XCTFail("unauthorized request unexpectedly succeeded")
    } catch PairingClientError.api(let code) {
      XCTAssertEqual(code, "unauthorized")
    }
    let counts = await transport.counts()
    XCTAssertEqual(counts.0, 2)
    XCTAssertEqual(counts.1, 2)
  }

  func testServerOriginsHaveIndependentStableIdentities() throws {
    let store = MemoryPairingStore()
    let unused = UnauthorizedTransport(key: "unused")
    _ = try PairingClient(
      serverAddress: "https://a.example.com", deviceName: "Test Mac", platform: .macos,
      store: store, transport: unused)
    _ = try PairingClient(
      serverAddress: "HTTPS://A.EXAMPLE.COM:443/", deviceName: "Test Mac", platform: .macos,
      store: store, transport: unused)
    _ = try PairingClient(
      serverAddress: "https://b.example.com", deviceName: "Test Mac", platform: .macos,
      store: store, transport: unused)
    let a = try PairingServerAddress.normalized("https://a.example.com").absoluteString
    let b = try PairingServerAddress.normalized("https://b.example.com").absoluteString
    let aIdentity = try PairingIdentity(store: store, account: PairingIdentity.account(server: a))
    let bIdentity = try PairingIdentity(store: store, account: PairingIdentity.account(server: b))
    XCTAssertNotEqual(aIdentity.publicKey, bIdentity.publicKey)
    XCTAssertEqual(store.createCount, 2)
  }

  func testLiveTwoDevicePairingWithoutKeychain() async throws {
    guard let server = ProcessInfo.processInfo.environment["WITERM_PAIRING_TEST_SERVER_URL"] else {
      throw XCTSkip("Set WITERM_PAIRING_TEST_SERVER_URL to test the real pairing API")
    }
    let hostStore = MemoryPairingStore()
    let phoneStore = MemoryPairingStore()
    let host = try PairingClient(
      serverAddress: server, deviceName: "SDK Test Mac", platform: .macos,
      store: hostStore, transport: URLSessionPairingTransport())
    let phone = try PairingClient(
      serverAddress: server, deviceName: "SDK Test iOS", platform: .ios,
      store: phoneStore, transport: URLSessionPairingTransport())
    let hostDevice = try await host.register()
    let phoneDevice = try await phone.register()
    XCTAssertNotEqual(hostDevice.publicKey, phoneDevice.publicKey)
    let invitation = try await host.createPairing()
    let pasted = try PairingInvitation(urlString: invitation.urlString, expectedServer: server)
    let joined = try await phone.join(pasted)
    XCTAssertEqual(joined.status, .pending)
    XCTAssertNil(joined.grant)
    let beforeHost = try await host.grants()
    let beforePhone = try await phone.grants()
    XCTAssertTrue(beforeHost.isEmpty)
    XCTAssertTrue(beforePhone.isEmpty)
    let pending = try await host.pairing(id: invitation.pairingID)
    let approved = try await host.approve(pending, permission: .view)
    let grant = try XCTUnwrap(approved.grant)
    let retried = try await host.approve(pending, permission: .view)
    XCTAssertEqual(retried.grant?.id, grant.id)
    let clientApproved = try await phone.pairing(id: invitation.pairingID)
    XCTAssertEqual(clientApproved.grant?.id, grant.id)
    let hostGrants = try await host.grants()
    let phoneGrants = try await phone.grants()
    XCTAssertEqual(hostGrants.map(\.id), [grant.id])
    XCTAssertEqual(phoneGrants.map(\.id), [grant.id])
    let restoredPhone = try PairingClient(
      serverAddress: server, deviceName: "SDK Test iOS", platform: .ios,
      store: phoneStore, transport: URLSessionPairingTransport())
    let restoredGrants = try await restoredPhone.grants()
    XCTAssertEqual(restoredGrants.map(\.id), [grant.id])
    try await host.revoke(grantID: grant.id)
    let revokedHost = try await host.grants()
    let revokedPhone = try await phone.grants()
    XCTAssertTrue(revokedHost.isEmpty)
    XCTAssertTrue(revokedPhone.isEmpty)
    let revokedPairing = try await phone.pairing(id: invitation.pairingID)
    XCTAssertEqual(revokedPairing.status, .approved)
    XCTAssertNil(revokedPairing.grant)
  }
}
