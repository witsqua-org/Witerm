import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol PairingSecureStore: Sendable {
  func read(account: String) throws -> Data?
  func create(_ data: Data, account: String) throws -> Bool
  func write(_ data: Data, account: String) throws
  func delete(account: String) throws
}

struct KeychainPairingStore: PairingSecureStore {
  private let service = "com.witerm.pairing.v1"

  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  func read(account: String) throws -> Data? {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    request[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw PairingClientError.identityUnavailable
    }
    return data
  }

  func create(_ data: Data, account: String) throws -> Bool {
    var request = query(account)
    request[kSecValueData as String] = data
    request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(request as CFDictionary, nil)
    if status == errSecDuplicateItem { return false }
    guard status == errSecSuccess else { throw PairingClientError.identityUnavailable }
    return true
  }

  func write(_ data: Data, account: String) throws {
    let status = SecItemUpdate(
      query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      if !(try create(data, account: account)) {
        guard
          SecItemUpdate(
            query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            == errSecSuccess
        else {
          throw PairingClientError.identityUnavailable
        }
      }
    } else if status != errSecSuccess {
      throw PairingClientError.identityUnavailable
    }
  }

  func delete(account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PairingClientError.identityUnavailable
    }
  }
}

struct PairingIdentity: Sendable {
  private let key: Curve25519.Signing.PrivateKey
  var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

  static func account(server: String) -> String {
    let digest = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
    return "device-signing-key-\(digest)"
  }

  init(store: any PairingSecureStore, account: String = "device-signing-key") throws {
    do {
      if let existing = try store.read(account: account) {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: existing)
        return
      }
      let candidate = Curve25519.Signing.PrivateKey()
      if try store.create(candidate.rawRepresentation, account: account) {
        key = candidate
      } else {
        // Another foreground client won creation. Never overwrite it.
        guard let existing = try store.read(account: account) else {
          throw PairingClientError.identityUnavailable
        }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: existing)
      }
    } catch {
      throw PairingClientError.identityUnavailable
    }
  }

  func sign(_ message: Data) throws -> String {
    try key.signature(for: message).base64EncodedString()
  }
}

enum PairingProof {
  static func validateDevice(_ device: PairedDevice) throws {
    guard PairingEncoding.canonicalID(device.id) == device.id,
      PairingEncoding.publicKey(device.publicKey) != nil,
      !device.name.isEmpty, device.name.unicodeScalars.count <= 64,
      device.name == device.name.trimmingCharacters(in: .whitespacesAndNewlines),
      !device.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw PairingClientError.invalidProof
    }
  }

  static func validateGrant(_ grant: DeviceGrant, identity: PairedDevice, pinnedHostKey: String?)
    throws
  {
    try validateDevice(grant.host)
    try validateDevice(grant.client)
    guard PairingEncoding.canonicalID(grant.id) == grant.id,
      PairingEncoding.canonicalID(grant.pairingID) == grant.pairingID,
      grant.host.platform == .macos, grant.client.platform == .ios,
      grant.host.id != grant.client.id,
      grant.host.publicKey != grant.client.publicKey,
      let hostBytes = PairingEncoding.publicKey(grant.host.publicKey),
      let signature = PairingEncoding.signature(grant.approvalSignature)
    else {
      throw PairingClientError.invalidProof
    }
    switch identity.platform {
    case .macos:
      guard grant.host.id == identity.id, grant.host.publicKey == identity.publicKey else {
        throw PairingClientError.invalidProof
      }
    case .ios:
      guard grant.client.id == identity.id, grant.client.publicKey == identity.publicKey,
        pinnedHostKey == grant.host.publicKey
      else { throw PairingClientError.invalidProof }
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: hostBytes)
    let message = PairingEncoding.approvalMessage(
      pairingID: grant.pairingID, hostKey: grant.host.publicKey, clientKey: grant.client.publicKey,
      permission: grant.permission)
    guard key.isValidSignature(signature, for: message) else {
      throw PairingClientError.invalidProof
    }
  }
}

struct PairingTrustLedger: Codable {
  var pinnedHosts: [String: String] = [:]
  var grants: [String: DeviceGrant] = [:]
  var revokedPairings: Set<String> = []

  static func account(server: String, publicKey: String) -> String {
    let digest = SHA256.hash(data: Data("\(server)\n\(publicKey)".utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return "trust-\(digest)"
  }
}
