import XCTest

/// Round 20, through the DEBUG remote fixture's Mac (`FixtureMac`, in memory;
/// nothing leaves the app): a paired terminal's title counts the devices
/// connected to it, this iPhone included, and never says who types; the ⋯
/// menu's Connected Devices opens a sheet listing each of them, typing or
/// watching, and whose size the terminal uses, live while it's open. Prints
/// `PROBE` lines. Screenshots go to `WITERM_SHOTS_DIR` when it's set.
@MainActor final class PairedConnectedDevicesTests: XCTestCase {
    private var app: XCUIApplication!
    private var launchedAt = Date()

    private func launch(extra: [String] = []) {
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
    private var status: XCUIElement { app.descendants(matching: .any)["terminalInputStatus"].firstMatch }
    private var hideKey: XCUIElement { app.buttons["terminalKey-hideKeyboard"] }
    private var keyboardButton: XCUIElement { app.buttons["remoteKeyboard"] }
    private var notice: XCUIElement { app.descendants(matching: .any)["remoteTerminalNotice"].firstMatch }
    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["connectedDevice-\(id)"].firstMatch }

    private func probeText(_ key: String) -> String? {
        guard surface.exists else { return nil }
        let label = surface.label
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return String(label[range.upperBound...].prefix { !$0.isWhitespace })
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

    private func open(_ id: String) {
        let row = app.buttons["remoteSession-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "No fixture terminal \(id)")
        row.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "The terminal didn't open")
    }

    /// The ⋯ menu's Connected Devices: a sheet, not another menu.
    private func openConnectedDevices() {
        app.buttons["terminalActionsMenu"].tap()
        let item = app.buttons["Connected Devices"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No Connected Devices in the ⋯ menu")
        shot("r20-0-menu")
        item.tap()
        // A sheet with its own navigation bar, not another menu.
        XCTAssertTrue(app.navigationBars["Connected Devices"].waitForExistence(timeout: 5), "The sheet didn't open")
    }

    private func closeConnectedDevices() {
        app.buttons["connectedDevicesDone"].tap()
        XCTAssertTrue(until(5) { !app.navigationBars["Connected Devices"].exists }, "The sheet didn't close")
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// The title says how many are connected and never who types or whose
    /// size it is; the sheet lists them all, and follows the iPad stopping.
    func testTitleCountsDevicesAndTheSheetListsThemLive() {
        // Alex's iPad types in Terminal 1 for 30 s; Studio's window and
        // Sam's iPhone watch it.
        launch(extra: ["-witerm.debug.fixtureOtherTyper", "30", "-witerm.debug.fixtureWatchers", "1"])
        open("fixture-s1")
        XCTAssertTrue(until(10) { probeText("mode") == "view" }, "Didn't open watching")
        XCTAssertTrue(until(5) { status.exists && status.label.contains("4 devices connected") }, "Title: \(status.label)")
        XCTAssertFalse(status.label.contains("Typing on") || status.label.contains("Sized for") || status.label.contains("its size"),
                       "The title names who types: \(status.label)")
        XCTAssertTrue(status.label.contains("Studio"), "The title lost the Mac's name: \(status.label)")
        print("PROBE r20 title=\(status.label)")
        shot("r20-1-title-four")

        openConnectedDevices()
        XCTAssertTrue(row("this").waitForExistence(timeout: 5))
        XCTAssertEqual(row("this").label, "This iPhone")
        XCTAssertEqual(value(row("this")), "Watching")
        XCTAssertEqual(row("mac").label, "Studio")
        XCTAssertEqual(value(row("mac")), "Watching")
        XCTAssertEqual(row("device-0").label, "Alex’s iPad")
        XCTAssertTrue(until(8) { value(row("device-0")) == "Typing, Sets the terminal size" }, "iPad: \(value(row("device-0")))")
        XCTAssertEqual(row("device-1").label, "Sam’s iPhone")
        XCTAssertEqual(value(row("device-1")), "Watching")
        // This iPhone first, then the Mac, then the others.
        XCTAssertLessThan(row("this").frame.minY, row("mac").frame.minY)
        XCTAssertLessThan(row("mac").frame.minY, row("device-0").frame.minY)
        // The sheet opens at half height; four rows push the footer below
        // it, so pull the sheet up to its full height.
        let footer = app.descendants(matching: .any)["connectedDevicesFooter"].firstMatch
        if !footer.exists { app.navigationBars["Connected Devices"].swipeUp() }
        XCTAssertTrue(footer.waitForExistence(timeout: 3) && footer.label.contains("80 columns, 24 rows"), "Footer: \(footer.label)")
        print("PROBE r20 sheet rows=this,mac,\(row("device-0").label),\(row("device-1").label) footer=\(footer.label)")
        shot("r20-2-sheet")

        // The iPad stops; the open sheet follows within a poll (5 s).
        let stops = launchedAt.addingTimeInterval(30)
        XCTAssertTrue(until(max(0, stops.timeIntervalSinceNow) + 8) { row("device-0").exists && row("device-0").label == "Sam’s iPhone" },
                      "The sheet still lists the iPad")
        let followed = Date().timeIntervalSince(stops)
        print("PROBE r20 sheet followed the iPad leaving after \(String(format: "%.1f", followed)) s")
        XCTAssertLessThan(followed, 8.5, "The sheet took longer than a poll (5 s) and the test's reads to follow")
        XCTAssertFalse(row("device-1").exists)
        shot("r20-3-sheet-ipad-gone")
        closeConnectedDevices()
        XCTAssertTrue(until(3) { status.label.contains("3 devices connected") }, "Title: \(status.label)")
        shot("r20-4-title-three")
    }

    /// Alone: no count (the title names the Mac), and the sheet says so.
    /// Typing here, this iPhone sets the size.
    func testAloneTheTitleNamesTheMacAndTheSheetSaysNobodyElse() {
        launch()
        open("fixture-s1")
        XCTAssertTrue(until(10) { probeText("mode") == "control" && hideKey.exists }, "Didn't open typing")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(status.label.contains("devices connected"), "A count of one: \(status.label)")
        XCTAssertTrue(status.label.contains("Studio"), status.label)
        shot("r20-5-alone-title")
        openConnectedDevices()
        XCTAssertTrue(row("this").waitForExistence(timeout: 5))
        XCTAssertTrue(until(8) { value(row("this")) == "Typing, Sets the terminal size" }, "This iPhone: \(value(row("this")))")
        XCTAssertFalse(row("mac").exists)
        let footer = app.descendants(matching: .any)["connectedDevicesFooter"].firstMatch
        XCTAssertTrue(footer.label.contains("No other devices are connected."), footer.label)
        shot("r20-6-alone-sheet")
        closeConnectedDevices()
        XCTAssertTrue(surface.exists)
    }

    /// The Mac types in "build": the title counts it; a tap keeps watching
    /// and says so without naming anyone, and offers the list.
    func testATapWhileTheMacTypesSaysWatchingWithoutNamingAnyone() {
        launch()
        open("fixture-s2")
        XCTAssertTrue(until(10) { probeText("mode") == "view" }, "Didn't open watching")
        XCTAssertTrue(until(5) { status.label.contains("2 devices connected") }, "Title: \(status.label)")
        XCTAssertFalse(status.label.contains("Typing on"), status.label)
        // Opening asked to type and the Mac refused, so it already says so.
        let words = app.staticTexts["Typing wasn’t available, so you’re watching."]
        XCTAssertTrue(notice.waitForExistence(timeout: 3) && words.exists, "Opening into watching said nothing")
        shot("r20-7a-opened-watching")
        notice.buttons["Dismiss"].tap()
        XCTAssertTrue(until(3) { !notice.exists })
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 3), "A refused tap said nothing")
        XCTAssertTrue(words.exists, "Notice: \(notice.debugDescription)")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Typing on")).firstMatch.exists,
                       "Something names who types")
        XCTAssertEqual(probeText("mode"), "view", "A tap took typing from the Mac")
        shot("r20-7-refused-tap")
        app.buttons["remoteNoticeConnectedDevices"].tap()
        XCTAssertTrue(app.navigationBars["Connected Devices"].waitForExistence(timeout: 5))
        XCTAssertEqual(row("mac").label, "Studio")
        XCTAssertTrue(until(8) { value(row("mac")) == "Typing, Sets the terminal size" }, "Mac: \(value(row("mac")))")
        XCTAssertEqual(value(row("this")), "Watching")
        shot("r20-8-refused-sheet")
        closeConnectedDevices()
    }

