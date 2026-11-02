import Foundation
import XCTest

/// Opt-in against the fixed, signed development app. A launch whose stored
/// tour version is below 1 shows the Welcome Tour; Esc and Skip close it,
/// Return and → move on, and Help → Welcome Tour opens it again. Nothing is
/// created: the tour is never finished with Get Started here.
@MainActor
final class WelcomeTourTests: XCTestCase {
    private func launch(_ language: String, locale: String) throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP to the signed development app")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        // A launch argument stands in for a first launch without touching the
        // stored value's other readers.
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-witerm.onboarding.completedVersion", "0"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        return app
    }

    private func waitForTitle(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts["welcomeTourTitle"]
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed, "Expected “\(title)”, saw “\(element.label)”",
                       file: file, line: line)
    }

    func testTourShowsOnFirstLaunchSkipsAndReopensFromHelp() throws {
        continueAfterFailure = false
        let app = try launch("en", locale: "en_US")
        let tour = app.descendants(matching: .any)["welcomeTour"].firstMatch
        XCTAssertTrue(tour.waitForExistence(timeout: 15), "The tour didn't open on a first launch")
        waitForTitle("Terminals keep running", in: app)

        // Return moves on; the service page offers its switch in place.
        app.typeKey(.return, modifierFlags: [])
        waitForTitle("Run in the background", in: app)
        let serviceOn = app.descendants(matching: .any)["welcomeTourServiceOn"].firstMatch
        let turnOn = app.buttons["welcomeTourService"]
        XCTAssertTrue(serviceOn.exists || turnOn.exists || app.buttons["Open Login Items Settings"].exists)
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForTitle("Terminals keep running", in: app)

        // Esc skips.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tour.waitForNonExistence(timeout: 5), "Esc didn't close the tour")

        // Help → Welcome Tour opens it again; the last page says Get Started.
        app.menuBars.menuBarItems["Help"].click()
        let item = app.menuItems["Welcome Tour"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        XCTAssertTrue(tour.waitForExistence(timeout: 5), "Help → Welcome Tour didn't open it")
        let primary = app.buttons["welcomeTourPrimary"]
        for title in ["Run in the background", "Open on another device", "Start from any folder"] {
            primary.click()
            waitForTitle(title, in: app)
        }
        XCTAssertEqual(primary.label, "Get Started")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "welcome-tour-last-page"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["welcomeTourSkip"].click()
        XCTAssertTrue(tour.waitForNonExistence(timeout: 5), "Skip didn't close the tour")
    }

    func testTourInChinese() throws {
        continueAfterFailure = false
        let app = try launch("zh-Hans", locale: "zh_CN")
        let tour = app.descendants(matching: .any)["welcomeTour"].firstMatch
        XCTAssertTrue(tour.waitForExistence(timeout: 15))
        waitForTitle("终端持续运行", in: app)
        XCTAssertEqual(app.buttons["welcomeTourSkip"].label, "跳过")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tour.waitForNonExistence(timeout: 5))
        app.menuBars.menuBarItems.element(boundBy: app.menuBars.menuBarItems.count - 1).click()
        let item = app.menuItems["欢迎导览"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Help has no 欢迎导览")
        app.typeKey(.escape, modifierFlags: [])
    }
}
