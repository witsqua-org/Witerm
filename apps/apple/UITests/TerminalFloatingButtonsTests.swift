import XCTest

/// Round 22, the owner's findings on the iPhone 17 Pro, on a paired terminal
/// through the DEBUG fixture Mac (`FixtureMac`): one tap on the text shows
/// the keyboard, also where the Mac's own window types (it always types
/// alongside), with a spinner on the keyboard button while the Mac is
/// asked; the keyboard button shows as soon as the keyboard is down; the
/// floating buttons and Hide Keyboard share one column; and hiding the
/// keyboard is one transition (the grid fills the screen before the
/// keyboard has gone, and the watching renderer lands every row where the
/// typing one had it). The SSH side is `SSHFloatingButtonsTests`. Prints
/// `PROBE` lines. Screenshots go to `WITERM_SHOTS_DIR` when it's set.
@MainActor final class TerminalFloatingButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(extra: [String] = []) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1",
                               "-witerm.serverAddresses", "(\"https://relay.fixture.invalid\")",
                               "-witerm.debug.remoteFixture", "1",
                               "--witerm-ui-test-layout-probe", "--witerm-ui-test-steady-terminal-cursor",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        if ProcessInfo.processInfo.environment["WITERM_SOFT_KEYBOARD"] == "1" {
            app.launchArguments += ["-witerm.debug.softwareKeyboard", "YES"]
        }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { [app] in
            await MainActor.run {
                XCUIDevice.shared.orientation = .portrait
                app?.terminate()
            }
        }
    }

    private var surface: XCUIElement { app.descendants(matching: .any)["remoteTerminalSurface"].firstMatch }
    private var hideKey: XCUIElement { app.buttons["terminalKey-hideKeyboard"] }
    private var keyboardButton: XCUIElement { app.buttons["remoteKeyboard"] }
    private var latest: XCUIElement { app.buttons["terminalJumpToLatest"] }
    private var notice: XCUIElement { app.descendants(matching: .any)["remoteTerminalNotice"].firstMatch }

    private func probeText(_ key: String) -> String? {
        guard surface.exists else { return nil }
        return TerminalProbeLabel.text(surface.label, key)
    }

    private func probe(_ key: String) -> Double? {
        probeText(key).flatMap { Double($0.prefix { $0.isNumber || $0 == "." || $0 == "-" }) }
    }

    @discardableResult
    private func until(_ timeout: TimeInterval, poll: TimeInterval = 0.05, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        return condition()
    }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

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
        let row = app.buttons["remoteSession-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "No fixture terminal \(id)")
        row.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "The terminal didn't open")
    }

    private var typing: Bool { probeText("mode") == "control" && hideKey.exists && hideKey.isHittable }
    private var watching: Bool { probeText("mode") == "view" && keyboardButton.exists }

    private func waitForTyping(_ step: String = "") {
        XCTAssertTrue(until(10) { typing }, "Not typing \(step): \(probeText("mode") ?? "no probe")")
        pause(0.8)
    }

    private func waitForWatching(_ step: String = "") {
        XCTAssertTrue(until(10) { watching }, "Not watching \(step): \(probeText("mode") ?? "no probe")")
        pause(0.8)
    }

    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "none" }
        let f = element.frame
        return String(format: "%.1f,%.1f,%.1fx%.1f%@", f.minX, f.minY, f.width, f.height, element.isHittable ? "" : "(not hittable)")
    }

    private func report(_ step: String) {
        print("PROBE r22 \(step): mode=\(probeText("mode") ?? "?") pos=\(probeText("pos") ?? "?") latest=\(describe(latest)) keyboard=\(describe(keyboardButton)) hide=\(describe(hideKey)) actions=\(describe(app.buttons["terminalKey-actions"]))")
    }

    /// Scrolls back by dragging the text down (into the scrollback), short
    /// of the keyboard, which a longer drag pulls down (`.interactive`).
    private func scrollBack(_ distance: CGFloat = 220, from y: CGFloat = 0.15) {
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .default,
                    thenHoldForDuration: 0.1)
        pause(1)
    }

    /// Flings toward the newest output.
    private func flingForward() {
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)), withVelocity: .fast,
                    thenHoldForDuration: 0)
        pause(2)
    }

    private func tapText() {
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
    }

    // MARK: 1. One tap

    /// The owner's case: Terminal 1 is open on the Mac, whose window types
    /// there. The Mac lets a paired device type alongside its own window
    /// (protocol/local-agent-v1.md, Typing), but a tap counted the Mac as
    /// "someone else types" and only said "Typing wasn’t available".
    /// ("build" is where the fixture's Mac types.)
    func testOneTapShowsTheKeyboardWhileOnlyTheMacTypes() {
        launch(extra: ["-witerm.debug.fixtureLatency", "0.6"])
        open("fixture-s2")
        let opened = until(10) { typing }
        XCTAssertTrue(opened, "Opening where only the Mac types should type alongside it: \(probeText("mode") ?? "?")")
        if opened {
            hideKey.tap()
            waitForWatching()
        } else if notice.exists {
            shot("r22-1a-build-opened-watching")
            notice.buttons["Dismiss"].tap()
            pause(0.5)
        }
        let links = probe("links") ?? -1
        let start = Date()
        tapText()
        var pendingAfter: Double?
        let typed = until(10, poll: 0.03) {
            if pendingAfter == nil, keyboardButton.exists, (keyboardButton.value as? String) == "Showing Keyboard…" {
                pendingAfter = Date().timeIntervalSince(start)
            }
            return typing
        }
        let typedAfter = Date().timeIntervalSince(start)
        print(String(format: "PROBE r22 tap build: typing=%d after %.2f s, spinner after %@ s, notice=%d, links %d -> %d",
                     typed ? 1 : 0, typedAfter, pendingAfter.map { String(format: "%.2f", $0) } ?? "never",
                     notice.exists ? 1 : 0, Int(links), Int(probe("links") ?? -1)))
        shot("r22-1b-build-after-one-tap")
        XCTAssertTrue(typed, "One tap didn't bring up the keyboard where only the Mac types")
        XCTAssertFalse(notice.exists, "The tap said typing wasn't available")
    }

    /// A watched terminal nobody else types in: one tap asks the Mac, and
    /// the keyboard button turns into a spinner at once, until the keyboard
    /// rises (the Mac's answer takes a round trip, longer here: 0.6 s a step).
    func testOneTapShowsASpinnerAtOnceThenTheKeyboard() {
        launch(extra: ["-witerm.debug.fixtureLatency", "0.6"])
        open("fixture-s1")
        waitForTyping()
        hideKey.tap()
        waitForWatching()
        let start = Date()
        tapText()
        let tapped = Date().timeIntervalSince(start)
        var pendingAfter: Double?
        let typed = until(10, poll: 0.03) {
            if pendingAfter == nil, keyboardButton.exists, (keyboardButton.value as? String) == "Showing Keyboard…" {
                pendingAfter = Date().timeIntervalSince(start)
                shot("r22-1c-spinner")
            }
            return typing
        }
        print(String(format: "PROBE r22 tap s1: tap returned %.2f s, spinner after %@ s, typing after %.2f s",
                     tapped, pendingAfter.map { String(format: "%.2f", $0) } ?? "never", Date().timeIntervalSince(start)))
        XCTAssertTrue(typed, "One tap didn't bring up the keyboard")
        XCTAssertNotNil(pendingAfter, "Nothing showed that the tap was heard while the Mac was asked")
        if let pendingAfter { XCTAssertLessThan(pendingAfter, 1.0, "The spinner came late") }
        // A double tap still selects, and doesn't start typing.
        hideKey.tap()
        waitForWatching()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).doubleTap()
        pause(2)
        XCTAssertGreaterThan(probe("sel") ?? 0, 0, "A double tap didn't select")
        XCTAssertEqual(probeText("mode"), "view", "A double tap started typing")
    }

    /// The owner's case: the keyboard was just hidden, and one tap on the
    /// text comes before the watching link is ready (the switch waits 0.4 s
    /// for focus to come back, then lets go of typing and opens a new link,
    /// a round trip each, under Round 19's still picture). Before, the tap
    /// was dropped while the switch ran. Now it types: at once in the first
    /// 0.4 s (the typing link is still there), or once the switch is done.
    func testOneTapRightAfterHidingTheKeyboardTypes() {
        launch(extra: ["-witerm.debug.fixtureLatency", "0.6"])
        open("fixture-s1")
        // XCTest's tap returns once the keyboard has gone, so the first tap
        // lands while the switch runs (the probe's mode says which).
        for (step, delay) in [("right after", 0.0), ("a moment later", 0.5), ("once watching", 2.5)] {
            waitForTyping(step)
            let links = probe("links") ?? -1
            hideKey.tap()
            pause(delay)
            let mode = probeText("mode") ?? "?"
            let start = Date()
            tapText()
            let typed = until(10) { typing }
            print(String(format: "PROBE r22 tap %@: mode at tap=%@ typing=%d after %.2f s links %d -> %d", step, mode, typed ? 1 : 0,
                         Date().timeIntervalSince(start), Int(links), Int(probe("links") ?? -1)))
            XCTAssertTrue(typed, "A tap \(step) after hiding the keyboard didn't bring it back")
            XCTAssertFalse(notice.exists, "\(step): the tap said typing wasn't available")
            pause(0.8)
        }
    }

    // MARK: 2. The right buttons at the bottom

    /// Keyboard down, the keyboard button shows at once and stays, also
    /// while the switch to watching that hiding the keyboard starts is
    /// under way (before, neither button showed for that time); a tap on it
    /// then types once the switch is done. Leaving the bottom and coming
    /// back (a fling, Jump to Latest, new output) shows and hides Jump to
    /// Latest, above the key row.
    func testTheRightButtonsShowAtTheBottom() {
        launch(extra: ["-witerm.debug.fixtureLatency", "0.6"])
        open("fixture-s1")
        waitForTyping()
        hideKey.tap()
        // Sample until the switch to watching is done.
        var samples = 0, missing = 0, firstMissing: Double?
        let start = Date()
        until(6, poll: 0.03) {
            if !hideKey.exists {
                samples += 1
                if !keyboardButton.exists { missing += 1; if firstMissing == nil { firstMissing = Date().timeIntervalSince(start) } }
            }
            return probeText("mode") == "view" && Date().timeIntervalSince(start) > 1.5
        }
        print("PROBE r22 buttons after hide: samples=\(samples) withoutKeyboardButton=\(missing) first=\(firstMissing.map { String(format: "%.2f", $0) } ?? "-")")
        XCTAssertEqual(missing, 0, "\(missing) of \(samples) samples with the keyboard down showed no keyboard button")
        waitForWatching()
        // During the switch, the button types once it's done.
        keyboardButton.tap()
        waitForTyping("after the keyboard button")
        hideKey.tap()
        pause(0.2)
        if keyboardButton.exists { keyboardButton.tap() }
        XCTAssertTrue(until(10) { typing }, "A keyboard button tap during the switch to watching was lost")
        pause(0.8)
        // Keyboard up: leave the bottom and come back three ways.
        scrollBack()
        report("typing scrolled")
        XCTAssertTrue(latest.exists && latest.isHittable, "No Jump to Latest scrolled back")
        if latest.exists { XCTAssertLessThanOrEqual(latest.frame.maxY, hideKey.frame.minY, "Jump to Latest under the key row") }
        flingForward()
        XCTAssertTrue(until(3) { !latest.exists }, "Jump to Latest stayed after a fling back")
        scrollBack()
        if latest.exists { latest.tap() }
        XCTAssertTrue(until(3) { !latest.exists }, "Jump to Latest stayed after Jump to Latest")
        scrollBack()
        app.keys["a"].firstMatch.tap()
        XCTAssertTrue(until(3) { !latest.exists }, "Jump to Latest stayed after typing")
        XCTAssertTrue(hideKey.isHittable)
        // Keyboard down.
        hideKey.tap()
        waitForWatching()
        scrollBack()
        XCTAssertTrue(latest.exists && keyboardButton.exists, "Scrolled back: \(describe(latest)) \(describe(keyboardButton))")
        flingForward()
        XCTAssertTrue(until(3) { !latest.exists && keyboardButton.isHittable }, "Back at the bottom: \(describe(latest)) \(describe(keyboardButton))")
        shot("r22-2-watching-bottom")
    }

    // MARK: 3. One column

    /// Jump to Latest, the keyboard button and Hide Keyboard share one
    /// column (the same center and size), keyboard up and down, in portrait
    /// and landscape; in landscape the key row's actions key comes before
    /// Hide Keyboard, which ends the row.
    func testFloatingButtonsAndHideKeyboardShareOneColumn() {
        launch()
        open("fixture-s1")
        func check(_ step: String, landscape: Bool) {
            waitForTyping(step)
            let hide = hideKey.frame
            scrollBack(landscape ? 60 : 220, from: landscape ? 0.1 : 0.15)
            report("\(step) typing")
            shot("r22-3-\(step)-typing")
            XCTAssertTrue(latest.exists, "\(step): no Jump to Latest")
            if latest.exists {
                XCTAssertEqual(latest.frame.midX, hide.midX, accuracy: 0.5, "\(step): Jump to Latest and Hide Keyboard")
                XCTAssertEqual(latest.frame.width, hide.width, accuracy: 0.5, "\(step): sizes")
            }
            if landscape, app.buttons["terminalKey-actions"].exists {
                XCTAssertLessThanOrEqual(app.buttons["terminalKey-actions"].frame.maxX, hide.minX, "\(step): Hide Keyboard ends the row")
            }
            flingForward()
            hideKey.tap()
            waitForWatching(step)
            let keyboard = keyboardButton.frame
            XCTAssertEqual(keyboard.midX, hide.midX, accuracy: 0.5, "\(step): the keyboard button and Hide Keyboard")
            XCTAssertEqual(keyboard.width, hide.width, accuracy: 0.5, "\(step): sizes")
            scrollBack(landscape ? 60 : 220, from: landscape ? 0.1 : 0.15)
            report("\(step) watching")
            shot("r22-3-\(step)-watching")
            if latest.exists { XCTAssertEqual(latest.frame.midX, keyboard.midX, accuracy: 0.5, "\(step): Jump to Latest and the keyboard button") }
            flingForward()
        }
        check("portrait", landscape: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2)
        keyboardButton.tap()
        check("landscape", landscape: true)
        XCUIDevice.shared.orientation = .portrait
        pause(2)
    }

    // MARK: 4. Hiding the keyboard

    /// Hiding the keyboard is one transition: the grid takes the whole
    /// height when the keyboard starts to leave, not after it has gone (a
    /// black band grew under the text meanwhile), and the watching renderer
    /// that follows puts the last row where the typing one had it (both on
    /// the bottom edge; the typing grid left its part row at the bottom, so
    /// the cross-fade showed every row twice, half a row apart).
    func testHidingTheKeyboardIsOneTransition() {
        launch(extra: ["-witerm.debug.fixtureLatency", "0.6"])
        open("fixture-s1")
        waitForTyping()
        let screen = Double(app.windows.firstMatch.frame.height)
        hideKey.tap()
        let label = surface.label
        let mode = TerminalProbeLabel.text(label, "mode") ?? "?"
        let order = TerminalProbeLabel.keyboardLeaving(label, screenHeight: screen)
        let typingCursor = TerminalProbeLabel.numbers(label, "cursorCell")
        let typingBottom = (TerminalProbeLabel.numbers(label, "textBottom").first ?? 0) - (TerminalProbeLabel.numbers(label, "gridBottom").first ?? 0)
        print("PROBE r22 hide order: mode=\(mode) gridMs=\(order.grid.map(String.init) ?? "-") goneMs=\(order.gone.map(String.init) ?? "-") cursor=\(typingCursor) bottomGap=\(typingBottom) events=\(order.events)")
        XCTAssertNotNil(order.grid, "The grid didn't change after the keyboard left: \(order.events)")
        if let grid = order.grid, let gone = order.gone {
            XCTAssertLessThan(grid, gone, "The grid waited for the keyboard to be gone (\(grid) ms, gone at \(gone) ms)")
        }
        XCTAssertLessThan(typingBottom, 1, "Typing, \(typingBottom) pt between the last row and the bottom edge")
        waitForWatching()
        let watchingCursor = TerminalProbeLabel.numbers(surface.label, "cursorCell")
        print("PROBE r22 hide rows: typing cursor=\(typingCursor) (mode \(mode)) watching cursor=\(watchingCursor)")
        if mode == "control", typingCursor.count == 4, watchingCursor.count == 4 {
            XCTAssertEqual(watchingCursor[1], typingCursor[1], accuracy: 0.5, "The watching renderer moved the rows")
        }
    }

    /// For a screen recording made around it (`simctl io recordVideo`):
    /// typing, then Hide Keyboard, with time to see each step.
    func testRecordHidingTheKeyboard() {
        launch()
        open("fixture-s1")
        waitForTyping()
        pause(2)
        print("PROBE r22 record hide at \(Date().timeIntervalSince1970)")
        hideKey.tap()
        waitForWatching()
        pause(2)
        print("PROBE r22 record show at \(Date().timeIntervalSince1970)")
        keyboardButton.tap()
        waitForTyping()
        pause(2)
        print("PROBE r22 record hide again at \(Date().timeIntervalSince1970)")
        hideKey.tap()
        waitForWatching()
        pause(2)
    }
}
