import XCTest

/// Round 18, through the DEBUG remote fixture's Mac (`FixtureMac`, in
/// memory; nothing revoked): Back keeps a paired terminal connected and
/// reopening it is instant (the same link, no redraw); its row says
/// Connected; Disconnect is a trailing swipe (never a full one), the
/// long-press menu and the terminal's ⋯ menu, where Leave was; at most
/// three stay connected; the Mac ending a kept terminal takes its row away;
/// unpairing lets kept terminals go. Prints `PROBE` lines (links opened,
/// memory). Screenshots go to `WITERM_SHOTS_DIR` when it's set.
@MainActor final class PairedKeepConnectedTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch() {
        continueAfterFailure = false
        app = XCUIApplication()
        // One snippet, `exit`, sent from the key row's Snippets key.
        let snippet = #"[{"id":"5A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C40","name":"Exit","text":"exit","runsImmediately":true}]"#
        let hex = Data(snippet.utf8).map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1",
                               "-witerm.serverAddresses", "(\"https://relay.fixture.invalid\")",
                               "-witerm.debug.remoteFixture", "1", "-witerm.commandSnippets", "<\(hex)>",
                               "--witerm-ui-test-layout-probe", "--witerm-ui-test-steady-terminal-cursor",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if ProcessInfo.processInfo.environment["WITERM_SOFT_KEYBOARD"] == "1" {
            app.launchArguments += ["-witerm.debug.softwareKeyboard", "YES"]
        }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
    }

    private var surface: XCUIElement { app.descendants(matching: .any)["remoteTerminalSurface"].firstMatch }
    private func row(_ id: String) -> XCUIElement { app.buttons["remoteSession-\(id)"] }
    private func connectedBadge(_ id: String) -> XCUIElement { app.descendants(matching: .any)["remoteSessionConnected-\(id)"] }
    private var back: XCUIElement { app.buttons["remoteSessionList"] }

    private func probeText(_ key: String) -> String? {
        guard surface.exists else { return nil }
        let label = surface.label
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return String(label[range.upperBound...].prefix { !$0.isWhitespace })
    }
    private func probe(_ key: String) -> Double? { probeText(key).flatMap { Double($0.prefix { $0.isNumber || $0 == "." }) } }

    @discardableResult
    private func until(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
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

    private func open(_ id: String) {
        if !row(id).waitForExistence(timeout: 15) { shot("missing-\(id)") }
        XCTAssertTrue(row(id).exists, "No fixture terminal \(id)")
        row(id).tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "\(id) didn't open")
        XCTAssertTrue(until(10) { probeText("mode") != nil && !app.descendants(matching: .any)["remoteTerminalActivity"].exists })
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    private func goBack() {
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remoteSession-")).firstMatch.waitForExistence(timeout: 5),
                      "Back didn't return to Terminals")
    }

    // MARK: Back keeps it connected

    /// Typing, then Back: the list shows at once, the row says Connected,
    /// and reopening shows the same terminal with no new link and no cover.
    func testBackKeepsTheTerminalConnectedAndReopensInstantly() {
        launch()
        open("fixture-s1")
        XCTAssertTrue(until(10) { probeText("mode") == "control" }, "Not typing")
        let before = probe("links") ?? -1
        let started = Date()
        goBack()
        let backIn = Date().timeIntervalSince(started)
        XCTAssertTrue(connectedBadge("fixture-s1").waitForExistence(timeout: 3), "Back didn't keep the terminal connected")
        shot("r18-keep-1-back-connected")
        // Back never waits for the Mac (no Leaving… or Disconnecting…).
        XCTAssertFalse(app.descendants(matching: .any)["remoteTerminalActivity"].exists, "Back waited for the connection")
        // Typing was let go: a watching link replaced the typing one.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let reopenStart = Date()
        row("fixture-s1").tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 2), "Reopening wasn't instant")
        let reopenIn = Date().timeIntervalSince(reopenStart)
        XCTAssertFalse(app.descendants(matching: .any)["remoteTerminalActivity"].exists, "Reopening showed Opening…")
        XCTAssertEqual(probeText("mode"), "view", "Reopened watching, the keyboard down")
        XCTAssertEqual(probe("links"), before + 1, "Reopening made a new link (only the watching one after Back may exist)")
        XCTAssertEqual(probe("covers"), 0, "Reopening covered a redraw")
        XCTAssertTrue((surface.value as? String ?? "").contains("fixture$"), "The screen is blank")
        print("PROBE r18 keep back=\(String(format: "%.2f", backIn))s reopen=\(String(format: "%.2f", reopenIn))s links=\(probeText("links") ?? "?") mem=\(probeText("mem") ?? "?")")
        shot("r18-keep-2-reopened")
        // The keyboard button types again, as usual.
        app.buttons["remoteKeyboard"].tap()
        XCTAssertTrue(until(10) { probeText("mode") == "control" }, "The keyboard button didn't type")
    }

    // MARK: Disconnect

    func testDisconnectIsASwipeAMenuItemAndInTheTerminalMenu() {
        launch()
        open("fixture-s1")
        goBack()
        XCTAssertTrue(connectedBadge("fixture-s1").waitForExistence(timeout: 3))
        // A full swipe only reveals it.
        row("fixture-s1").swipeLeft(velocity: .fast)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(connectedBadge("fixture-s1").exists, "A full swipe disconnected")
        app.swipeDown()
        row("fixture-s1").swipeLeft()
        let swipe = app.buttons["Disconnect"]
        XCTAssertTrue(swipe.waitForExistence(timeout: 3), "No Disconnect swipe")
        XCTAssertFalse(app.buttons["Delete"].exists)
        shot("r18-disconnect-1-swipe")
        swipe.tap()
        XCTAssertTrue(until(5) { !connectedBadge("fixture-s1").exists }, "Still Connected after Disconnect")
        // A row that isn't connected has no swipe actions at all (a swipe
        // there opens it, like a tap), so nothing to check by swiping.
        // The long-press menu.
        open("fixture-s1")
        goBack()
        XCTAssertTrue(connectedBadge("fixture-s1").waitForExistence(timeout: 3))
        row("fixture-s1").press(forDuration: 1.2)
        let item = app.buttons["Disconnect"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "No Disconnect in the long-press menu")
        shot("r18-disconnect-2-menu")
        item.tap()
        XCTAssertTrue(until(5) { !connectedBadge("fixture-s1").exists })
        // The terminal's ⋯ menu: Disconnect where Leave was.
        open("fixture-s1")
        if app.buttons["terminalKey-hideKeyboard"].exists { app.buttons["terminalKey-hideKeyboard"].tap() }
        XCTAssertTrue(until(10) { probeText("mode") == "view" })
        app.buttons["terminalActionsMenu"].tap()
        let menuItem = app.buttons["detachRemoteTerminal"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3))
        XCTAssertEqual(menuItem.label, "Disconnect")
        XCTAssertFalse(app.buttons["Leave"].exists, "Leave is still in the menu")
        shot("r18-disconnect-3-terminal-menu")
        menuItem.tap()
        XCTAssertTrue(row("fixture-s1").waitForExistence(timeout: 5), "Disconnect didn't return to Terminals")
        XCTAssertTrue(until(3) { !connectedBadge("fixture-s1").exists }, "Still Connected after the menu's Disconnect")
        shot("r18-disconnect-4-list")
    }

    // MARK: The limit

    /// Three stay connected; opening a fourth disconnects the one left
    /// longest ago and says which.
    func testOpeningAFourthDisconnectsTheOldest() {
        launch()
        var memory: [String] = []
        for id in ["fixture-s1", "fixture-s2", "fixture-s3"] {
            open(id)
            memory.append(probeText("mem") ?? "?")
            goBack()
            XCTAssertTrue(connectedBadge(id).waitForExistence(timeout: 3), "\(id) wasn't kept")
        }
        open("fixture-m1")
        memory.append(probeText("mem") ?? "?")
        let note = app.descendants(matching: .any)["remoteKeptNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "No note about the terminal disconnected")
        XCTAssertTrue(note.label.contains("Terminal 1"), note.label)
        shot("r18-limit-1-note")
        print("PROBE r18 limit mem=\(memory.joined(separator: ","))")
        goBack()
        XCTAssertTrue(connectedBadge("fixture-m1").waitForExistence(timeout: 3))
        XCTAssertTrue(connectedBadge("fixture-s2").exists)
        XCTAssertTrue(connectedBadge("fixture-s3").exists)
        XCTAssertFalse(connectedBadge("fixture-s1").exists, "The oldest is still connected")
        shot("r18-limit-2-three-connected")
    }

    // MARK: The Mac ends it

    func testTheMacEndingAKeptTerminalTakesItsRowAway() {
        launch()
        open("fixture-s1")
        XCTAssertTrue(until(10) { probeText("mode") == "control" })
        // `exit` ends the fixture’s terminal 10 s later.
        let key = app.buttons["terminalKey-snippets"]
        for _ in 0..<6 where !(key.exists && key.isHittable) {
            let escape = app.buttons["terminalKey-escape"]
            let start = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
        }
        key.tap()
        let exit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Exit")).firstMatch
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        exit.tap()
        goBack()
        XCTAssertTrue(connectedBadge("fixture-s1").waitForExistence(timeout: 2), "Not kept")
        XCTAssertTrue(until(20) { !row("fixture-s1").exists }, "The ended terminal is still listed")
        shot("r18-ended-1-row-gone")
    }

    // MARK: Unpairing

    func testUnpairingLetsKeptTerminalsGo() {
        launch()
        open("fixture-s2")
        goBack()
        XCTAssertTrue(connectedBadge("fixture-s2").waitForExistence(timeout: 3))
        app.tabBars.buttons.element(boundBy: 1).tap()
        let details = app.buttons["deviceDetails-fixture-studio"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        app.buttons["unpairDevice"].tap()
        app.alerts.firstMatch.buttons["Unpair"].tap()
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(until(8) { !row("fixture-s2").exists && !connectedBadge("fixture-s2").exists }, "Studio's kept terminal stayed")
        shot("r18-unpair-1-gone")
    }
}
