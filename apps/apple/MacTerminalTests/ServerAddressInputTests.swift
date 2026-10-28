import XCTest
import WitermCore
@testable import WitermMac

final class ServerAddressInputTests: XCTestCase {
    private func address(_ text: String) -> String? { ServerAddressInput(text).address }
    private func problem(_ text: String) -> ServerAddressInput.Problem? { ServerAddressInput(text).problem }

    func testFillsInTheSchemeAndTidiesTheAddress() {
        XCTAssertEqual(address("test.witerm.dev"), "https://test.witerm.dev")
        XCTAssertEqual(address("  Test.Witerm.dev:8443 "), "https://test.witerm.dev:8443")
        XCTAssertEqual(address("https://test.witerm.dev/"), "https://test.witerm.dev")
        XCTAssertEqual(address("https://test.witerm.dev:443"), "https://test.witerm.dev")
        XCTAssertEqual(address("localhost:37429"), "http://localhost:37429")
        XCTAssertEqual(address("127.0.0.1:37429"), "http://127.0.0.1:37429")
        XCTAssertEqual(address("[::1]:37429"), "http://[::1]:37429")
        XCTAssertEqual(address("http://localhost:37429"), "http://localhost:37429")
        // A private-network IP still needs HTTPS, as pairing requires.
        XCTAssertEqual(address("192.168.1.20:37429"), "https://192.168.1.20:37429")
        for text in ["test.witerm.dev", "localhost:37429", "[::1]:37429"] {
            XCTAssertNoThrow(try PairingServerAddress.normalized(XCTUnwrap(address(text))), text)
        }
    }

    func testRecognizesWhatIsntAServer() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("test witerm.dev"), .spaces)
        XCTAssertEqual(problem("deploy@build.example.com"), .sshLogin)
        XCTAssertEqual(ServerAddressInput("deploy@build.example.com").sshAddress, "deploy@build.example.com")
        XCTAssertEqual(problem("ssh://deploy@build.example.com:2222"), .sshPort)
        XCTAssertEqual(ServerAddressInput("ssh://deploy@build.example.com:2222").sshAddress, "deploy@build.example.com:2222")
        XCTAssertEqual(problem("build.example.com:22"), .sshPort)
        XCTAssertEqual(ServerAddressInput("build.example.com:22").sshAddress, "build.example.com")
        XCTAssertEqual(problem("witerm://pair?server=x"), .invitation)
        XCTAssertEqual(problem("ftp://test.witerm.dev"), .unsupportedScheme("ftp"))
        XCTAssertEqual(problem("https://"), .invalid)
    }

    func testOffersAFixThatKeepsTheHost() {
        let path = ServerAddressInput("https://test.witerm.dev/v1/info")
        XCTAssertEqual(path.problem, .path("/v1/info"))
        XCTAssertEqual(path.fix, "https://test.witerm.dev")
        let insecure = ServerAddressInput("http://test.witerm.dev")
        XCTAssertEqual(insecure.problem, .insecure)
        XCTAssertEqual(insecure.fix, "https://test.witerm.dev")
        XCTAssertEqual(ServerAddressInput("http://192.168.1.20:8080").fix, "https://192.168.1.20:8080")
        let credentials = ServerAddressInput("https://user:pw@test.witerm.dev")
        XCTAssertEqual(credentials.problem, .credentials)
        XCTAssertEqual(credentials.fix, "https://test.witerm.dev")
        for text in ["https://test.witerm.dev/v1/info", "http://test.witerm.dev", "https://user:pw@test.witerm.dev"] {
            let fix = try? XCTUnwrap(ServerAddressInput(text).fix)
            XCTAssertNotNil(fix.flatMap { ServerAddressInput($0).address }, "The fix for \(text) isn't usable")
        }
    }
}
