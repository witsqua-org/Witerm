import CryptoKit
import Foundation

// Noise rev34, sections 5 and 7. Only XX/25519/ChaChaPoly/SHA256 is supported.
// Deterministic key injection is internal and used only by reference-vector tests.
struct RelayNoiseCipher: Sendable {
  private let key: SymmetricKey
  private(set) var nonce: UInt64 = 0
  private var failed = false
  init(key: Data, nonce: UInt64 = 0) {
    self.key = SymmetricKey(data: key)
    self.nonce = nonce
  }

  private func iv() throws -> ChaChaPoly.Nonce {
    guard !failed, nonce < UInt64.max else { throw RelayError.invalidMessage }
    var little = nonce.littleEndian
    return try ChaChaPoly.Nonce(
      data: Data(repeating: 0, count: 4) + withUnsafeBytes(of: &little) { Data($0) })
  }

  mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
    do {
      guard plaintext.count <= 49_152 else { throw RelayError.invalidMessage }
      let box = try ChaChaPoly.seal(plaintext, using: key, nonce: iv(), authenticating: ad)
      nonce += 1
      return box.ciphertext + box.tag
    } catch {
      failed = true
      throw RelayError.invalidMessage
    }
  }

  mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
    do {
      guard (16...49_168).contains(ciphertext.count) else { throw RelayError.invalidMessage }
      let box = try ChaChaPoly.SealedBox(
        nonce: iv(), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
      let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
      nonce += 1
      return plaintext
    } catch {
      failed = true
      throw RelayError.invalidMessage
    }
  }
}

private struct RelayNoiseSymmetric: Sendable {
  var hash: Data
  var chainingKey: Data
  var cipher: RelayNoiseCipher?

  init(prologue: Data) {
    let name = Data("Noise_XX_25519_ChaChaPoly_SHA256".utf8)
    hash =
      name.count <= 32
      ? name + Data(repeating: 0, count: 32 - name.count) : Data(SHA256.hash(data: name))
    chainingKey = hash
    mixHash(prologue)
  }

  mutating func mixHash(_ value: Data) { hash = Data(SHA256.hash(data: hash + value)) }
  static func hkdf(_ salt: Data, _ input: Data) -> (Data, Data) {
    let temp = SymmetricKey(
      data: Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: salt))))
    let first = Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: temp))
    let second = Data(HMAC<SHA256>.authenticationCode(for: first + Data([2]), using: temp))
    return (first, second)
  }

  mutating func mixKey(_ input: Data) {
    let (ck, key) = Self.hkdf(chainingKey, input)
    chainingKey = ck
    cipher = RelayNoiseCipher(key: key)
  }
  mutating func encrypt(_ payload: Data) throws -> Data {
    let result: Data
    if cipher != nil { result = try cipher!.encrypt(payload, ad: hash) } else { result = payload }
    mixHash(result)
    return result
  }
  mutating func decrypt(_ message: Data) throws -> Data {
    let result: Data
    if cipher != nil { result = try cipher!.decrypt(message, ad: hash) } else { result = message }
    mixHash(message)
    return result
  }
  func split(initiator: Bool) -> (RelayNoiseCipher, RelayNoiseCipher) {
    let (first, second) = Self.hkdf(chainingKey, Data())
    return initiator
      ? (RelayNoiseCipher(key: first), RelayNoiseCipher(key: second))
      : (RelayNoiseCipher(key: second), RelayNoiseCipher(key: first))
  }
}

struct RelayNoiseHandshake: Sendable {
  private let initiator: Bool
  private let staticKey: Curve25519.KeyAgreement.PrivateKey
  private let ephemeral: Curve25519.KeyAgreement.PrivateKey
  private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
  private var remoteStatic: Curve25519.KeyAgreement.PublicKey?
  private var symmetric: RelayNoiseSymmetric
  private var step = 0
  private var failed = false
  var hash: Data { symmetric.hash }

  init(
    initiator: Bool, prologue: Data,
    staticKey: Curve25519.KeyAgreement.PrivateKey = .init(),
    ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
  ) {
    self.initiator = initiator
    self.staticKey = staticKey
    self.ephemeral = ephemeral
    symmetric = RelayNoiseSymmetric(prologue: prologue)
  }

  private func dh(
    _ local: Curve25519.KeyAgreement.PrivateKey, _ remote: Curve25519.KeyAgreement.PublicKey?
  ) throws -> Data {
    guard let remote else { throw RelayError.invalidMessage }
    return try local.sharedSecretFromKeyAgreement(with: remote).withUnsafeBytes { Data($0) }
  }

  mutating func write(payload: Data = Data()) throws -> Data {
    do {
      guard !failed, step < 3, (step % 2 == 0) == initiator, payload.count <= 4096 else {
        throw RelayError.invalidMessage
      }
      var message = Data()
      if step == 0 || step == 1 {
        let e = ephemeral.publicKey.rawRepresentation
        message += e
        symmetric.mixHash(e)
      }
      if step == 1 {
        symmetric.mixKey(try dh(ephemeral, remoteEphemeral))  // ee
        message += try symmetric.encrypt(staticKey.publicKey.rawRepresentation)
        symmetric.mixKey(try dh(staticKey, remoteEphemeral))  // es
      } else if step == 2 {
        message += try symmetric.encrypt(staticKey.publicKey.rawRepresentation)
        symmetric.mixKey(try dh(staticKey, remoteEphemeral))  // se
      }
      message += try symmetric.encrypt(payload)
      step += 1
      return message
    } catch {
      failed = true
      throw RelayError.invalidMessage
    }
  }

  mutating func read(_ message: Data) throws -> Data {
    do {
      guard !failed, step < 3, (step % 2 == 0) != initiator, message.count <= 4200 else {
        throw RelayError.invalidMessage
      }
      var remaining = message
      if step == 0 || step == 1 {
        guard remaining.count >= 32 else { throw RelayError.invalidMessage }
        let e = Data(remaining.prefix(32))
        remaining = Data(remaining.dropFirst(32))
        remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: e)
        symmetric.mixHash(e)
      }
      if step == 1 {
        symmetric.mixKey(try dh(ephemeral, remoteEphemeral))  // ee
      }
      if step == 1 || step == 2 {
        guard remaining.count >= 48 else { throw RelayError.invalidMessage }
        let s = try symmetric.decrypt(Data(remaining.prefix(48)))
        remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: s)
        remaining = Data(remaining.dropFirst(48))
        symmetric.mixKey(try dh(ephemeral, remoteStatic))  // es or se
      }
      let payload = try symmetric.decrypt(remaining)
      step += 1
      return payload
    } catch {
      failed = true
      throw RelayError.invalidMessage
    }
  }

  func split() throws -> (RelayNoiseCipher, RelayNoiseCipher) {
    guard step == 3, !failed else { throw RelayError.invalidMessage }
    return symmetric.split(initiator: initiator)
  }
}
