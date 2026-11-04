import XCTest

/// Round 18, item 5: screenshots of the iOS screens whose custom-drawn
/// boxes became native components (docs/design/native-ui-audit-ios.md),
/// through the DEBUG remote fixture (nothing real is touched). Also checks
/// the identifiers the other tests use are still there. Screenshots go to
/// `WITERM_SHOTS_DIR` when it's set.
@MainActor final class NativeUIScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ extra: [String] = []) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1",
                               "-witerm.serverAddresses", "(\"https://relay.fixture.invalid\")",
                               "-witerm.debug.remoteFixture", "1",
                               "--witerm-ui-test-steady-terminal-cursor",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
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

    private var any: XCUIElementQuery { app.descendants(matching: .any) }

    func testListsAndPages() {
        launch()
        let row = app.buttons["remoteSession-fixture-s1"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        shot("native-01-terminals")
        // A terminal kept connected after Back: its Connected status.
        row.tap()
        XCTAssertTrue(app.buttons["remoteSessionList"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.buttons["remoteSessionList"].tap()
        XCTAssertTrue(any["remoteSessionConnected-fixture-s1"].waitForExistence(timeout: 5))
        shot("native-02-terminals-connected")
        // The offline device and Shared with You, further down.
        app.swipeUp()
        XCTAssertTrue(any["deviceOffline-fixture-laptop"].waitForExistence(timeout: 5))
        shot("native-03-terminals-offline-shared")
        app.tabBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["deviceDetails-fixture-studio"].waitForExistence(timeout: 10))
        shot("native-04-devices")
        app.buttons["deviceDetails-fixture-studio"].tap()
        XCTAssertTrue(app.buttons["unpairDevice"].waitForExistence(timeout: 5))
        shot("native-05-device-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.buttons["settingsAdvanced"].waitForExistence(timeout: 5))
        shot("native-06-settings")
    }

    /// The terminal when its device drops off: the box the owner asked to be
    /// native ("Device Is Offline").
    func testTerminalWhenItsDeviceGoesOffline() {
        launch(["-witerm.debug.fixtureOfflineAfter", "10"])
        let row = app.buttons["remoteSession-fixture-s1"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let status = any["remoteDisconnectedStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 40), "No disconnected status")
        // Its automatic tries end on Device Is Offline.
        let end = Date().addingTimeInterval(30)
        while Date() < end, !(status.exists && status.label.contains("Offline")) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        shot("native-07-terminal-device-offline")
        XCTAssertTrue(status.label.contains("Offline"), status.label)
        XCTAssertTrue(app.buttons["reconnectRemoteTerminal"].exists || app.buttons["remoteDisconnectedSessionList"].exists)
        app.buttons["remoteSessionList"].tap()
        let section = any["deviceSection-fixture-studio"]
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        shot("native-08-terminals-studio-offline")
    }
}
