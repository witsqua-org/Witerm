import Darwin
import Foundation
import XCTest
@preconcurrency import Citadel
@preconcurrency import NIO
@testable import WitermSSH

final class SSHFailureClassificationTests: XCTestCase {
    func testEngineErrorsMapToSpecificFailures() {
        func classified(_ error: Error) -> SSHFailure? { SSHFailure.classify(error) as? SSHFailure }
        XCTAssertEqual(classified(SSHClientError.allAuthenticationOptionsFailed), .authenticationFailed)
        XCTAssertEqual(classified(SSHClientError.unsupportedPasswordAuthentication), .authenticationMethodUnavailable)
        XCTAssertEqual(classified(ChannelError.connectTimeout(.seconds(1))), .timedOut)
        XCTAssertEqual(classified(IOError(errnoCode: ECONNREFUSED, reason: "connect")), .connectionRefused)
        XCTAssertEqual(classified(IOError(errnoCode: EHOSTUNREACH, reason: "connect")), .networkUnreachable)
        XCTAssertEqual(classified(SSHFailure.hostKeyChanged), .hostKeyChanged)
        XCTAssertNil(classified(IOError(errnoCode: EPIPE, reason: "write")))
        XCTAssertTrue(SSHFailure.classify(CancellationError()) is CancellationError)
    }

    func testClosedLoopbackPortReportsConnectionRefused() async throws {
        let port = try Self.closedLoopbackPort()
        let profile = SSHProfile(name: "Refused", host: SSHHost(hostname: "127.0.0.1", port: port, username: "nobody"))
        do {
            _ = try await SSHConnection.connect(profile: profile, credentials: [profile.host.id: .password("unused")]) { _ in
                XCTFail("No host key can be presented by a closed port")
            }
            XCTFail("Closed port accepted a connection")
        } catch { XCTAssertEqual(error as? SSHFailure, .connectionRefused) }
    }

    /// Round 20: every hop's credential is checked before any network. A
    /// chain missing the target's credential (or with an unusable key) used
    /// to connect to the jump host first; here the jump host is a closed
    /// port, so reaching it at all would say "refused".
    func testMissingOrUnusableCredentialFailsBeforeAnyHopIsReached() async throws {
        let port = try Self.closedLoopbackPort()
        let jump = SSHHost(hostname: "127.0.0.1", port: port, username: "nobody")
        let profile = SSHProfile(name: "Chain", host: SSHHost(hostname: "target.invalid", username: "nobody"), jumpHosts: [jump])
        let cases: [(String, [UUID: SSHCredential], SSHFailure)] = [
            ("missing target", [jump.id: .password("unused")], .missingCredential),
            ("unusable key", [jump.id: .password("unused"), profile.host.id: .privateKey("not a key", passphrase: nil)],
             .unsupportedPrivateKey),
        ]
        for (name, credentials, expected) in cases {
            do {
                _ = try await SSHConnection.connect(profile: profile, credentials: credentials) { _ in
                    XCTFail("\(name): no host key can be presented by a closed port")
                }
                XCTFail("\(name): connected")
            } catch { XCTAssertEqual(error as? SSHFailure, expected, name) }
        }
    }

    /// Binds an ephemeral loopback port and releases it, so nothing listens there.
    private static func closedLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHFailure.disconnected }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw SSHFailure.disconnected }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
