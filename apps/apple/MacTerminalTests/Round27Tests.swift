import WitermSSH
import XCTest
@testable import WitermMac

/// Round 27: what a search field offers to add, and how a terminal's folder reads.
@MainActor final class Round27Tests: XCTestCase {
    private func profile(_ user: String, _ host: String, _ port: Int = 22, name: String? = nil) -> SSHProfile {
        SSHProfile(name: name ?? "\(user)@\(host)", host: SSHHost(hostname: host, port: port, username: user))
    }

    func testAnUnsavedAddressIsOfferedAndWordsAreNot() {
        let saved = [profile("deploy", "prod.example.com"), profile("root", "10.0.0.5", 2222)]
        XCTAssertEqual(SSHAddressInput.unsavedSuggestion("admin@prod.example.com", saved: saved), "admin@prod.example.com")
        XCTAssertEqual(SSHAddressInput.unsavedSuggestion(" db.example.com:2200 ", saved: saved), "db.example.com:2200")
        XCTAssertEqual(SSHAddressInput.unsavedSuggestion("root@10.0.0.5", saved: saved), "root@10.0.0.5", "Port 22 isn't the saved 2222")
        XCTAssertNil(SSHAddressInput.unsavedSuggestion("deploy@prod.example.com", saved: saved), "Already saved")
        XCTAssertNil(SSHAddressInput.unsavedSuggestion("PROD.example.com", saved: saved), "A bare host matches any saved user")
        XCTAssertNil(SSHAddressInput.unsavedSuggestion("root@10.0.0.5:2222", saved: saved))
        for word in ["build", "new terminal", "", "deploy@", "a b@c.d", "x@host:99999"] {
            XCTAssertNil(SSHAddressInput.unsavedSuggestion(word, saved: saved), word)
        }
    }

    func testFoldersReadFromHome() {
        XCTAssertEqual(LocalTerminalModel.tilde("/Users/someone/src/Witerm", home: "/Users/someone"), "~/src/Witerm")
        XCTAssertEqual(LocalTerminalModel.tilde("/Users/someone", home: "/Users/someone"), "~")
        XCTAssertEqual(LocalTerminalModel.tilde("/Users/someoneelse/x", home: "/Users/someone"), "/Users/someoneelse/x")
        XCTAssertEqual(LocalTerminalModel.tilde("/tmp", home: ""), "/tmp")
    }

    func testPagesAreNotRememberedAsRecentTerminals() {
        XCTAssertFalse(MacDestination.home.isTerminal)
        XCTAssertFalse(MacDestination.devices.isTerminal)
        XCTAssertTrue(MacDestination.local("x").isTerminal)
        XCTAssertEqual(MacDestination.devices.quickOpenID, "place:devices")
    }
}
