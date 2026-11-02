import AppKit
import Foundation
import XCTest

/// Opt-in: opens the Continue sheet from a fresh terminal while a script
/// outside the sandboxed runner takes a burst of window shots, so the first
/// frames of the sheet can be checked for views growing out of a corner.
/// The runner asks for the burst on the pasteboard (`witerm-burst:<name>|x,y,w,h`)
/// and waits for `witerm-burst-started:<name>` before pressing ⌥⌘P. Creates
/// one terminal and ends only that one. Set WITERM_HCI_FIXED_APP and
/// WITERM_HCI_SHEET_FRAMES to a name prefix (such as `before` or `after`).
@MainActor
final class SheetOpeningFramesTests: XCTestCase {
    func testContinueSheetOpeningFrames() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], let prefix = environment["WITERM_HCI_SHEET_FRAMES"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_HCI_SHEET_FRAMES")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        // Ends a terminal an interrupted run of this test left, by its exact ID only.
        if let leftover = environment["WITERM_HCI_END_ID"], UUID(uuidString: leftover) != nil {
            let row = app.descendants(matching: .any)["localSession-" + leftover].firstMatch
            if row.waitForExistence(timeout: 5) {
                row.rightClick()
                app.menuItems["endSessionMenu"].click()
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
                XCTAssertTrue(row.waitForNonExistence(timeout: 10))
            }
        }

        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "localSession-"))
        let before = Set(rows.allElementsBoundByIndex.map(\.identifier))
        app.typeKey("n", modifierFlags: .command)
        let terminal = app.descendants(matching: .any)["localTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let createdID = try XCTUnwrap(rows.allElementsBoundByIndex.first { !before.contains($0.identifier) }?.identifier)
        let row = app.descendants(matching: .any)[createdID].firstMatch
        addTeardownBlock {
            await MainActor.run {
                for _ in 0..<2 { app.typeKey(.escape, modifierFlags: []) }
                if app.buttons["continueCancel"].exists { app.buttons["continueCancel"].click() }
                app.activate()
                guard row.waitForExistence(timeout: 3) else { return }
                if row.isHittable {
                    row.rightClick()
                    app.menuItems["endSessionMenu"].click()
                } else {
                    // The selected terminal is still this one: Terminal → End Terminal….
                    app.menuBars.menuBarItems["Terminal"].click()
                    app.menuBars.menuItems.matching(NSPredicate(
                        format: "title == 'End Terminal…' OR title == 'End Session'")).firstMatch.click()
                }
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
            }
        }

        for round in 1...2 {
            let name = "\(prefix)-sheet-open-\(round)"
            let frame = app.windows.firstMatch.frame.insetBy(dx: -8, dy: -8)
            let region = [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0)) }.joined(separator: ",")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("witerm-burst:\(name)|\(region)", forType: .string)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, NSPasteboard.general.string(forType: .string) != "witerm-burst-started:\(name)" {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            app.typeKey("p", modifierFlags: [.command, .option])
            let title = app.staticTexts["continueStepTitle"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            app.buttons["continueCancel"].click()
            _ = title.waitForNonExistence(timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }
}
