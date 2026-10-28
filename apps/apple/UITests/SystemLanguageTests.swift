import XCTest

@MainActor final class SystemLanguageTests: XCTestCase {
    func testEnglishInterface() {
        verify(language: "en", locale: "en_US", action: "Add Server", title: "New SSH Connection", cancel: "Cancel")
    }

    func testSimplifiedChineseInterface() {
        verify(language: "zh-Hans", locale: "zh_CN", action: "添加服务器", title: "新建 SSH 连接", cancel: "取消")
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        verify(language: "fr", locale: "fr_FR", action: "Add Server", title: "New SSH Connection", cancel: "Cancel")
    }

    private func verify(language: String, locale: String, action: String, title: String, cancel: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-witerm.startTask", "mac",
                               "-witerm.serverAddresses", "()"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        let primary = app.buttons["primaryAction"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(primary.label, action)
        app.tabBars.buttons.element(boundBy: 0).tap()
        app.buttons["newSSHProfile"].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[cancel].exists)
        app.buttons[cancel].tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
    }
}
