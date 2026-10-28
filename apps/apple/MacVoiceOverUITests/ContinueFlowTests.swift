import Foundation
import XCTest

/// Opt-in acceptance against the fixed, signed development app. Only the
/// freshly created session is ended; nothing is shared and remote access is
/// never enabled.
@MainActor
@available(macOS 27.0, *)
final class ContinueFlowTests: XCTestCase {
    func testContinueSheetStartsAtTheFirstUnfinishedStep() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"],
              let id = ProcessInfo.processInfo.environment["WITERM_HCI_SESSION_ID"],
              UUID(uuidString: id) != nil else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and a freshly created WITERM_HCI_SESSION_ID")
        }
        // An acceptance run may have started VoiceOver to diagnose its system
        // precondition. Restore the caller's explicitly recorded off state.
        if ProcessInfo.processInfo.environment["WITERM_HCI_RESTORE_VOICEOVER_OFF"] == "1",
           XCUIDevice.shared.voiceOverService.isEnabled {
            try XCUIDevice.shared.voiceOverService.disable()
        }
        let url = URL(fileURLWithPath: path)
        let app = XCUIApplication(url: url)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }

        let enable = app.buttons["enableLocalTerminal"]
        if enable.waitForExistence(timeout: 3) { enable.click() }
        let row = app.descendants(matching: .any)["localSession-" + id].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.hasPrefix("HCI acceptance"))
        addTeardownBlock {
            await MainActor.run {
                if app.buttons["continueCancel"].exists { app.buttons["continueCancel"].click() }
                guard row.exists else { return }
                row.rightClick()
                app.menuItems["End Session"].click()
                let confirm = app.buttons["action-button-1"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                confirm.click()
                let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
                XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
            }
        }

        row.rightClick()
        app.menuItems["Continue on Another Device…"].click()
        let title = app.staticTexts["continueStepTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // Remote access stays off in this run, so the sheet stops at the server
        // step unless this Mac already allows it; it never skips ahead silently.
        XCTAssertTrue(["Connect This Mac", "Choose a Device"].contains(title.label), title.label)
        if title.label == "Choose a Device" {
            XCTAssertTrue(app.descendants(matching: .any)["continueNewDevice"].firstMatch.exists)
            XCTAssertTrue(app.descendants(matching: .any)["continueGuest"].firstMatch.exists)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "continue-on-another-device"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["continueCancel"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        wait(for: [closed], timeout: 5)
        // Cancelling shares nothing.
        XCTAssertFalse(app.descendants(matching: .any)["localSession-" + id].firstMatch.value as? String ?? "" == "Shared")
    }
}
