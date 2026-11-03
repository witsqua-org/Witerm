import XCTest
import WitermSSH
@testable import WitermMac

final class SSHAddressInputTests: XCTestCase {
    private func parsed(_ text: String) -> SSHAddressInput.Parsed? { try? SSHAddressInput.parse(text).get() }
    private func problem(_ text: String) -> SSHAddressInput.Problem? {
        if case .failure(let error) = SSHAddressInput.parse(text) { return error.problem }
        return nil
    }

    func testReadsTheWaysPeopleWriteAddresses() {
        XCTAssertEqual(parsed("deploy@10.0.4.12"), .init(username: "deploy", hostname: "10.0.4.12", port: 22))
        XCTAssertEqual(parsed("  deploy@server.example.com:2222 "), .init(username: "deploy", hostname: "server.example.com", port: 2222))
        XCTAssertEqual(parsed("ssh://pi@raspberrypi.local:22/"), .init(username: "pi", hostname: "raspberrypi.local", port: 22))
        XCTAssertEqual(parsed("ops@[fe80::1]:2200"), .init(username: "ops", hostname: "fe80::1", port: 2200))
        XCTAssertEqual(parsed("ops@fe80::1"), .init(username: "ops", hostname: "fe80::1", port: 22))
        XCTAssertEqual(parsed("first.last@corp@bastion"), .init(username: "first.last@corp", hostname: "bastion", port: 22))
    }

    func testUsernamesThatAreEmailAddresses() {
        // The host starts after the last @, as in OpenSSH.
        XCTAssertEqual(parsed("first.last@corp.com@bastion.example.com"),
                       .init(username: "first.last@corp.com", hostname: "bastion.example.com", port: 22))
        XCTAssertEqual(parsed("first.last@corp.com@[fe80::1]:2200"), .init(username: "first.last@corp.com", hostname: "fe80::1", port: 2200))
        XCTAssertEqual(parsed("first.last@corp.com@10.0.0.5:2222"), .init(username: "first.last@corp.com", hostname: "10.0.0.5", port: 2222))
        // An SSH URI may percent-encode the username's @; a plain address keeps % as typed.
        XCTAssertEqual(parsed("ssh://first.last%40corp.com@bastion:2222/"), .init(username: "first.last@corp.com", hostname: "bastion", port: 2222))
        XCTAssertEqual(parsed("ssh://first.last@corp.com@bastion"), .init(username: "first.last@corp.com", hostname: "bastion", port: 22))
        XCTAssertEqual(parsed("first%40corp@bastion"), .init(username: "first%40corp", hostname: "bastion", port: 22))
        // An empty part around an @ is a typo.
        XCTAssertEqual(problem("@first@bastion"), .invalidUser)
        XCTAssertEqual(problem("first@@bastion"), .invalidUser)
        XCTAssertEqual(problem("first@corp.com@@bastion"), .invalidUser)
        XCTAssertEqual(problem("ssh://first%ZZ@bastion"), .invalidUser)
        XCTAssertEqual(problem("@bastion"), .missingUser)
        XCTAssertEqual(problem("first@corp.com@"), .invalidHost)
    }

    func testExplainsWhatIsMissing() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("server.example.com"), .missingUser)
        XCTAssertEqual(problem("deploy@host:70000"), .invalidPort)
        XCTAssertEqual(problem("deploy@host:ssh"), .invalidPort)
        XCTAssertEqual(problem("deploy@bad host"), .invalidHost)
        XCTAssertEqual(problem("deploy@[fe80::1"), .invalidHost)
    }

    func testFormatRoundTrips() {
        for host in [SSHHost(hostname: "10.0.4.12", username: "deploy"),
                     SSHHost(hostname: "server.example.com", port: 2222, username: "deploy"),
                     SSHHost(hostname: "fe80::1", port: 2200, username: "ops"),
                     SSHHost(hostname: "bastion.example.com", username: "first.last@corp.com"),
                     SSHHost(hostname: "fe80::1", port: 2200, username: "first.last@corp.com")] {
            let text = SSHAddressInput.format(host)
            XCTAssertEqual(parsed(text), .init(username: host.username, hostname: host.hostname, port: host.port), text)
        }
        XCTAssertEqual(SSHAddressInput.format(SSHHost(hostname: "h", username: "u")), "u@h")
    }
}
