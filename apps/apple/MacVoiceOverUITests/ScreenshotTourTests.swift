import AppKit
import Foundation
import XCTest

/// Opt-in: walks the signed app through the screens the HCI review records
/// and pauses at each one, so a person (or a script outside the sandboxed
/// runner) can take `screencapture -l` window shots. It announces each pause
/// on the pasteboard as `witerm-shot:<name>` and waits briefly for
/// `witerm-ack:<name>`; without an answer it moves on. Creates one session
/// and ends only that one. Set WITERM_HCI_FIXED_APP and WITERM_HCI_SCREENSHOTS
/// (`en` or `zh-Hans`).
@MainActor
final class ScreenshotTourTests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("witerm-shot:" + name, forType: .string)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, NSPasteboard.general.string(forType: .string) != "witerm-ack:" + name {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    func testCaptureScreens() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], let language = environment["WITERM_HCI_SCREENSHOTS"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_HCI_SCREENSHOTS=en|zh-Hans")
        }
        let chinese = language == "zh-Hans"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", chinese ? "(zh-Hans)" : "(en)", "-AppleLocale", chinese ? "zh_CN" : "en_US",
                               "-witerm.onboarding.completedVersion", chinese ? "0" : "1"]
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let tour = app.descendants(matching: .any)["welcomeTour"].firstMatch
        if chinese {
            // A fresh launch shows the tour; each page in turn, then Skip.
            XCTAssertTrue(tour.waitForExistence(timeout: 10), "The tour didn't appear on a fresh launch")
            for page in 1...4 {
                pause("tour-zh-\(page)")
                let primary = app.buttons["welcomeTourPrimary"]
                if page < 4, primary.exists { primary.click() }
            }
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(tour.waitForNonExistence(timeout: 5))
            app.menuBars.menuBarItems.element(boundBy: app.menuBars.menuBarItems.count - 1).click()
            pause("help-menu-zh")
            app.typeKey(.escape, modifierFlags: [])
            return
        }

        pause("main-launch")
        // A fresh session through ⌘N; an older build asks for a name first.
        let name = "Round 7 " + String(UUID().uuidString.prefix(4))
        app.typeKey("n", modifierFlags: .command)
        let nameField = app.textFields["localSessionName"]
        let askedForName = nameField.waitForExistence(timeout: 3)
        if askedForName {
            nameField.typeKey("a", modifierFlags: .command)
            nameField.typeText(name + "\r")
        }
        let terminal = app.descendants(matching: .any)["localTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        let rowQuery = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "localSession-"))
        if !askedForName {
            // Newer builds name it automatically; give it this run's name.
            app.typeKey("r", modifierFlags: [.command, .shift])
            let rename = app.textFields["localSessionName"]
            if rename.waitForExistence(timeout: 3) {
                rename.typeKey("a", modifierFlags: .command)
                rename.typeText(name + "\r")
            }
        }
        let row = rowQuery.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "No row named \(name)")
        addTeardownBlock { [app] in
            await MainActor.run {
                for button in ["continueCancel", "welcomeTourSkip"] where app?.buttons[button].exists == true { app?.buttons[button].click() }
                guard row.exists else { return }
                row.rightClick()
                app?.menuItems["endSessionMenu"].click()
                guard let confirm = app?.buttons["action-button-1"] else { return }
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
            }
        }
        // Measured for the HCI log: does the new terminal have the keyboard
        // without a click? (An older build asks for a name first.)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let focused = (terminal.value(forKey: "hasKeyboardFocus") as? Bool) == true
        print("WITERM_MEASURE focus_after_new_session=\(focused) asked_for_name=\(askedForName)")
        if !focused { terminal.click() }
        app.typeText("echo Witerm round 7\r")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        pause("main-terminal")

        app.typeKey("p", modifierFlags: [.command, .option])
        let title = app.staticTexts["continueStepTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        pause("continue-sheet")
        app.buttons["continueCancel"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        app.menuBars.menuBarItems.element(boundBy: app.menuBars.menuBarItems.count - 1).click()
        pause("help-menu")
        let tourItem = app.menuItems["Welcome Tour"]
        if tourItem.exists {
            tourItem.click()
            XCTAssertTrue(tour.waitForExistence(timeout: 5))
            for page in 1...4 {
                pause("tour-en-\(page)")
                let primary = app.buttons["welcomeTourPrimary"]
                if page < 4, primary.exists { primary.click() }
            }
            app.buttons["welcomeTourSkip"].click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}
