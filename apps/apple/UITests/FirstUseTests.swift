import XCTest

/// The one first-use screen: SSH needs no server, and continuing from
/// another device goes straight to scanning or pasting an invitation.
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

    func testSSHChoiceDoesNotRequireServerSetup() {
        let app = launchFirstUse()
        XCTAssertTrue(app.buttons["sshAddFirstHost"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["firstUseContinue"].exists)
        capture("first-use", app: app)
        app.buttons["sshAddFirstHost"].tap()
        XCTAssertTrue(app.textFields["sshHostAddress"].waitForExistence(timeout: 5))
    }

    func testContinueOpensScanOrPasteWithoutServerSetup() {
        let app = launchFirstUse()
        XCTAssertTrue(app.buttons["firstUseContinue"].waitForExistence(timeout: 10))
        app.buttons["firstUseContinue"].tap()
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
        XCTAssertTrue(app.buttons["sshAddFirstHost"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sshAddFirstHost"].isHittable)
        let continuing = app.buttons["firstUseContinue"]
        for _ in 0..<4 where !continuing.isHittable { app.swipeUp() }
        XCTAssertTrue(continuing.isHittable)
        XCTAssertGreaterThanOrEqual(continuing.frame.height, 44)
        capture("first-use-large-type", app: app)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
