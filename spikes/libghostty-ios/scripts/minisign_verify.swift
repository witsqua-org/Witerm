// Minimal minisign verifier (prehashed "ED" signatures): Ed25519 via CryptoKit.
// Usage: swift minisign_verify.swift <pubkey-b64> <file.minisig> <blake2b512-hex-of-file>
import CryptoKit
import Foundation

let a = CommandLine.arguments
func b64(_ s: String) -> Data { Data(base64Encoded: s.trimmingCharacters(in: .whitespaces))! }
let pk = b64(a[1])
precondition(pk.count == 42 && pk.prefix(2) == Data("Ed".utf8))
let lines = try! String(contentsOfFile: a[2], encoding: .utf8).split(separator: "\n").map(String.init)
let sig = b64(lines[1])
precondition(sig.count == 74)
precondition(sig.prefix(2) == Data("ED".utf8), "expected prehashed signature")
precondition(sig[2..<10] == pk[2..<10], "key id mismatch")
let key = try! Curve25519.Signing.PublicKey(rawRepresentation: pk[10..<42])
var hash = Data()
var i = a[3].startIndex
while i < a[3].endIndex {
    let j = a[3].index(i, offsetBy: 2)
    hash.append(UInt8(a[3][i..<j], radix: 16)!)
    i = j
}
let fileOK = key.isValidSignature(sig[10..<74], for: hash)
let tc = lines[2]
precondition(tc.hasPrefix("trusted comment: "))
let global = b64(lines[3])
let globalOK = key.isValidSignature(global, for: Data(sig[10..<74]) + Data(tc.dropFirst("trusted comment: ".count).utf8))
print("file signature:", fileOK ? "VALID" : "INVALID", " global signature:", globalOK ? "VALID" : "INVALID")
exit(fileOK && globalOK ? 0 : 1)
