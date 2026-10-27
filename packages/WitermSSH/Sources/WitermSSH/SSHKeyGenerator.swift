import Foundation
@preconcurrency import Citadel
import Crypto
@preconcurrency import NIO

/// Ed25519 keys made on this device. The private key is returned to the
/// caller only; storing it is a separate, explicit choice.
public enum SSHKeyGenerator {
    /// A new unencrypted OpenSSH Ed25519 private key and its `authorized_keys` line.
    public static func ed25519(comment: String) -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.makeSSHRepresentation(comment: comment), authorizedKey(key.publicKey, comment: comment))
    }

    /// The `authorized_keys` line for an OpenSSH Ed25519 private key, or nil
    /// when the key can't be read with this passphrase.
    public static func publicKey(forPrivateKey text: String, passphrase: String?, comment: String = "") -> String? {
        guard text.utf8.count <= 1_048_576,
              let key = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: passphrase.map { Data($0.utf8) })
        else { return nil }
        return authorizedKey(key.publicKey, comment: comment)
    }

    /// Whether private key text is an RSA key, which this engine refuses
    /// rather than sign with SHA-1. Lets forms explain it before connecting.
    public static func isRSAPrivateKey(_ text: String) -> Bool {
        guard text.utf8.count <= 1_048_576 else { return false }
        return (try? SSHKeyDetection.detectPrivateKeyType(from: text))?.rawValue == "ssh-rsa"
    }

    private static func authorizedKey(_ key: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = ByteBufferAllocator().buffer(capacity: 51)
        for field in [Array("ssh-ed25519".utf8), Array(key.rawRepresentation)] {
            blob.writeInteger(UInt32(field.count))
            blob.writeBytes(field)
        }
        let encoded = Data(blob.readableBytesView).base64EncodedString()
        let line = "ssh-ed25519 " + encoded
        let label = comment.filter { !$0.isNewline && !$0.isWhitespace || $0 == " " }
        return label.isEmpty ? line : line + " " + label
    }
}
