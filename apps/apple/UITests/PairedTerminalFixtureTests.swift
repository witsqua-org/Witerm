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

    // MARK: Round 18: the bottom obstruction

    /// The surface's height in points, from the probe's keyboard diagnostics.
    private func surfaceHeight() -> Double? {
        guard let text = probeText("surface") else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0.filter { $0 != "]" }) }
        return parts.count == 4 ? parts[3] : nil
    }

    /// The keyboard's space, from the probe's keyboard diagnostics.
    private func keyboardOverlap() -> Double? {
        guard surface.exists else { return nil }
        let label = surface.label
        guard let range = label.range(of: "kbdiag=[overlap=") else { return nil }
        return Double(label[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    /// What the bottom of the terminal shows that isn't text: the surface's
    /// height less the keyboard's space and the grid's rows on screen. A
    /// reserved strip for the keyboard button, or a grid shorter than the
    /// screen, reads as a band here.
    private func bottomBand() -> (band: Double, cell: Double)? {
        guard let height = surfaceHeight(), let overlap = keyboardOverlap(), let grid = probe("frameH"),
              let shown = probe("boundsH"), let cell = probe("cell") else { return nil }
        return (height - overlap - min(grid, shown), cell)
    }

    private func assertNoBand(_ step: String) {
        guard let measured = bottomBand() else { return XCTFail("No probe at \(step)") }
        print("PROBE r18 band \(step): band=\(String(format: "%.1f", measured.band)) cell=\(measured.cell) rows=\(probeText("rows") ?? "?") fitRows=\(probeText("fitRows") ?? "?") overlap=\(keyboardOverlap() ?? -1) kb=\(keyboardButton.exists ? NSCoder.string(for: keyboardButton.frame) : "none")")
        XCTAssertLessThan(measured.band, measured.cell, "\(step): \(measured.band) pt at the bottom with no text (a band)")
    }

    /// The owner's "obstruction at the bottom": watching, the keyboard
    /// button's strip (60 pt) and the partial row under the grid left an
    /// empty band. The terminal now uses the full height, with the button
    /// floating over it; portrait and landscape, keyboard up and down.
    func testTheTerminalUsesTheFullHeightWithTheKeyboardDown() {
        launch()
        continueAfterFailure = true
        open("fixture-s1")
        waitForTyping()
        shot("r18-1-typing-portrait")
        assertNoBand("typing, portrait")
        hideKey.tap()
        waitForWatching()
        shot("r18-2-watching-portrait")
        assertNoBand("watching, portrait")
        // The floating button lies over the reading text: an accessibility
        // touch at the button (VoiceOver, XCUITest) must find the button.
        XCTAssertTrue(keyboardButton.isHittable, "The text under the keyboard button took its accessibility hit test")
        // The watched grid's last row is fully on screen and nothing is cut off.
        XCTAssertLessThan(probe("overflow") ?? 99, 1)
        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("r18-3-watching-landscape-portrait-grid")
        keyboardButton.tap()
        waitForTyping()
        shot("r18-4-typing-landscape")
        assertNoBand("typing, landscape")
        hideKey.tap()
        waitForWatching()
        shot("r18-5-watching-landscape")
        assertNoBand("watching, landscape")
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        keyboardButton.tap()
        waitForTyping()
        hideKey.tap()
        waitForWatching()
        assertNoBand("watching, portrait again")
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
        // Round 22: another paired device that doesn't type alongside (the
        // fixture's Alex's iPad); the Mac's own window always does, so a tap
        // where only it types starts typing (`TerminalFloatingButtonsTests`).
        launch(extra: ["-witerm.debug.fixtureOtherTyper", "600"])
        open("fixture-s1")
        XCTAssertTrue(until(10) { probeText("mode") == "view" }, "Didn't open watching")
        if app.descendants(matching: .any)["remoteTerminalNotice"].firstMatch.exists {
            app.descendants(matching: .any)["remoteTerminalNotice"].firstMatch.buttons["Dismiss"].tap()
        }
        // Round 20: the title counts who is connected (the iPad types here)
        // and never names who types.
        let status = app.descendants(matching: .any)["terminalInputStatus"].firstMatch
        XCTAssertTrue(until(5) { status.exists && status.label.contains("2 devices connected") }, status.label)
        let links = probe("links")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(probeText("mode"), "view", "A tap took typing from someone else")
        XCTAssertFalse(hideKey.exists)
        XCTAssertEqual(probe("links"), links, "A tap asked the Mac for typing while someone types")
        XCTAssertTrue(status.label.contains("2 devices connected") && !status.label.contains("Typing on"), status.label)
        XCTAssertTrue(app.descendants(matching: .any)["remoteTerminalNotice"].firstMatch.exists, "The tap said nothing")
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
        // What's on screen without the menu, so only new menu items count.
        let chrome = Set(app.buttons.allElementsBoundByIndex.map(\.label))
        menu.tap()
        // Menus drop the identifiers of a control group's buttons: by label too.
        func item(_ id: String, _ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, label)).firstMatch
        }
        let larger = item("terminalLargerText", "Increase Text Size")
        if !larger.waitForExistence(timeout: 3) {
            shot("b3-1-actions-menu-missing")
            print("PROBE menu buttons: " + app.buttons.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }.joined(separator: ", "))
        }
        XCTAssertTrue(larger.exists, "Larger text isn't in the menu itself")
        shot("b3-1-actions-menu")
        XCTAssertTrue(item("terminalSmallerText", "Decrease Text Size").exists)
        XCTAssertTrue(item("terminalTextSize", "14 pt").exists, "The size, between Smaller and Larger")
        XCTAssertFalse(app.buttons["terminalTextAndColors"].exists, "Text and Colors is still a submenu")
        for scheme in ["System", "Graphite", "Paper", "Ocean"] {
            XCTAssertTrue(app.buttons[scheme].exists, "\(scheme) isn't in the menu itself")
        }
        // Each item acts: none brings up more items of its own.
        let before = Set(app.buttons.allElementsBoundByIndex.map(\.label))
        app.buttons["Ocean"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let opened = Set(app.buttons.allElementsBoundByIndex.filter(\.isHittable).map(\.label)).subtracting(before).subtracting(chrome)
        XCTAssertTrue(opened.isEmpty, "Choosing a color scheme opened \(opened)")
        XCTAssertFalse(larger.exists && larger.isHittable, "The menu stayed open after choosing a scheme")
        // Put the scheme back.
        menu.tap()
        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 3))
        app.buttons["System"].tap()
    }

    // MARK: B2

    /// Hide Keyboard is a 44 pt capsule like the keyboard button, and a
    /// swipe down on the key row hides the keyboard (and so watches, with
    /// the grid filling the screen).
    func testSwipeDownOnTheKeyRowHidesTheKeyboard() {
        launch()
        open("fixture-s1")
        waitForTyping()
        XCTAssertEqual(hideKey.frame.width, hideKey.frame.height, accuracy: 1, "Hide Keyboard is round")
        XCTAssertGreaterThanOrEqual(hideKey.frame.width, 44)
        shot("b2-1-key-row")
        let escape = app.buttons["terminalKey-escape"]
        XCTAssertTrue(escape.exists)
        let start = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: .fast, thenHoldForDuration: 0)
        waitForWatching()
        assertGridFillsTheScreen("after a swipe down on the key row")
        // The swipe sent nothing: Esc would have shown as nothing, but the
        // prompt is still the last line.
        XCTAssertTrue((surface.value as? String ?? "").contains("fixture$"))
    }

    // MARK: A1

    /// A Shared with You terminal can end its invitation from the phone:
    /// a swipe or a long press, always confirmed, never a full swipe.
    func testEndingAnInvitationAsksFirstAndRemovesTheRow() {
        launch()
        let row = app.buttons["remoteSession-fixture-a1"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeLeft()
        let swipe = app.buttons["End Invitation…"]
        XCTAssertTrue(swipe.waitForExistence(timeout: 3), "No End Invitation… swipe")
        shot("a1-1-swipe")
        swipe.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertEqual(alert.label, "End Invitation to “Demo”?")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "can’t be undone")).firstMatch.exists,
                      "The confirmation must say it can't be undone")
        shot("a1-2-confirm")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Cancel must keep it")
        // A full swipe only reveals the action.
        row.swipeLeft(velocity: .fast)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(row.exists)
        app.swipeDown()
        row.press(forDuration: 1.2)
        let menuItem = app.buttons["End Invitation…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "No End Invitation… in the long-press menu")
        menuItem.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.firstMatch.buttons["End Invitation"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 3) && row.exists, "The row stays after ending the invitation")
        XCTAssertFalse(app.staticTexts["Shared with You"].exists, "An empty Shared with You stays")
        shot("a1-3-ended")
    }

    // MARK: A2

    /// Announce New Output is in Settings' Terminal group while VoiceOver
    /// runs (DEBUG stand-in for VoiceOver), and only in Advanced otherwise.
    func testAnnounceNewOutputFollowsVoiceOver() {
        for voiceOver in [true, false] {
            launch(extra: voiceOver ? ["-witerm.debug.voiceOverRunning", "YES"] : [])
            app.tabBars.buttons.element(boundBy: 2).tap()
            let toggle = app.switches["terminalAnnounceOutput"]
            XCTAssertEqual(toggle.waitForExistence(timeout: 3), voiceOver, "In the main list: \(voiceOver)")
            shot("a2-settings-voiceover-\(voiceOver)")
            app.buttons["settingsAdvanced"].tap()
            XCTAssertTrue(app.switches["terminalBell"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.switches["terminalAnnounceOutput"].exists, !voiceOver, "In Advanced: \(!voiceOver)")
            app.terminate()
        }
    }

    // MARK: B5

    /// The seconds to stay away, from `WITERM_BG_SECONDS` (default 10 and 60).
    private var awayTimes: [Double] {
        (ProcessInfo.processInfo.environment["WITERM_BG_SECONDS"] ?? "10,60").split(separator: ",").compactMap { Double($0) }
    }

    /// Leaves for `seconds` and returns; then measures how long until the
    /// terminal can be typed in again, whether anything said Disconnected
    /// or Opening on the way, and whether its link was kept or resumed.
    private func away(_ seconds: Double, label: String) -> (usable: Double?, links: Double?, covers: Double?, flashed: Bool) {
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        app.activate()
        let start = Date()
        var flashed = false, usable: Double?
        let disconnected = app.descendants(matching: .any)["remoteDisconnectedStatus"].firstMatch
        let activity = app.descendants(matching: .any)["remoteTerminalActivity"].firstMatch
        while Date().timeIntervalSince(start) < 15 {
            if disconnected.exists || activity.exists { flashed = true }
            if usable == nil, probeText("mode") == "control", probeText("focused") == "1", hideKey.exists {
                usable = Date().timeIntervalSince(start)
            }
            if usable != nil, Date().timeIntervalSince(start) > (usable ?? 0) + 2 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        report("back after \(Int(seconds)) s")
        print("PROBE b5 paired away=\(Int(seconds)) usable=\(usable.map { String(format: "%.2f", $0) } ?? "never") flashed=\(flashed) links=\(probeText("links") ?? "?") covers=\(probeText("covers") ?? "?") coverMs=\(probeText("coverMs") ?? "?")")
        shot("b5-\(label)-back-\(Int(seconds))s")
        return (usable, probe("links"), probe("covers"), flashed)
    }

    /// Returning within 3 minutes continues the same terminal: still typing,
    /// keyboard up, no Disconnected or Opening on the way; a short absence
    /// keeps the same link, a longer one resumes it under the old screen.
    func testReturningWithinThreeMinutesContinuesTheTerminal() {
        executionTimeAllowance = 900
        launch()
        open("fixture-s1")
        waitForTyping()
        for seconds in awayTimes {
            let before = probe("links") ?? 0, rows = probe("rows")
            let result = away(seconds, label: "paired")
            XCTAssertNotNil(result.usable, "Not typing again after \(seconds) s away")
            XCTAssertFalse(result.flashed, "Disconnected or Opening showed after \(seconds) s away")
            XCTAssertEqual(probe("rows"), rows, "The grid changed")
            if seconds < 20 {
                XCTAssertEqual(result.links, before, "A short absence must keep the same link")
            } else {
                XCTAssertEqual(result.links, before + 1, "A longer absence resumes with one new link")
                XCTAssertGreaterThan(probe("coverMs") ?? 0, 0, "The old screen must cover the redraw")
            }
            XCTAssertTrue((surface.value as? String ?? "").contains("fixture$"), "The screen is blank")
        }
    }

    /// Past 3 minutes the terminal was let go: returning reconnects as before.
    /// Opt-in (`WITERM_BG_LONG=1`): it waits 190 s.
    func testReturningAfterThreeMinutesReconnects() throws {
        guard ProcessInfo.processInfo.environment["WITERM_BG_LONG"] == "1" else { throw XCTSkip("Set WITERM_BG_LONG=1") }
        executionTimeAllowance = 600
        launch()
        open("fixture-s1")
        waitForTyping()
        let before = probe("links") ?? 0
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(190))
        app.activate()
        let start = Date()
        XCTAssertTrue(until(20) { probeText("mode") == "control" && (probe("links") ?? 0) > before }, "Didn't reconnect")
        print("PROBE b5 paired away=190 reconnected=\(String(format: "%.2f", Date().timeIntervalSince(start))) links=\(probeText("links") ?? "?")")
        shot("b5-paired-back-190s")
    }
}
