import XCTest
@testable import WitermSSH

final class SSHConfigImportTests: XCTestCase {
    private let config = """
    # Global defaults come first or last; the first value found wins.
    User fallback

    Host web web-alias
        HostName web.example.com
        Port 2222
        IdentityFile ~/.ssh/id_ed25519

    Host bastion
        HostName=bastion.example.com
        User ops

    Host db
        HostName 10.0.0.5
        ProxyJump bastion
        User "data team"

    Host chain
        HostName inner.example.com
        ProxyJump alice@hop1.example.com:2200,[fe80::1]:22

    Match host *.internal
        User ignored

    Host *.example.com !secret.example.com
        Port 2022

    Host *
        User everyone
    """

    func testResolvesFirstValueAndJumpChains() throws {
        let entries = Dictionary(uniqueKeysWithValues: SSHConfigImport.parse(config, defaultUsername: "me").map { ($0.alias, $0) })
        XCTAssertEqual(Set(entries.keys), ["web", "web-alias", "bastion", "db", "chain"])

        let web = try XCTUnwrap(entries["web"]?.profile)
        XCTAssertEqual(web.host.hostname, "web.example.com")
        XCTAssertEqual(web.host.port, 2222)
        XCTAssertEqual(web.host.username, "fallback")
        XCTAssertTrue(web.jumpHosts.isEmpty)

        let db = try XCTUnwrap(entries["db"]?.profile)
        XCTAssertEqual(db.host.username, "fallback", "Options before any Host block apply first")
        XCTAssertEqual(db.jumpHosts.map(\.hostname), ["bastion.example.com"])

        let chain = try XCTUnwrap(entries["chain"]?.profile)
        XCTAssertEqual(chain.jumpHosts.map(\.hostname), ["hop1.example.com", "fe80::1"])
        XCTAssertEqual(chain.jumpHosts.map(\.port), [2200, 22])
        XCTAssertEqual(chain.jumpHosts.first?.username, "alice")
    }

    func testUsernamesThatAreEmailAddresses() throws {
        let text = """
        Host corp
            HostName inner.corp.com
            User first.last@corp.com
            ProxyJump first.last@corp.com@hop1.corp.com:2200,ssh://second%40corp.com@hop2.corp.com/

        Host typo
            HostName inner.corp.com
            ProxyJump first@@hop1.corp.com
        """
        let entries = Dictionary(uniqueKeysWithValues: SSHConfigImport.parse(text, defaultUsername: "me").map { ($0.alias, $0) })
        let corp = try XCTUnwrap(entries["corp"]?.profile)
        XCTAssertEqual(corp.host.username, "first.last@corp.com")
        XCTAssertEqual(corp.jumpHosts.map(\.username), ["first.last@corp.com", "second@corp.com"])
        XCTAssertEqual(corp.jumpHosts.map(\.hostname), ["hop1.corp.com", "hop2.corp.com"])
        XCTAssertEqual(corp.jumpHosts.map(\.port), [2200, 22])
        XCTAssertNil(entries["typo"]?.profile, "An empty part around an @ is not guessed")
    }

    func testPatternsAndDefaultsWithoutGlobalUser() throws {
        let text = """
        Host app
            HostName app.example.com
        Host secret
            HostName secret.example.com
        Host *.example.com app !secret
            Port 2022
        """
        let entries = Dictionary(uniqueKeysWithValues: SSHConfigImport.parse(text, defaultUsername: nil).map { ($0.alias, $0) })
        XCTAssertEqual(entries["app"]?.skipped, .missingUser)
        let named = Dictionary(uniqueKeysWithValues: SSHConfigImport.parse(text, defaultUsername: "me").map { ($0.alias, $0) })
        XCTAssertEqual(named["app"]?.profile?.host.port, 2022)
        XCTAssertEqual(named["secret"]?.profile?.host.port, 22, "A negated pattern excludes the host")
    }

    func testUnusableEntriesAreExplainedNotGuessed() {
        let text = """
        Host loop
            ProxyJump loop
        Host badport
            Port none
        """
        let entries = Dictionary(uniqueKeysWithValues: SSHConfigImport.parse(text, defaultUsername: "me").map { ($0.alias, $0) })
        XCTAssertEqual(entries["loop"]?.skipped, .unsupportedJump)
        XCTAssertEqual(entries["badport"]?.skipped, .invalid)
    }
}