    /// A Mac from before Round 20 lists who types but not who is attached:
    /// no count and no Connected Devices; neither for an invitation's guest.
    func testOlderMacsAndInvitationsShowNoCountAndNoSheet() {
        launch(extra: ["-witerm.debug.fixtureOlderMac", "1"])
        open("fixture-s2")
        XCTAssertTrue(until(10) { probeText("mode") == "view" }, "Didn't open watching")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // The status reads with the terminal's name first ("build, Studio").
        XCTAssertTrue(status.label.hasSuffix("Studio") && !status.label.contains("devices connected")
                      && !status.label.contains("Typing on"), "An older Mac: the title names the Mac only: \(status.label)")
        app.buttons["terminalActionsMenu"].tap()
        XCTAssertTrue(app.buttons["Find in Terminal"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connected Devices"].exists, "Offered a list the Mac can't give")
        shot("r20-9-older-mac-menu")
        app.terminate()
        // Shared with You, from a current Mac: an invitation's guest learns
        // nobody else.
        launch()
        open("fixture-a1")
        XCTAssertTrue(until(10) { probeText("mode") != nil && status.exists })
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(status.label.contains("devices connected"), status.label)
        app.buttons["terminalActionsMenu"].tap()
        XCTAssertTrue(app.buttons["Find in Terminal"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connected Devices"].exists, "An invitation's guest got the list")
    }
}
