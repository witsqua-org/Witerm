import CryptoKit
import Foundation

public enum DevicePlatform: String, Codable, Sendable { case macos, ios }
public enum PairingPermission: String, Codable, Sendable { case view, control }
public enum PairingStatus: String, Codable, Sendable {
  case waiting, pending, approved, rejected, expired
}

public enum PairingClientError: Error, Sendable, Equatable {
  case invalidServer
  case insecureTransport
  case invalidDeviceName
  case invalidInvitation
  case serverMismatch
  case identityUnavailable
  case invalidProof
  case api(code: String)
  case invalidResponse
}

public struct PairedDevice: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public let platform: DevicePlatform
  public let publicKey: String

  public init(id: String, name: String, platform: DevicePlatform, publicKey: String) {
    self.id = id
    self.name = name
    self.platform = platform
    self.publicKey = publicKey
  }

  enum CodingKeys: String, CodingKey {
    case id, name, platform
    case publicKey = "public_key"
  }
}

public struct DeviceGrant: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let pairingID: String
  public let host: PairedDevice
  public let client: PairedDevice
  public let permission: PairingPermission
  public let approvalSignature: String
  public let createdAt: Date

  public init(
    id: String, pairingID: String, host: PairedDevice, client: PairedDevice,
    permission: PairingPermission, approvalSignature: String, createdAt: Date
  ) {
    self.id = id
    self.pairingID = pairingID
    self.host = host
    self.client = client
    self.permission = permission
    self.approvalSignature = approvalSignature
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id, host, client, permission
    case pairingID = "pairing_id"
    case approvalSignature = "approval_signature"
    case createdAt = "created_at"
  }
}

public struct DevicePairing: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let status: PairingStatus
  public let expiresAt: Date
  public let host: PairedDevice
  public let client: PairedDevice?
  public let grant: DeviceGrant?

  public init(
    id: String, status: PairingStatus, expiresAt: Date, host: PairedDevice, client: PairedDevice?,
    grant: DeviceGrant?
  ) {
    self.id = id
    self.status = status
    self.expiresAt = expiresAt
    self.host = host
    self.client = client
    self.grant = grant
  }

  enum CodingKeys: String, CodingKey {
    case id, status, host, client, grant
    case expiresAt = "expires_at"
  }
}

public enum PairingFingerprint {
  public static func display(publicKey: String) -> String {
    guard let bytes = PairingEncoding.publicKey(publicKey) else { return "—" }
    let hex = SHA256.hash(data: bytes).prefix(8).map { String(format: "%02X", $0) }.joined()
    return stride(from: 0, to: hex.count, by: 4).map { offset in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      let end = hex.index(start, offsetBy: 4)
      return String(hex[start..<end])
    }.joined(separator: " ")
  }
}

enum PairingEncoding {
  static func publicKey(_ value: String) -> Data? {
    guard let data = Data(base64Encoded: value), data.count == 32,
      data.base64EncodedString() == value
    else { return nil }
    return data
  }

  static func signature(_ value: String) -> Data? {
    guard let data = Data(base64Encoded: value), data.count == 64,
      data.base64EncodedString() == value
    else { return nil }
    return data
  }

  static func randomValue(_ value: String) -> Data? {
    guard value.count == 43,
      value.unicodeScalars.allSatisfy({
        CharacterSet(
          charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        ).contains($0)
      })
    else { return nil }
    let base64 =
      value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
    guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
    let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return encoded == value ? data : nil
  }

  /// Unpadded Base64URL, the encoding `randomValue` accepts.
  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  static func canonicalID(_ value: String) -> String? {
    UUID(uuidString: value)?.uuidString.lowercased()
  }

  static func registrationMessage(
    challengeID: String, nonce: String, name: String, platform: DevicePlatform
  ) -> Data {
    Data("witerm-device-v1\n\(challengeID)\n\(nonce)\n\(name)\n\(platform.rawValue)".utf8)
  }

  static func approvalMessage(
    pairingID: String, hostKey: String, clientKey: String, permission: PairingPermission
  ) -> Data {
    Data("witerm-pair-v1\n\(pairingID)\n\(hostKey)\n\(clientKey)\n\(permission.rawValue)".utf8)
  }
}

/// The canonical form of a server address: identities, grants and relay
/// settings are keyed by it, so two spellings of one server are one server.
public enum PairingServerAddress {
  public static func normalized(_ address: String) throws -> URL {
    let base: URL
    do { base = try ServerClient.validatedURL(for: address) } catch {
      throw PairingClientError.invalidServer
    }
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased()
    else {
      throw PairingClientError.invalidServer
    }
    if let port = components.port, !(1...65535).contains(port) {
      throw PairingClientError.invalidServer
    }
    if scheme == "http" {
      let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      let parts = unbracketed.split(separator: ".", omittingEmptySubsequences: false)
      let loopback4 =
        parts.count == 4 && parts.first == "127"
        && parts.allSatisfy { part in
          guard let value = Int(part), String(value) == part else { return false }
          return (0...255).contains(value)
        }
      guard host == "localhost" || unbracketed == "::1" || loopback4 else {
        throw PairingClientError.insecureTransport
      }
    }
    components.scheme = scheme
    components.host = host
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80)
    {
      components.port = nil
    }
    components.path = ""
    guard let url = components.url else { throw PairingClientError.invalidServer }
    return url
  }
}

public struct PairingInvitation: Sendable, Equatable {
  public let urlString: String
  public let pairingID: String
  public let hostPublicKey: String
  let serverAddress: String
  let secret: String

  public init(urlString: String, expectedServer: String) throws {
    guard urlString.utf8.count <= 4096,
      let parts = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
      parts.scheme?.lowercased() == "witerm", parts.host?.lowercased() == "pair",
      parts.user == nil, parts.password == nil, parts.port == nil,
      parts.fragment == nil, parts.path.isEmpty,
      let items = parts.queryItems, items.count == 4,
      Set(items.map(\.name)) == Set(["server", "id", "secret", "host_key"])
    else {
      throw PairingClientError.invalidInvitation
    }
    let fields = Dictionary(
      uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
    guard fields.count == 4, let rawServer = fields["server"], let rawID = fields["id"],
      let id = PairingEncoding.canonicalID(rawID), let secret = fields["secret"],
      PairingEncoding.randomValue(secret) != nil, let hostKey = fields["host_key"],
      PairingEncoding.publicKey(hostKey) != nil
    else { throw PairingClientError.invalidInvitation }
    let server = try PairingServerAddress.normalized(rawServer)
    guard server == (try PairingServerAddress.normalized(expectedServer)) else {
      throw PairingClientError.serverMismatch
    }
    self = Self.make(server: server.absoluteString, pairingID: id, hostKey: hostKey, secret: secret)
  }

  private init(
    validatedURL: String, pairingID: String, hostKey: String, server: String, secret: String
  ) {
    self.urlString = validatedURL
    self.pairingID = pairingID
    self.hostPublicKey = hostKey
    self.serverAddress = server
    self.secret = secret
  }

  static func make(server: String, pairingID: String, hostKey: String, secret: String) -> Self {
    var parts = URLComponents()
    parts.scheme = "witerm"
    parts.host = "pair"
    parts.queryItems = [
      URLQueryItem(name: "server", value: server), URLQueryItem(name: "id", value: pairingID),
      URLQueryItem(name: "secret", value: secret), URLQueryItem(name: "host_key", value: hostKey),
    ]
    return Self(
      validatedURL: parts.string!, pairingID: pairingID, hostKey: hostKey, server: server,
      secret: secret)
  }
}
