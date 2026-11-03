import XCTest

/// Round 17, a paired terminal on the simulator through the DEBUG remote
/// fixture's Mac (`FixtureMac`, in memory: no relay server, no Mac, nothing
/// revoked). Hiding the keyboard watches a grid that fills the screen (B1);
/// tapping a watched terminal starts typing when nobody else types there, and
/// keeps watching when someone does (A3); the terminal's menus never open
/// another menu (B3); the background keeps or resumes the terminal (B5).
/// Screenshots go to `WITERM_SHOTS_DIR` when it's set. Prints `PROBE` lines.
@MainActor final class PairedTerminalFixtureTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(extra: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1",
                               "-witerm.serverAddresses", "(\"https://relay.fixture.invalid\")",
                               "-witerm.debug.remoteFixture", "1",
                               "--witerm-ui-test-layout-probe", "--witerm-ui-test-steady-terminal-cursor",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        // The software keyboard's stand-in, where the simulator has a hardware keyboard.
        if ProcessInfo.processInfo.environment["WITERM_SOFT_KEYBOARD"] == "1" {
            app.launchArguments += ["-witerm.debug.softwareKeyboard", "YES"]
        }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
    }

    private var surface: XCUIElement { app.descendants(matching: .any)["remoteTerminalSurface"].firstMatch }
    private var hideKey: XCUIElement { app.buttons["terminalKey-hideKeyboard"] }
    private var keyboardButton: XCUIElement { app.buttons["remoteKeyboard"] }

    private func probe(_ key: String) -> Double? {
        probeText(key).flatMap { Double($0.prefix { $0.isNumber || $0 == "." || $0 == "-" }) }
    }

    /// Read once: the label changes between reads.
    private func probeText(_ key: String) -> String? {
        guard surface.exists else { return nil }
        let label = surface.label
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return String(label[range.upperBound...].prefix { !$0.isWhitespace })
    }

    private func report(_ name: String) {
        print("PROBE \(name): mode=\(probeText("mode") ?? "?") cols=\(probeText("cols") ?? "?") rows=\(probeText("rows") ?? "?") fitRows=\(probeText("fitRows") ?? "?") gap=\(probeText("gap") ?? "?") overflow=\(probeText("overflow") ?? "?") cell=\(probeText("cell") ?? "?") links=\(probeText("links") ?? "?")")
    }

    @discardableResult
    private func until(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    /// Opens one of Studio's fixture terminals from Terminals.
    private func open(_ id: String) {
        let row = app.buttons["remoteSession-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "No fixture terminal \(id)")
        row.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "The terminal didn't open")
    }

    private func waitForTyping() {
        XCTAssertTrue(until(10) { probeText("mode") == "control" && hideKey.exists && hideKey.isHittable },
                      "Not typing: \(probeText("mode") ?? "no probe")")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func waitForWatching() {
        XCTAssertTrue(until(10) { probeText("mode") == "view" && keyboardButton.exists }, "Not watching: \(probeText("mode") ?? "no probe")")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    /// The watched grid fills the text area: as many rows as fit, nothing
    /// blank under it, nothing cut off.
    private func assertGridFillsTheScreen(_ step: String) {
        guard let rows = probe("rows"), let fit = probe("fitRows"), let gap = probe("gap"),
              let overflow = probe("overflow"), let cell = probe("cell") else { return XCTFail("No probe at \(step)") }
        XCTAssertEqual(rows, fit, "\(step): the grid has \(Int(rows)) rows where \(Int(fit)) fit")
        XCTAssertLessThan(gap, cell, "\(step): \(gap) pt blank under the grid")
        XCTAssertLessThan(overflow, 1, "\(step): \(overflow) pt of the grid below the text area")
    }

    // MARK: B1

    /// The owner's black half screen: type, hide the keyboard, and the
    /// watched grid still filled only the part above where the keyboard was.
    func testHidingTheKeyboardWatchesAGridThatFillsTheScreen() {
        launch()
        open("fixture-s1")
        waitForTyping()
        report("typing")
        shot("b1-1-typing")
        hideKey.tap()
        waitForWatching()
        report("watching")
        shot("b1-2-watching")
        assertGridFillsTheScreen("after hiding the keyboard")
        // Again, from the keyboard button: the same rows each time.
        keyboardButton.tap()
        waitForTyping()
        hideKey.tap()
        waitForWatching()
        report("watching again")
        assertGridFillsTheScreen("after hiding it again")
    }

    // MARK: A3

    func testTappingAWatchedTerminalStartsTypingWhenNobodyElseTypes() {
        launch()
        open("fixture-s1")
        waitForTyping()
        hideKey.tap()
        waitForWatching()
        shot("a3-1-watching")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(until(8) { probeText("mode") == "control" && hideKey.exists }, "A tap didn't start typing")
        shot("a3-2-tapped-typing")
    }

    func testTappingWhileSomeoneElseTypesKeepsWatching() {
        launch()
        open("fixture-s2")
        XCTAssertTrue(until(10) { probeText("mode") == "view" }, "Didn't open watching")
        let status = app.descendants(matching: .any)["terminalInputStatus"].firstMatch
        XCTAssertTrue(until(5) { status.exists && status.label.contains("Typing on Studio") }, status.label)
        let links = probe("links")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(probeText("mode"), "view", "A tap took typing from someone else")
        XCTAssertFalse(hideKey.exists)
        XCTAssertEqual(probe("links"), links, "A tap asked the Mac for typing while someone types")
        XCTAssertTrue(status.label.contains("Typing on Studio"), status.label)
        shot("a3-3-someone-else-types")
    }

    // MARK: B3

    /// Text size and colors sit in the actions menu itself: no item opens
    /// another menu.
    func testTerminalActionsMenuNeverOpensAnotherMenu() {
        launch()
        open("fixture-s1")
        waitForTyping()
        hideKey.tap()
        waitForWatching()
        let menu = app.buttons["terminalActionsMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let larger = app.buttons["terminalLargerText"]
        XCTAssertTrue(larger.waitForExistence(timeout: 3), "Larger text isn't in the menu itself")
        shot("b3-1-actions-menu")
        XCTAssertTrue(app.buttons["terminalSmallerText"].exists)
        XCTAssertFalse(app.buttons["terminalTextAndColors"].exists, "Text and Colors is still a submenu")
        for scheme in ["System", "Graphite", "Paper", "Ocean"] {
            XCTAssertTrue(app.buttons[scheme].exists, "\(scheme) isn't in the menu itself")
        }
        // Each item acts: none brings up more items of its own.
        let before = Set(app.buttons.allElementsBoundByIndex.map(\.label))
        app.buttons["Ocean"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let opened = Set(app.buttons.allElementsBoundByIndex.filter(\.isHittable).map(\.label)).subtracting(before)
        XCTAssertTrue(opened.isEmpty, "Choosing a color scheme opened \(opened)")
        XCTAssertFalse(larger.exists && larger.isHittable, "The menu stayed open after choosing a scheme")
        // Put the scheme back.
        menu.tap()
        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 3))
        app.buttons["System"].tap()
    }
}
