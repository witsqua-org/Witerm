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
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-witerm.serverAddresses", "(\"\(server)\")", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // A blinking caret never lets XCTest see the app idle.
                               "--witerm-ui-test-steady-terminal-cursor"]
        app.launch()
        func shot(_ label: String) { try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("probe-\(label).png")) }
        app.tabBars.buttons["Terminals"].tap()
        // Each paired Mac's terminals are listed in its own section.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "remoteSession-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        // Open: the keyboard's Hide key when typing, the keyboard button when not.
        let keyboardButton = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["remoteKeyboard", "terminalKey-hideKeyboard"])).firstMatch
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 30))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("1-following")
        let started = Date()
        // The keyboard comes up with the connection; the button brings it back if not.
        if !app.keyboards.firstMatch.exists { app.toggleTerminalKeyboard() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.keyboards.firstMatch.keys["e"].tap()
        let elapsed = Date().timeIntervalSince(started)
        shot("2-typed")
        try? Data(String(format: "%.1f", elapsed).utf8).write(to: folder.appendingPathComponent("probe-seconds"))
        XCTAssertLessThan(elapsed, 15, "The terminal stayed busy after the keyboard appeared")
    }

    /// Round 24: opens an already paired Mac's session named
    /// WITERM_PROBE_SESSION (a name with the "HCI " test prefix), stays
    /// WITERM_PROBE_WAIT seconds so output arriving meanwhile (a Codex-like
    /// tool's reply) reaches the terminal live, then drags back through the
    /// scrollback, saving the screen at the bottom and after each drag into
    /// WITERM_E2E_DIR. It types nothing.
    func testScrollBackThroughASession() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["WITERM_E2E_SERVER"], let name = environment["WITERM_PROBE_SESSION"], name.hasPrefix("HCI "),
              let directory = environment["WITERM_E2E_DIR"] else { throw XCTSkip("Opt-in probe") }
        continueAfterFailure = false
        let folder = URL(fileURLWithPath: directory)
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-witerm.serverAddresses", "(\"\(server)\")", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "--witerm-ui-test-steady-terminal-cursor"]
        app.launch()
        func shot(_ label: String) { try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("scroll-\(label).png")) }
        app.tabBars.buttons["Terminals"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "remoteSession-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(name) isn't listed: is this simulator paired with the Mac?")
        row.tap()
        let surface = app.descendants(matching: .any)["remoteTerminalSurface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        // The keyboard would cover half the screen; watching needs none.
        if app.keyboards.firstMatch.exists { app.toggleTerminalKeyboard() }
        RunLoop.current.run(until: Date().addingTimeInterval(Double(environment["WITERM_PROBE_WAIT"] ?? "") ?? 3))
        shot("0-bottom")
        for step in 1...6 {
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            shot("\(step)-up")
        }
    }
}
