import AppKit
import Foundation
import XCTest

/// Opt-in: rests the pointer on each custom control that has its own hover
/// feedback or pointer (Round 8), and pauses so a script outside the
/// sandboxed runner can take `screencapture -C` shots with the pointer. Each
/// pause is announced on the pasteboard as `witerm-shot:<name>`; the script
/// answers `witerm-ack:<name>`, and without an answer the test moves on.
/// Creates one terminal and ends only that one. Set WITERM_HCI_FIXED_APP and
/// WITERM_HCI_HOVER_SHOTS=1.
@MainActor
final class HoverScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    /// Pauses for a shot of the frontmost window (in screen points, top left).
    private func pause(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let frame = app.windows.firstMatch.frame.insetBy(dx: -8, dy: -8)
        let region = [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0)) }.joined(separator: ",")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("witerm-shot:" + name + "|" + region, forType: .string)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, NSPasteboard.general.string(forType: .string) != "witerm-ack:" + name {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    func testHoverFeedback() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], environment["WITERM_HCI_HOVER_SHOTS"] == "1" else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_HCI_HOVER_SHOTS=1")
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // The sidebar footer opens Settings → Devices.
        let footer = app.descendants(matching: .any)["serverStatusFooter"].firstMatch
        if footer.waitForExistence(timeout: 5) {
            footer.hover()
            pause("hover-sidebar-footer")
        }

        // A fresh terminal: the I-beam over its text while typing and while watching.
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
                for _ in 0..<2 { app.typeKey(.escape, modifierFlags: []) }
                if app.buttons["continueCancel"].exists { app.buttons["continueCancel"].click() }
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
            rename.typeText("HCI R8 hover\r")
        }
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).hover()
        pause("hover-terminal-typing-ibeam")
        row.rightClick()
        app.menuItems["watchLocalSession"].click()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).hover()
        pause("hover-terminal-watching-ibeam")
        let start = app.buttons["startTypingLocal"]
        if start.exists { start.hover(); pause("hover-toolbar-start-typing-tooltip") }

        // The Continue sheet: the device choices and Change….
        app.typeKey("p", modifierFlags: [.command, .option])
        let title = app.staticTexts["continueStepTitle"]
        if title.waitForExistence(timeout: 10) {
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let change = app.descendants(matching: .any)["continueChangeServer"].firstMatch
            // The element spans the server line; Change… is its right end.
            if change.exists {
                change.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -18, dy: 0)).hover()
                pause("hover-continue-change-link")
            }
            if app.buttons["continueBack"].exists, title.label != "Choose a Device" { app.buttons["continueBack"].click() }
            let guest = app.descendants(matching: .any)["continueGuest"].firstMatch
            if guest.waitForExistence(timeout: 5) {
                guest.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).hover()
                pause("hover-continue-choice-row")
            }
            app.buttons["continueCancel"].click()
            _ = title.waitForNonExistence(timeout: 5)
        }

        // Settings → Devices: Pair a Device… is a link.
        app.typeKey(",", modifierFlags: .command)
        let devices = app.toolbars.buttons["Devices"].firstMatch
        if devices.waitForExistence(timeout: 5) {
            devices.click()
            let pair = app.buttons["createPairingInvitation"].firstMatch
            if pair.waitForExistence(timeout: 5) {
                pair.hover(); pause("hover-settings-pair-link")
            } else {
                let link = app.descendants(matching: .any)["createPairingInvitation"].firstMatch
                if link.exists { link.hover(); pause("hover-settings-pair-link") }
            }
            let commandLine = app.toolbars.buttons["Command Line"].firstMatch
            commandLine.click()
            let copy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy '")).firstMatch
            if copy.waitForExistence(timeout: 5) { copy.click(); pause("click-settings-copy-feedback") }
            app.typeKey("w", modifierFlags: .command)
        }

        // The SSH host form's More Options row; nothing is saved.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let more = app.buttons["sshMoreOptions"]
        if more.waitForExistence(timeout: 5) {
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).hover()
            pause("hover-ssh-form-more-options")
            app.typeKey(.escape, modifierFlags: [])
            _ = more.waitForNonExistence(timeout: 5)
        }

        // The Welcome Tour's page dots.
        app.menuBars.menuBarItems["Help"].click()
        let tourItem = app.menuItems["Welcome Tour"]
        if tourItem.waitForExistence(timeout: 5) {
            tourItem.click()
            let tour = app.descendants(matching: .any)["welcomeTour"].firstMatch
            if tour.waitForExistence(timeout: 5) {
                let primary = app.buttons["welcomeTourPrimary"]
                // The dots sit midway between Skip and Next.
                let skip = app.buttons["welcomeTourSkip"]
                let middle = CGVector(dx: (skip.frame.midX + primary.frame.midX) / 2 - skip.frame.midX - 9, dy: 0)
                skip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(middle).hover()
                pause("hover-tour-page-dot")
                skip.click()
            }
        }
    }
}
