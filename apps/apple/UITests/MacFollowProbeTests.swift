import XCTest

/// Opt-in probe for an already paired Mac: opens the session named
/// WITERM_PROBE_SESSION while another writer owns a wider grid, shows the
/// keyboard, and types, so a stuck or busy terminal shows up as slow keys.
@MainActor
final class MacFollowProbeTests: XCTestCase {
    func testTypingWhileFollowingAWiderGrid() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["WITERM_E2E_SERVER"], let name = environment["WITERM_PROBE_SESSION"],
              let directory = environment["WITERM_E2E_DIR"] else { throw XCTSkip("Opt-in probe") }
        let folder = URL(fileURLWithPath: directory)
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.serverAddresses", "(\"\(server)\")", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // A blinking caret never lets XCTest see the app idle.
                               "--witerm-ui-test-steady-terminal-cursor"]
        app.launch()
        func shot(_ label: String) { try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("probe-\(label).png")) }
        app.tabBars.buttons["Terminals"].tap()
        let mac = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remoteMac-")).firstMatch
        XCTAssertTrue(mac.waitForExistence(timeout: 30))
        mac.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "remoteSession-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(app.buttons["remoteKeyboard"].waitForExistence(timeout: 30))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("1-following")
        let started = Date()
        app.buttons["remoteKeyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.keyboards.firstMatch.keys["e"].tap()
        let elapsed = Date().timeIntervalSince(started)
        shot("2-typed")
        try? Data(String(format: "%.1f", elapsed).utf8).write(to: folder.appendingPathComponent("probe-seconds"))
        XCTAssertLessThan(elapsed, 15, "The terminal stayed busy after the keyboard appeared")
    }
}
