import XCTest

/// Round 19, through the DEBUG remote fixture's Mac (`FixtureMac`, in memory;
/// nothing leaves the app): a new link that waits for the Mac's redraw for
/// longer than a moment says Catching up… over the old screen, and never on
/// a fast resume; watching a grid another device that types set, only
/// Connected Devices says whose size it is (Round 20). Prints `PROBE`
/// lines. Screenshots go to `WITERM_SHOTS_DIR` when it's set.
@MainActor final class PairedCatchUpTests: XCTestCase {
    private var app: XCUIApplication!
    private var launchedAt = Date()

    private func launch(extra: [String] = []) {
        // Captures of the code before a change run every step anyway.
        continueAfterFailure = ProcessInfo.processInfo.environment["WITERM_CONTINUE"] == "1"
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1",
                               "-witerm.serverAddresses", "(\"https://relay.fixture.invalid\")",
                               "-witerm.debug.remoteFixture", "1",
                               "--witerm-ui-test-layout-probe", "--witerm-ui-test-steady-terminal-cursor",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        if ProcessInfo.processInfo.environment["WITERM_SOFT_KEYBOARD"] == "1" {
            app.launchArguments += ["-witerm.debug.softwareKeyboard", "YES"]
        }
        launchedAt = Date()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
    }

    private var surface: XCUIElement { app.descendants(matching: .any)["remoteTerminalSurface"].firstMatch }
    private var hideKey: XCUIElement { app.buttons["terminalKey-hideKeyboard"] }
    private var keyboardButton: XCUIElement { app.buttons["remoteKeyboard"] }
    private var note: XCUIElement { app.descendants(matching: .any)["remoteCatchingUp"].firstMatch }
    private var status: XCUIElement { app.descendants(matching: .any)["terminalInputStatus"].firstMatch }

