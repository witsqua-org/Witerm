import XCTest

/// Round 16's structure (docs/design/ia-ios-round16.md): Terminals is one
/// list with a section per paired device, Shared with You, and SSH Hosts;
/// Devices holds only devices and relay servers; Settings puts frequent
/// preferences first and the rest under Advanced. Uses the DEBUG remote
/// fixture, so no relay server or Mac is involved and nothing is revoked:
/// the fixture lives in memory and comes back on the next launch.
///
/// With WITERM_AUDIT_DIR set, screenshots also go to `<dir>/round16`.
@MainActor final class InformationArchitectureTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(largestText: Bool = false, language: String = "en", locale: String = "en_US") {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1",
                               "-witerm.serverAddresses", "(\"https://relay.fixture.invalid\")",
                               "-witerm.debug.remoteFixture", "1",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
    }

    private func tab(_ index: Int) {
        let button = app.tabBars.buttons.element(boundBy: index)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func any(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func shot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["WITERM_AUDIT_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("round16")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func reveal(_ element: XCUIElement) {
        // Lists create rows lazily: scroll until it exists and can be tapped.
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<12 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists, "Missing \(element)")
        XCTAssertTrue(element.isHittable, "Not reachable: \(element)")
    }

    // MARK: Terminals

    func testTerminalsListsEveryDevicesTerminalsWithoutDrillingIn() {
        launch()
        let studio = any("deviceSection-fixture-studio")
        XCTAssertTrue(studio.waitForExistence(timeout: 15))
        XCTAssertTrue(studio.label.contains("Studio") && studio.label.contains("Online"), studio.label)
        // Its terminals are rows in its section, with no tap into the device.
        let terminal = app.buttons["remoteSession-fixture-s1"]
        XCTAssertTrue(terminal.exists)
        XCTAssertEqual(terminal.label, "Terminal 1")
        XCTAssertTrue((app.buttons["remoteSession-fixture-s2"].value as? String ?? "").contains("Typing on Studio"))
        XCTAssertTrue((app.buttons["remoteSession-fixture-m1"].value as? String ?? "").contains("Can only watch"))
        // An offline device says so in one line instead of an empty list.
        let laptop = any("deviceSection-fixture-laptop")
        XCTAssertTrue(laptop.label.contains("Offline"), laptop.label)
        XCTAssertTrue(any("deviceOffline-fixture-laptop").exists)
        shot("01-terminals-devices")

        // Shared with You, after the paired devices: whose it is, and that
        // access ends with the invitation.
        let shared = app.buttons["remoteSession-fixture-a1"]
        reveal(shared)
        XCTAssertTrue((shared.value as? String ?? "").contains("Until the invitation ends"))
        XCTAssertTrue(app.staticTexts["Shared with You"].exists)
        // SSH Hosts last, with Add SSH Host… as its own row, once.
        let add = app.buttons["newSSHProfile"]
        reveal(add)
        XCTAssertEqual(app.buttons.matching(identifier: "newSSHProfile").count, 1)
        XCTAssertGreaterThan(add.frame.minY, shared.frame.minY, "SSH Hosts comes after Shared with You")
        XCTAssertFalse(app.buttons["continueFromDevice"].exists, "Add Device belongs to Devices")
        XCTAssertFalse(any("terminalsDevicesPointer").exists, "The pointer is only for when nothing is paired")
        shot("02-terminals-shared-ssh")
    }

    /// A terminal row has no swipe: no watching mode to pick (the keyboard
    /// decides) and no delete (ending it is the Mac's decision).
    func testTerminalRowsHaveNoSwipeActions() {
        launch()
        let terminal = app.buttons["remoteSession-fixture-s1"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        terminal.swipeLeft()
        XCTAssertFalse(app.buttons["Watch"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Delete"].exists, "Ending a terminal is the other device's decision")
        shot("03-terminal-no-swipe")
    }

    // MARK: Devices

    func testDevicesHoldsOnlyDevicesAndRelayServers() {
        launch()
        tab(1)
        XCTAssertTrue(app.buttons["continueFromDevice"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["deviceDetails-fixture-studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["deviceDetails-fixture-mini"].exists)
        XCTAssertTrue(app.buttons["deviceDetails-fixture-laptop"].exists)
        XCTAssertFalse(app.buttons["deviceDetails-fixture-alex"].exists, "A shared terminal's Mac isn't a paired device")
        XCTAssertFalse(app.buttons["newSSHProfile"].exists)
        XCTAssertFalse(app.buttons["sshImportHosts"].exists)
        reveal(app.buttons["settingsServerRow-0"])
        XCTAssertTrue(app.buttons["settingsAddServer"].exists)
        shot("04-devices")
        // The device's page no longer has Show Terminals.
        app.swipeDown()
        app.buttons["deviceDetails-fixture-studio"].tap()
        XCTAssertTrue(app.buttons["unpairDevice"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["deviceShowTerminals"].exists)
        shot("05-device-page")
    }

    /// Unpairing by swipe always asks first; Cancel keeps the device. The
    /// fixture's unpair stays in memory: nothing reaches a relay server.
    func testUnpairSwipeAsksFirst() {
        launch()
        tab(1)
        let mini = app.buttons["deviceDetails-fixture-mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 15))
        let alert = app.alerts.firstMatch

        // Long press offers Unpair…, which asks.
        mini.press(forDuration: 1.0)
        let item = app.buttons["Unpair…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        shot("06a-unpair-context-menu")
        item.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Unpair must be confirmed")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "Cancel unpaired anyway")

        // A full swipe only reveals the action.
        mini.swipeLeft(velocity: .fast)
        XCTAssertFalse(alert.waitForExistence(timeout: 2), "A full swipe started unpairing")
        XCTAssertTrue(mini.exists)

        // The swipe's Unpair… asks too, and confirming unpairs.
        let action = app.buttons["Unpair…"]
        if !action.waitForExistence(timeout: 2) { mini.swipeLeft() }
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        shot("06-unpair-swipe")
        action.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Unpair must be confirmed")
        XCTAssertTrue(alert.label.contains("Mini"), alert.label)
        shot("07-unpair-confirm")
        app.alerts.buttons["Unpair"].tap()
        XCTAssertTrue(any("unpairedNote").waitForExistence(timeout: 10))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: mini)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
        tab(0)
        XCTAssertTrue(any("deviceSection-fixture-studio").waitForExistence(timeout: 5))
        XCTAssertFalse(any("deviceSection-fixture-mini").exists, "Terminals still lists the unpaired device")
    }

    // MARK: Settings

    func testSettingsPutsFrequentFirstAndTheRestInAdvanced() {
        launch()
        tab(2)
        let display = any("settingsDisplay")
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["snippetSettings"].exists)
        XCTAssertTrue(app.buttons["settingsWelcomeTour"].exists)
        XCTAssertFalse(app.buttons["settingsServers"].exists, "Relay servers moved to Devices")
        XCTAssertFalse(any("terminalFontSize").exists, "Text and Colors starts collapsed")
        shot("08-settings")
        display.tap()
        XCTAssertTrue(any("terminalFontSize").waitForExistence(timeout: 5))
        XCTAssertTrue(any("terminalColorScheme").exists)
        XCTAssertFalse(any("terminalHighContrast").exists, "Contrast is Advanced")
        shot("09-settings-text-colors")
        reveal(app.buttons["settingsAdvanced"])
        app.buttons["settingsAdvanced"].tap()
        XCTAssertTrue(any("terminalHighContrast").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mobileKeyRowSettings"].exists)
        XCTAssertTrue(any("terminalBell").exists)
        reveal(any("terminalAnnounceOutput"))
        shot("10-settings-advanced")
    }

    // MARK: Largest text

    func testLargestTextKeepsSectionsAndActionsReachable() {
        launch(largestText: true)
        XCTAssertTrue(any("deviceSection-fixture-studio").waitForExistence(timeout: 15))
        reveal(app.buttons["remoteSession-fixture-s1"])
        XCTAssertGreaterThanOrEqual(app.buttons["remoteSession-fixture-s1"].frame.height, 44)
        shot("11-terminals-ax5")
        reveal(app.buttons["newSSHProfile"])
        shot("12-terminals-ax5-ssh")
        tab(1)
        reveal(app.buttons["deviceDetails-fixture-studio"])
        reveal(app.buttons["settingsAddServer"])
        shot("13-devices-ax5")
        tab(2)
        reveal(app.buttons["settingsAdvanced"])
        shot("14-settings-ax5")
    }

    /// Runs last (tests run in name order): gives the fixture machines'
    /// colors back, so real hosts keep the least-used hues.
    func testZCleanUpFixtureColors() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-witerm.serverAddresses", "()",
                               "-witerm.debug.remoteFixtureCleanup", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testSimplifiedChineseSections() {
        launch(language: "zh-Hans", locale: "zh_CN")
        let studio = any("deviceSection-fixture-studio")
        XCTAssertTrue(studio.waitForExistence(timeout: 15))
        XCTAssertTrue(studio.label.contains("在线"), studio.label)
        reveal(app.buttons["remoteSession-fixture-a1"])
        shot("15-terminals-zh")
        tab(1)
        XCTAssertTrue(app.buttons["deviceDetails-fixture-studio"].waitForExistence(timeout: 10))
        shot("16-devices-zh")
        tab(2)
        XCTAssertTrue(any("settingsDisplay").waitForExistence(timeout: 10))
        shot("17-settings-zh")
    }
}
