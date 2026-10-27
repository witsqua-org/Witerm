import XCTest

@MainActor final class TaskChoiceTests: XCTestCase {
    private func launchTaskChoice(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.serverAddresses", "()", "-witerm.startTask", "",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        return app
    }

    func testSSHChoiceDoesNotRequireServerSetup() {
        let app = launchTaskChoice()
        XCTAssertTrue(app.buttons["chooseSSH"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chooseMac"].exists)
        capture("task-choice", app: app)
        app.buttons["chooseSSH"].tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["primaryAction"].exists)
        app.buttons["newSSHProfile"].tap()
        XCTAssertTrue(app.textFields["sshHostAddress"].waitForExistence(timeout: 5))
    }

    func testMacChoiceShowsServerSetup() {
        let app = launchTaskChoice()
        XCTAssertTrue(app.buttons["chooseMac"].waitForExistence(timeout: 10))
        app.buttons["chooseMac"].tap()
        XCTAssertTrue(app.buttons["primaryAction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["primaryAction"].label.contains("添加服务器"))
    }

    func testLargeTextKeepsBothChoicesReachable() {
        let app = launchTaskChoice(largeText: true)
        XCTAssertTrue(app.buttons["chooseSSH"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chooseSSH"].isHittable)
        let mac = app.buttons["chooseMac"]
        for _ in 0..<4 where !mac.isHittable { app.swipeUp() }
        XCTAssertTrue(mac.isHittable)
        XCTAssertGreaterThanOrEqual(mac.frame.height, 44)
        capture("task-choice-large-type", app: app)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
