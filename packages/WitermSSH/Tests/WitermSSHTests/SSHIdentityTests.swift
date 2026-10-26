import Foundation
import XCTest
@preconcurrency import NIO
@preconcurrency import NIOSSH
@testable import WitermSSH

final class SSHIdentityTests: XCTestCase, @unchecked Sendable {
    // RFC8032 Ed25519 test-vector public key, encoded as an OpenSSH key blob.
    private let blob = "AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea"

    func testVerifierReceivesCanonicalFingerprintAndAuthority() async throws {
        let capture = IdentityCapture()
        let host = SSHHost(hostname: "EXAMPLE.com", port: 2222, username: "test")
        let validator = SSHIdentityValidator(host: host) { await capture.record($0) }
        let key = try NIOSSHPublicKey(openSSHPublicKey: "ssh-ed25519 \(blob)")
        let promise = MultiThreadedEventLoopGroup.singleton.any().makePromise(of: Void.self)
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        try await promise.futureResult.get()
        let actual = await capture.value
        XCTAssertEqual(actual?.authority, "[example.com]:2222")
        XCTAssertEqual(actual?.algorithm, "ssh-ed25519")
        XCTAssertEqual(actual?.publicKey, blob)
        XCTAssertEqual(actual?.fingerprint, "SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8")
    }

    func testRejectedKeyFailsHandshakePromise() async throws {
        let validator = SSHIdentityValidator(host: SSHHost(hostname: "example.com", username: "test")) { _ in
            throw SSHFailure.hostKeyRejected
        }
        let key = try NIOSSHPublicKey(openSSHPublicKey: "ssh-ed25519 \(blob)")
        let promise = MultiThreadedEventLoopGroup.singleton.any().makePromise(of: Void.self)
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        do {
            try await promise.futureResult.get()
            XCTFail("Rejected host key must fail the SSH handshake")
        } catch { XCTAssertEqual(error as? SSHFailure, .hostKeyRejected) }
    }
}

private actor IdentityCapture {
    var value: SSHHostKey?
    func record(_ identity: SSHHostKey) { value = identity }
}
