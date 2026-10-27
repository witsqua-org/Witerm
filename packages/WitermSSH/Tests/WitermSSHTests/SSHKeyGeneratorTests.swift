import Foundation
import XCTest
@testable import WitermSSH

final class SSHKeyGeneratorTests: XCTestCase {
    func testGeneratedKeyRoundTripsToItsPublicKey() throws {
        let generated = SSHKeyGenerator.ed25519(comment: "witerm test")
        XCTAssertTrue(generated.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(generated.publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        XCTAssertTrue(generated.publicKey.hasSuffix(" witerm test"))
        let derived = try XCTUnwrap(SSHKeyGenerator.publicKey(forPrivateKey: generated.privateKey, passphrase: nil,
                                                              comment: "witerm test"))
        XCTAssertEqual(derived, generated.publicKey)
        XCTAssertNotEqual(SSHKeyGenerator.ed25519(comment: "").privateKey, generated.privateKey)
    }

    func testUnreadableKeyHasNoPublicKey() {
        XCTAssertNil(SSHKeyGenerator.publicKey(forPrivateKey: "not a key", passphrase: nil))
        XCTAssertFalse(SSHKeyGenerator.isRSAPrivateKey(SSHKeyGenerator.ed25519(comment: "").privateKey))
        XCTAssertFalse(SSHKeyGenerator.isRSAPrivateKey("not a key"))
    }

    #if os(macOS)
    /// OpenSSH itself must read the private key and derive the same public key.
    func testOpenSSHReadsGeneratedKey() throws {
        let tool = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("ssh-keygen is unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-keygen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = SSHKeyGenerator.ed25519(comment: "witerm")
        let file = directory.appendingPathComponent("id_ed25519")
        try Data(generated.privateKey.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let process = Process(), output = Pipe()
        process.executableURL = tool
        process.arguments = ["-y", "-f", file.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let derived = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(derived.split(separator: " ").prefix(2), generated.publicKey.split(separator: " ").prefix(2))
    }

    func testRSAKeysAreRecognized() throws {
        let tool = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("ssh-keygen is unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-keygen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("id_rsa")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(SSHKeyGenerator.isRSAPrivateKey(try String(contentsOf: file, encoding: .utf8)))
    }
    #endif

    func testCommentCannotAddLines() {
        let generated = SSHKeyGenerator.ed25519(comment: "a\nb")
        XCTAssertFalse(generated.publicKey.contains("\n"))
    }
}
