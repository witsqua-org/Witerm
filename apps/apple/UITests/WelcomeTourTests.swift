import XCTest

/// The Welcome Tour: shown on a fresh launch, skippable on every page, and
/// reopened from Settings → Help. A launch argument stands in for a fresh
/// install (`-witerm.onboarding.completedVersion 0`), so no app data is reset.
@MainActor final class WelcomeTourTests: XCTestCase {
    private func launch(language: String = "en", largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "0",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        return app
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    func testTourShowsOnFreshLaunchSkipsAndReopensFromHelp() {
        let app = launch()
        let skip = app.buttons["welcomeTourSkip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "A fresh launch must show the Welcome Tour")
        XCTAssertTrue(app.staticTexts["Connect over SSH"].exists)
        shot("tour-en-1", app)
        app.buttons["welcomeTourNext"].tap()
        XCTAssertTrue(app.staticTexts["Continue from Your Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(skip.exists, "Skip stays on every page")
        shot("tour-en-2", app)

        // Skip lands on Terminals, the first useful screen.
        skip.tap()
        XCTAssertFalse(skip.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))

        // Settings → Help reopens it; Get Started finishes on Terminals.
        app.tabBars.buttons.element(boundBy: 2).tap()
        let help = app.buttons["settingsWelcomeTour"]
        for _ in 0..<4 where !help.isHittable { app.swipeUp() }
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        shot("settings-help-en", app)
        help.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        app.buttons["welcomeTourNext"].tap()
        app.buttons["welcomeTourNext"].tap()
        XCTAssertTrue(app.staticTexts["Keys and Gestures"].waitForExistence(timeout: 5))
        shot("tour-en-3", app)
        app.buttons["welcomeTourStart"].tap()
        XCTAssertFalse(skip.waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).isSelected, "Get Started lands on Terminals")
    }

    /// In Chinese at the largest accessibility size, every page's title and
    /// line stay reachable and Skip and Next stay on screen.
    func testChineseAtLargestTextSize() {
        let app = launch(language: "zh-Hans", largeText: true)
        let skip = app.buttons["welcomeTourSkip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertEqual(skip.label, "跳过")
        for (index, title) in ["通过 SSH 连接", "从 Mac 继续", "按键与手势"].enumerated() {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
            XCTAssertTrue(skip.isHittable)
            shot("tour-zh-large-\(index + 1)", app)
            let next = index < 2 ? app.buttons["welcomeTourNext"] : app.buttons["welcomeTourStart"]
            XCTAssertTrue(next.isHittable)
            XCTAssertGreaterThanOrEqual(next.frame.height, 44)
            next.tap()
        }
        XCTAssertFalse(skip.waitForExistence(timeout: 2))
    }

    /// The tour in Chinese at the default size, for the record.
    func testChinesePages() {
        let app = launch(language: "zh-Hans")
        XCTAssertTrue(app.buttons["welcomeTourSkip"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["通过 SSH 连接"].exists)
        shot("tour-zh-1", app)
        app.buttons["welcomeTourNext"].tap()
        XCTAssertTrue(app.staticTexts["从 Mac 继续"].waitForExistence(timeout: 5))
        shot("tour-zh-2", app)
        app.buttons["welcomeTourNext"].tap()
        XCTAssertTrue(app.staticTexts["按键与手势"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["welcomeTourStart"].label, "开始使用")
        shot("tour-zh-3", app)
        app.buttons["welcomeTourSkip"].tap()
    }
}
