import XCTest

/// The first-use screen: SSH needs no server, Add SSH Host… and Import SSH
/// Hosts… are the SSH Hosts section's own rows, and Add Device lives only in
/// Devices, where it goes straight to scanning or pasting an invitation.
@MainActor final class FirstUseTests: XCTestCase {
    private func launchFirstUse(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-witerm.serverAddresses", "()",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        return app
    }

    private func showDevices(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    func testSSHChoiceDoesNotRequireServerSetup() {
        let app = launchFirstUse()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sshImportHosts"].exists)
        // One place for each: no Add Device row and no + button here, only
        // words saying where devices are added.
        XCTAssertFalse(app.buttons["continueFromDevice"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "newSSHProfile").count, 1, "Add SSH Host… appears once")
        XCTAssertTrue(app.staticTexts["terminalsDevicesPointer"].exists)
        capture("first-use", app: app)
        app.buttons["newSSHProfile"].tap()
        XCTAssertTrue(app.textFields["sshHostAddress"].waitForExistence(timeout: 5))
    }

    func testContinueOpensScanOrPasteWithoutServerSetup() {
        let app = launchFirstUse()
        showDevices(app)
        XCTAssertTrue(app.buttons["continueFromDevice"].waitForExistence(timeout: 10))
        // Devices holds devices and relay servers only.
        XCTAssertFalse(app.buttons["newSSHProfile"].exists)
        XCTAssertFalse(app.buttons["sshImportHosts"].exists)
        app.buttons["continueFromDevice"].tap()
        XCTAssertTrue(app.buttons["pasteInvitation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["typeInvitation"].exists)
        XCTAssertFalse(app.textFields["serverAddressField"].exists, "Continuing asked for a server first")
        app.buttons["typeInvitation"].tap()
        let field = app.textViews["sessionInvitationField"].exists ? app.textViews["sessionInvitationField"] : app.textFields["sessionInvitationField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("https://example.com")
        app.buttons["preparePairing"].tap()
        XCTAssertTrue(app.staticTexts["invitationProblem"].waitForExistence(timeout: 5))
        capture("continue-scan", app: app)
    }

    func testLargeTextKeepsEveryChoiceReachable() {
        let app = launchFirstUse(largeText: true)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["newSSHProfile"].isHittable)
        let importing = app.buttons["sshImportHosts"]
        for _ in 0..<4 where !importing.isHittable { app.swipeUp() }
        XCTAssertTrue(importing.isHittable)
        XCTAssertGreaterThanOrEqual(importing.frame.height, 44)
        capture("first-use-large-type", app: app)
        showDevices(app)
        let continuing = app.buttons["continueFromDevice"]
        XCTAssertTrue(continuing.waitForExistence(timeout: 10))
        XCTAssertTrue(continuing.isHittable)
        XCTAssertGreaterThanOrEqual(continuing.frame.height, 44)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
