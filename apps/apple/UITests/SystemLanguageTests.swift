import XCTest

@MainActor final class SystemLanguageTests: XCTestCase {
    func testEnglishInterface() {
        verify(language: "en", locale: "en_US", action: "Continue from Another Device", title: "New SSH Connection", cancel: "Cancel")
    }

    func testSimplifiedChineseInterface() {
        verify(language: "zh-Hans", locale: "zh_CN", action: "从其他设备继续", title: "新建 SSH 连接", cancel: "取消")
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        verify(language: "fr", locale: "fr_FR", action: "Continue from Another Device", title: "New SSH Connection", cancel: "Cancel")
    }

    private func verify(language: String, locale: String, action: String, title: String, cancel: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-witerm.serverAddresses", "()"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        let continuing = app.buttons["firstUseContinue"]
        XCTAssertTrue(continuing.waitForExistence(timeout: 10))
        XCTAssertTrue(continuing.label.hasPrefix(action), continuing.label)
        app.buttons["newSSHProfile"].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[cancel].exists)
        app.buttons[cancel].tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
    }
}
