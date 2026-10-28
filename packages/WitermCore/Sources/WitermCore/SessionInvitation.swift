import CryptoKit
import Foundation

/// An invitation to one Mac session for a device that hasn't paired. It uses
/// the pairing endpoints, so the Mac still signs the grant, but the grant
/// reaches only that session, until a time, and only after the recipient
/// proves it holds `proofKey`. That key is in the link and never sent to the
/// server, so a server that sees the join secret still can't redeem it.
///
/// `witerm://share?server=…&id=…&secret=…&host_key=…&access=view|control&until=<unix seconds>&key=…`
public struct SessionInvitation: Sendable, Equatable {
  public let urlString: String
  public let pairingID: String
  public let hostPublicKey: String
  /// The normalized server address the invitation names.
  public let server: String
  public let permission: PairingPermission
  /// When access ends; the Mac also ends it when the session ends.
  public let expiresAt: Date
  let secret: String
  let proofKey: Data

  /// The longest access an invitation may grant.
  public static let longestAccess: TimeInterval = 24 * 60 * 60

  /// Parses and checks a link. The server is not compared with saved ones:
  /// the app asks before using a server it doesn't have.
  public init(urlString: String, now: Date = Date()) throws {
    guard urlString.utf8.count <= 4096,
      let parts = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
      parts.scheme?.lowercased() == "witerm", parts.host?.lowercased() == "share",
      parts.user == nil, parts.password == nil, parts.port == nil,
      parts.fragment == nil, parts.path.isEmpty,
      let items = parts.queryItems, items.count == 7,
      Set(items.map(\.name)) == ["server", "id", "secret", "host_key", "access", "until", "key"]
    else { throw PairingClientError.invalidInvitation }
    let fields = Dictionary(
      uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
    guard fields.count == 7, let rawServer = fields["server"],
      let id = fields["id"].flatMap(PairingEncoding.canonicalID),
      let secret = fields["secret"], PairingEncoding.randomValue(secret) != nil,
      let hostKey = fields["host_key"], PairingEncoding.publicKey(hostKey) != nil,
      let permission = fields["access"].flatMap(PairingPermission.init(rawValue:)),
      let until = fields["until"].flatMap(Int.init), String(until) == fields["until"],
      let key = fields["key"].flatMap(PairingEncoding.randomValue)
    else { throw PairingClientError.invalidInvitation }
    let expiresAt = Date(timeIntervalSince1970: TimeInterval(until))
    guard expiresAt > now, expiresAt.timeIntervalSince(now) <= Self.longestAccess + 60 else {
      throw PairingClientError.invalidInvitation
    }
    let server = try PairingServerAddress.normalized(rawServer).absoluteString
    self = Self.make(
      server: server, pairingID: id, hostKey: hostKey, secret: secret, permission: permission,
      expiresAt: expiresAt, proofKey: key)
  }

  private init(
    urlString: String, pairingID: String, hostPublicKey: String, server: String,
    permission: PairingPermission, expiresAt: Date, secret: String, proofKey: Data
  ) {
    self.urlString = urlString
    self.pairingID = pairingID
    self.hostPublicKey = hostPublicKey
    self.server = server
    self.permission = permission
    self.expiresAt = expiresAt
    self.secret = secret
    self.proofKey = proofKey
  }

  /// A link for a pairing this Mac just created.
  public static func make(
    pairing: PairingInvitation, permission: PairingPermission, expiresAt: Date, proofKey: Data
  ) -> SessionInvitation {
    make(
      server: pairing.serverAddress, pairingID: pairing.pairingID, hostKey: pairing.hostPublicKey,
      secret: pairing.secret, permission: permission,
      expiresAt: Date(timeIntervalSince1970: floor(expiresAt.timeIntervalSince1970)), proofKey: proofKey)
  }

  static func make(
    server: String, pairingID: String, hostKey: String, secret: String,
    permission: PairingPermission, expiresAt: Date, proofKey: Data
  ) -> SessionInvitation {
    var parts = URLComponents()
    parts.scheme = "witerm"
    parts.host = "share"
    parts.queryItems = [
      URLQueryItem(name: "server", value: server), URLQueryItem(name: "id", value: pairingID),
      URLQueryItem(name: "secret", value: secret), URLQueryItem(name: "host_key", value: hostKey),
      URLQueryItem(name: "access", value: permission.rawValue),
      URLQueryItem(name: "until", value: String(Int(expiresAt.timeIntervalSince1970))),
      URLQueryItem(name: "key", value: PairingEncoding.base64URL(proofKey)),
    ]
    return SessionInvitation(
      urlString: parts.string!, pairingID: pairingID, hostPublicKey: hostKey, server: server,
      permission: permission, expiresAt: expiresAt, secret: secret, proofKey: proofKey)
  }

  /// A fresh random proof key for a new invitation.
  public static func newProofKey() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }

  /// The pairing join this invitation carries, for a client on its server.
  public func pairingInvitation() -> PairingInvitation {
    PairingInvitation.make(server: server, pairingID: pairingID, hostKey: hostPublicKey, secret: secret)
  }

  /// What the recipient sends, inside the encrypted channel, to show it
  /// holds the link: bound to the pairing and to its own identity key.
  public func proof(clientPublicKey: String) -> Data {
    Self.proof(key: proofKey, pairingID: pairingID, clientPublicKey: clientPublicKey)
  }

  public static func proof(key: Data, pairingID: String, clientPublicKey: String) -> Data {
    let message = Data("witerm-session-invite-v1\n\(pairingID)\n\(clientPublicKey)".utf8)
    return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
  }

  /// Constant-time check of a recipient's proof.
  public static func verify(proof: Data, key: Data, pairingID: String, clientPublicKey: String) -> Bool {
    let message = Data("witerm-session-invite-v1\n\(pairingID)\n\(clientPublicKey)".utf8)
    return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: key))
  }
}