    private func probeText(_ key: String) -> String? {
        guard surface.exists else { return nil }
        let label = surface.label
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return String(label[range.upperBound...].prefix { !$0.isWhitespace })
    }
    private func probe(_ key: String) -> Double? { probeText(key).flatMap { Double($0.prefix { $0.isNumber || $0 == "." || $0 == "-" }) } }

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
        let row = app.buttons["remoteSession-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "No fixture terminal \(id)")
        row.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "The terminal didn't open")
    }

    private var screenText: String { surface.value as? String ?? "" }

    /// Watches the note from `start` for `seconds`: when it first showed and
    /// when it went, in seconds since `start`.
    private func watchNote(from start: Date, for seconds: TimeInterval, shotName: String? = nil,
                           shotAt: (TimeInterval, String)? = nil) -> (shown: Double?, gone: Double?) {
        var shown: Double?, gone: Double?, shotTaken = false, timedShot = shotAt == nil
        let end = start.addingTimeInterval(seconds)
        while Date() < end {
            let visible = note.exists
            let now = Date().timeIntervalSince(start)
            // The same moment before and after a change, for comparing captures.
            if !timedShot, let shotAt, now >= shotAt.0 { shot(shotAt.1); timedShot = true }
            if gone != nil, timedShot { break }
            if visible, shown == nil { shown = now }
            if visible, !shotTaken, let shotName { shot(shotName); shotTaken = true }
            if !visible, shown != nil, gone == nil { gone = now; if timedShot { break } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return (shown, gone)
    }

    // MARK: Catching up

    /// A slow redraw (the fixture sends the Mac's earlier output at once and
    /// tmux's redraw 1.5 s later, as over a slow relay): after hiding the
    /// keyboard and after typing again, the terminal says Catching up… over
    /// the old screen, and the note goes once the redraw is there.
    func testASlowRedrawSaysCatchingUpOverTheOldScreen() {
        launch(extra: ["-witerm.debug.fixtureRedrawDelay", "1.5"])
        open("fixture-s1")
        // A first open has no old screen to keep: no note.
        let first = watchNote(from: Date(), for: 2.5)
        XCTAssertNil(first.shown, "Catching up… on a first open")
        XCTAssertTrue(until(10) { probeText("mode") == "control" && screenText.contains("fixture$") }, "Not typing: \(probeText("mode") ?? "no probe")")
        XCTAssertTrue(until(5) { hideKey.exists && hideKey.isHittable }, "No Hide Keyboard")
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        // Stop typing: the watching link waits for the redraw.
        hideKey.tap()
        let watchStart = Date()
        let watching = watchNote(from: watchStart, for: 6, shotName: "r19-catch-1-watching",
                                 shotAt: (0.9, "r19-catch-1b-watching-0.9s"))
        print("PROBE r19 catch watching shown=\(watching.shown.map { String(format: "%.2f", $0) } ?? "never") gone=\(watching.gone.map { String(format: "%.2f", $0) } ?? "never") catchUpMs=\(probeText("catchUpMs") ?? "?") covers=\(probeText("covers") ?? "?")")
        XCTAssertNotNil(watching.shown, "No Catching up… while the watching link waited for the redraw")
        XCTAssertNotNil(watching.gone, "Catching up… stayed after the redraw")
        XCTAssertTrue(until(5) { probeText("mode") == "view" && keyboardButton.exists }, "Not watching")
        XCTAssertTrue(until(3) { screenText.contains("fixture$") }, "No redraw")
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        // Type again: the owner's case.
        keyboardButton.tap()
        let typeStart = Date()
        var coveredWhileWaiting = false
        let typing = watchNote(from: typeStart, for: 6, shotName: "r19-catch-2-typing-again",
                               shotAt: (0.9, "r19-catch-2b-typing-again-0.9s"))
        if typing.shown != nil { coveredWhileWaiting = (probe("covers") ?? 0) >= 1 }
        print("PROBE r19 catch typing shown=\(typing.shown.map { String(format: "%.2f", $0) } ?? "never") gone=\(typing.gone.map { String(format: "%.2f", $0) } ?? "never") catchUpMs=\(probeText("catchUpMs") ?? "?") covers=\(probeText("covers") ?? "?") coverMs=\(probeText("coverMs") ?? "?") catchUps=\(probeText("catchUps") ?? "?")")
        XCTAssertNotNil(typing.shown, "No Catching up… after typing resumed with a slow redraw")
        XCTAssertNotNil(typing.gone, "Catching up… stayed after the redraw")
        XCTAssertTrue(coveredWhileWaiting, "The old screen wasn't kept under the note")
        XCTAssertTrue(until(5) { probeText("mode") == "control" && screenText.contains("fixture$") }, "Not typing again")
        XCTAssertGreaterThanOrEqual(probe("catchUpMs") ?? 0, 1000, "The renderer didn't wait for the redraw")
        shot("r19-catch-3-caught-up")
    }

    /// The fixture's redraw comes at once: typing or watching again never
    /// shows the note, not even for a moment.
    func testAFastResumeNeverSaysCatchingUp() {
        launch()
        open("fixture-s1")
        XCTAssertTrue(until(10) { probeText("mode") == "control" && hideKey.exists && hideKey.isHittable }, "Not typing")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        for step in ["watch", "type", "watch", "type"] {
            if step == "watch" { hideKey.tap() } else { keyboardButton.tap() }
            let seen = watchNote(from: Date(), for: 2.5)
            XCTAssertNil(seen.shown, "Catching up… showed on a fast \(step)")
            XCTAssertTrue(until(5) { probeText("mode") == (step == "watch" ? "view" : "control") }, "Didn't \(step)")
            XCTAssertTrue(until(5) { step == "watch" ? keyboardButton.exists : hideKey.exists && hideKey.isHittable })
            print("PROBE r19 fast \(step) catchUpMs=\(probeText("catchUpMs") ?? "?") catchUps=\(probeText("catchUps") ?? "?")")
            XCTAssertLessThan(probe("catchUpMs") ?? 0, 400, "A fast redraw took longer than the threshold")
            XCTAssertEqual(probe("catchUps"), 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
    }

    // MARK: Whose size (Round 19, reworded in Round 20)

    /// Another device ("Alex’s iPad", the fixture's) types in Terminal 1 at
    /// 80 × 24 for 8 s, so this phone opens watching its grid. Since Round
    /// 20 the title only counts who is connected (never "Typing on…" or
    /// "Sized for…"); Connected Devices says the iPad sets the size. After
    /// the iPad stops, this phone is alone: no count. Typing here sets this
    /// phone's size, and the sheet says so.
    func testWatchingAnotherDevicesGridNamesItOnlyInConnectedDevices() {
        launch(extra: ["-witerm.debug.fixtureOtherTyper", "8"])
        open("fixture-s1")
        XCTAssertTrue(until(10) { probeText("mode") == "view" }, "Didn't open watching")
        XCTAssertTrue(until(5) { status.exists && status.label.contains("2 devices connected") }, status.label)
        XCTAssertFalse(status.label.contains("Typing on") || status.label.contains("Sized for") || status.label.contains("its size"),
                       status.label)
        XCTAssertEqual(probeText("cols"), "80", "Not watching the iPad's grid")
        print("PROBE r20 sized status=\(status.label) grid=\(probeText("cols") ?? "?")x\(probeText("rows") ?? "?")")
        app.buttons["terminalActionsMenu"].tap()
        app.buttons["Connected Devices"].firstMatch.tap()
        let ipad = app.descendants(matching: .any)["connectedDevice-device-0"].firstMatch
        XCTAssertTrue(ipad.waitForExistence(timeout: 5))
        XCTAssertTrue(until(8) { (ipad.value as? String) == "Typing, Sets the terminal size" }, "\(ipad.value ?? "")")
        shot("r20-sized-1-sheet-ipad")
        app.buttons["connectedDevicesDone"].tap()
        // The iPad stops; the next list (every 10 s) no longer counts it.
        XCTAssertTrue(until(20) { status.exists && !status.label.contains("devices connected") }, "Still counts the iPad: \(status.label)")
        XCTAssertFalse(status.label.contains("Sized for"), status.label)
        shot("r20-sized-2-ipad-stopped")
        // Typing here sets this phone's size.
        while Date().timeIntervalSince(launchedAt) < 10 { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        keyboardButton.tap()
        XCTAssertTrue(until(10) { probeText("mode") == "control" && hideKey.exists }, "Didn't type")
        app.buttons["terminalActionsMenu"].tap()
        app.buttons["Connected Devices"].firstMatch.tap()
        let this = app.descendants(matching: .any)["connectedDevice-this"].firstMatch
        XCTAssertTrue(this.waitForExistence(timeout: 5))
        XCTAssertTrue(until(8) { (this.value as? String) == "Typing, Sets the terminal size" }, "\(this.value ?? "")")
        shot("r20-sized-3-typing-sheet")
        app.buttons["connectedDevicesDone"].tap()
    }
}
