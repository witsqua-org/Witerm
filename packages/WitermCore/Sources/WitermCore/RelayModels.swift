import CryptoKit
import Foundation

enum RelayTrace {
  static func event(_ id: String, _ phase: String, error: Error? = nil) {
    #if DEBUG
    guard ProcessInfo.processInfo.environment["WITERM_RELAY_TRACE"] == "1" else { return }
    let tag: String
    if let relay = error as? RelayError { tag = String(describing: relay) }
    else if let url = error as? URLError { tag = "url-\(url.code.rawValue)" }
    else if error is CancellationError { tag = "cancelled" }
    else { tag = error == nil ? "ok" : "other" }
    // Only fixed phases, error codes and an opaque route prefix; no payloads.
    print("relay-core[\(id)] \(phase): \(tag)")
    #endif
  }
}

public enum RelayError: Error, Sendable, Equatable {
  case offline, untrusted, revoked, unauthorized, invalidMessage, transport, backpressure
  case readOnly, sessionBusy, unavailable
  /// The session ended, or the Mac stopped sharing it.
  case sessionUnavailable
}

public struct RelayCredentials: Sendable {
  public let server: URL
  public let device: PairedDevice
  public let accessToken: String
  public let expiresAt: Date

  public init(server: URL, device: PairedDevice, accessToken: String, expiresAt: Date) {
    self.server = server
    self.device = device
    self.accessToken = accessToken
    self.expiresAt = expiresAt
  }
}

public struct RelayOffer: Codable, Sendable, Equatable {
  public let tunnelID: String
  public let grantID: String
  public init(tunnelID: String, grantID: String) {
    self.tunnelID = tunnelID
    self.grantID = grantID
  }
  enum CodingKeys: String, CodingKey {
    case tunnelID = "tunnel_id"
    case grantID = "grant_id"
  }
}

enum RelayMetadata {
  static func ready(_ data: Data) throws {
    guard data.count <= 4096,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      object == ["type": "ready"]
    else { throw RelayError.invalidMessage }
  }
  static func offer(_ data: Data) throws -> RelayOffer {
    guard data.count <= 4096,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      Set(object.keys) == ["type", "tunnel_id", "grant_id"], object["type"] == "offer"
    else { throw RelayError.invalidMessage }
    let offer = try JSONDecoder().decode(RelayOffer.self, from: data)
    guard PairingEncoding.canonicalID(offer.tunnelID) == offer.tunnelID,
      PairingEncoding.canonicalID(offer.grantID) == offer.grantID
    else { throw RelayError.invalidMessage }
    return offer
  }
  static func createRequest(grantID: String) throws -> Data {
    guard PairingEncoding.canonicalID(grantID) == grantID else { throw RelayError.untrusted }
    return try JSONEncoder().encode(["grant_id": grantID])
  }
  static func createdTunnel(_ data: Data) throws -> String {
    guard data.count <= 4096,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      Set(object.keys) == ["tunnel_id"], let id = object["tunnel_id"],
      PairingEncoding.canonicalID(id) == id
    else { throw RelayError.invalidMessage }
    return id
  }
}

enum RelayRole: String, Codable, Sendable { case client, host }

struct RelayIdentityProof: Codable, Sendable {
  let role: RelayRole
  let signature: Data

  static func message(role: RelayRole, hash: Data) throws -> Data {
    guard hash.count == 32 else { throw RelayError.invalidMessage }
    return Data("witerm-relay-identity-v1\n\(role.rawValue)\n".utf8) + hash
  }

  func verify(expectedRole: RelayRole, hash: Data, grant: DeviceGrant) throws {
    guard role == expectedRole, signature.count == 64,
      let bytes = PairingEncoding.publicKey(
        role == .host ? grant.host.publicKey : grant.client.publicKey)
    else { throw RelayError.untrusted }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    guard key.isValidSignature(signature, for: try Self.message(role: role, hash: hash)) else {
      throw RelayError.untrusted
    }
  }
}

enum RelayContext {
  static func sameIdentity(_ first: PairedDevice, _ second: PairedDevice) -> Bool {
    first.id == second.id && first.publicKey == second.publicKey
      && first.platform == second.platform
  }
  static func prologue(server: URL, tunnelID: String, grant: DeviceGrant) throws -> Data {
    guard try PairingServerAddress.normalized(server.absoluteString) == server,
      PairingEncoding.canonicalID(tunnelID) == tunnelID
    else { throw RelayError.invalidMessage }
    do { try PairingProof.validateGrant(grant, identity: grant.host, pinnedHostKey: nil) } catch {
      throw RelayError.untrusted
    }
    let fields = [
      "witerm-relay-v1", server.absoluteString, tunnelID, grant.id, grant.pairingID,
      grant.host.id, grant.host.publicKey, grant.client.id, grant.client.publicKey,
      grant.permission.rawValue,
    ]
    return Data((fields.joined(separator: "\n") + "\n").utf8)
  }

  static func map(_ error: Error) -> RelayError {
    if let relay = error as? RelayError { return relay }
    if error is DecodingError { return .invalidMessage }
    if let pairing = error as? PairingClientError {
      switch pairing {
      case .api(let code): return api(code)
      case .invalidProof: return .untrusted
      default: return .unavailable
      }
    }
    return .transport
  }

  static func api(_ code: String) -> RelayError {
    switch code {
    case "host_offline": return .offline
    case "unauthorized": return .unauthorized
    case "forbidden": return .revoked
    case "rate_limited": return .backpressure
    case "tunnel_unavailable": return .unavailable
    default: return .unavailable
    }
  }
}
