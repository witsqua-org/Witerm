import AppKit
import Foundation
import XCTest

/// Opt-in: walks the signed app through the screens the Round 8 wording
/// review records (the main window, a terminal's context menu before and
/// after switching to watching, the toolbar and menu-bar menus, the Continue
/// sheet, and Settings) and attaches a picture of each. Works against the
/// build before the review and after it, so only identifiers both share, or
/// a list of fallbacks, are used. Creates one terminal and ends only that one.
/// Set WITERM_HCI_FIXED_APP and WITERM_HCI_ROUND8_SHOTS=1.
@MainActor
final class Round8ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    /// The app's window, and any open menu, from a full-screen picture.
    private func shot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let screen = XCUIScreen.main.screenshot()
        var area = app.windows.firstMatch.frame
        for menu in app.menus.allElementsBoundByIndex where menu.exists && !menu.frame.isEmpty {
            area = area.union(menu.frame)
        }
        for sheet in app.sheets.allElementsBoundByIndex where sheet.exists { area = area.union(sheet.frame) }
        let image = screen.image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            add(XCTAttachment(screenshot: screen))
            return
        }
        let points = NSScreen.screens.first?.frame.size ?? image.size
        let scale = CGFloat(cg.width) / points.width
        let crop = area.insetBy(dx: -12, dy: -12)
            .intersection(CGRect(origin: .zero, size: points))
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
        let attachment: XCTAttachment
        if let cropped = cg.cropping(to: pixels) {
            attachment = XCTAttachment(image: NSImage(cgImage: cropped, size: crop.size))
        } else {
            attachment = XCTAttachment(screenshot: screen)
        }
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The first menu item that exists, by identifier or title.
    private func menuItem(_ candidates: [String]) -> XCUIElement? {
        for candidate in candidates {
            let item = app.menuItems[candidate]
            if item.exists { return item }
        }
        return nil
    }

    func testCaptureRound8Screens() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], environment["WITERM_HCI_ROUND8_SHOTS"] == "1" else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_HCI_ROUND8_SHOTS=1")
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        // Ends terminals an interrupted run of this test left, by their prefix only.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let leftovers = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "localSession-", "HCI R8 "))
        for _ in 0..<5 {
            let leftover = leftovers.firstMatch
            guard leftover.exists else { break }
            leftover.rightClick()
            app.menuItems["endSessionMenu"].click()
            let confirm = app.buttons["action-button-1"]
            if confirm.waitForExistence(timeout: 5) { confirm.click() }
            _ = leftover.waitForNonExistence(timeout: 10)
        }
        shot("01-main-launch")

        // A fresh terminal through ⌘N, renamed so it can't be confused with another.
        let name = "HCI R8 " + String(UUID().uuidString.prefix(4))
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "localSession-"))
        let before = Set(rows.allElementsBoundByIndex.map(\.identifier))
        app.typeKey("n", modifierFlags: .command)
        let terminal = app.descendants(matching: .any)["localTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let createdID = try XCTUnwrap(rows.allElementsBoundByIndex.first { !before.contains($0.identifier) }?.identifier)
        let row = app.descendants(matching: .any)[createdID].firstMatch
        addTeardownBlock { [app] in
            await MainActor.run {
                guard let app else { return }
                app.typeKey(.escape, modifierFlags: [])
                app.typeKey(.escape, modifierFlags: [])
                if app.windows["General"].exists || app.windows["Devices"].exists || app.windows["Command Line"].exists {
                    app.typeKey("w", modifierFlags: .command)
                }
                for button in ["continueCancel"] where app.buttons[button].exists { app.buttons[button].click() }
                guard row.exists else { return }
                row.rightClick()
                app.menuItems["endSessionMenu"].click()
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
            }
        }
        app.typeKey("r", modifierFlags: [.command, .shift])
        let rename = app.textFields["localSessionName"]
        if rename.waitForExistence(timeout: 5) {
            rename.typeKey("a", modifierFlags: .command)
            rename.typeText(name + "\r")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if (terminal.value(forKey: "hasKeyboardFocus") as? Bool) != true { terminal.click() }
        app.typeText("echo Witerm round 8\r")
        shot("02-terminal-typing")

        // The row's context menu while typing, then switching to watching.
        row.rightClick()
        XCTAssertTrue(app.menus.firstMatch.waitForExistence(timeout: 5))
        shot("03-row-menu-typing")
        if let watch = menuItem(["watchLocalSession", "View Only"]) {
            watch.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("04-terminal-watching")
        row.rightClick()
        XCTAssertTrue(app.menus.firstMatch.waitForExistence(timeout: 5))
        shot("05-row-menu-watching")
        app.typeKey(.escape, modifierFlags: [])

        // The toolbar's More menu and the menu bar's File and Terminal menus.
        let more = app.descendants(matching: .any)["localTerminalMore"].firstMatch
        if more.waitForExistence(timeout: 5) {
            more.click()
            shot("06-more-menu-watching")
            app.typeKey(.escape, modifierFlags: [])
        }
        for (index, title) in ["File", "Terminal"].enumerated() {
            let item = app.menuBars.menuBarItems[title]
            guard item.exists else { continue }
            item.click()
            shot(String(format: "%02d-menubar-%@", 7 + index, title.lowercased()))
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        // Back to typing, then the More menu again.
        row.rightClick()
        if let typing = menuItem(["typeLocalSession", "Connect"]) { typing.click() } else { app.typeKey(.escape, modifierFlags: []) }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        if more.waitForExistence(timeout: 5) {
            more.click()
            shot("09-more-menu-typing")
            app.typeKey(.escape, modifierFlags: [])
        }

        // Continue on Another Device, as far as it goes on its own.
        app.typeKey("p", modifierFlags: [.command, .option])
        let title = app.staticTexts["continueStepTitle"]
        if title.waitForExistence(timeout: 10) {
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            shot("10-continue-sheet")
            app.buttons["continueCancel"].click()
            _ = title.waitForNonExistence(timeout: 5)
        }

        // Leave, then the state a left terminal shows.
        row.rightClick()
        if let leave = menuItem(["leaveLocalSession"]) {
            leave.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            if more.waitForExistence(timeout: 5) { more.click(); app.menuItems["detachLocalTerminal"].click() }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("11-terminal-left")

        // The end confirmation, cancelled here; the teardown ends it.
        row.rightClick()
        app.menuItems["endSessionMenu"].click()
        let confirm = app.buttons["action-button-1"]
        if confirm.waitForExistence(timeout: 5) {
            shot("12-end-confirmation")
            app.typeKey(.escape, modifierFlags: [])
        }

        // Settings: General, Devices, Command Line.
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS 'Settings' OR title CONTAINS 'General' OR title CONTAINS 'Devices'")).firstMatch
        _ = settings.waitForExistence(timeout: 5)
        for (index, tab) in ["General", "Devices", "Command Line"].enumerated() {
            let button = app.toolbars.buttons[tab].firstMatch
            guard button.waitForExistence(timeout: 5) else { continue }
            button.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let window = app.windows.firstMatch
            let image = XCUIScreen.main.screenshot().image
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let points = NSScreen.screens.first?.frame.size ?? image.size
                let scale = CGFloat(cg.width) / points.width
                let frame = window.frame.insetBy(dx: -12, dy: -12).intersection(CGRect(origin: .zero, size: points))
                if let cropped = cg.cropping(to: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                                        width: frame.width * scale, height: frame.height * scale)) {
                    let attachment = XCTAttachment(image: NSImage(cgImage: cropped, size: frame.size))
                    attachment.name = String(format: "%02d-settings-%@", 13 + index, tab.lowercased().replacingOccurrences(of: " ", with: "-"))
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        app.typeKey("w", modifierFlags: .command)
    }
}
