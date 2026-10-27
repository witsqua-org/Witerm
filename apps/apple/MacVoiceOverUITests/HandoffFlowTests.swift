import Foundation
import XCTest

/// Opt-in acceptance against the fixed, signed development app. Only the
/// freshly created session is shared or ended; remote access is never enabled.
@MainActor
@available(macOS 27.0, *)
final class HandoffFlowTests: XCTestCase {
    func testPreparationAndSharingOfFreshSession() throws {
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
                if app.buttons["Done"].exists { app.buttons["Done"].click() }
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
        app.menuItems["Continue on iPhone…"].click()
        let readiness = app.descendants(matching: .any)["handoffReadiness"].firstMatch
        XCTAssertTrue(readiness.waitForExistence(timeout: 10))
        XCTAssertTrue(((readiness.value as? String ?? "") + readiness.label).contains("Prepare This Session"))
        let sharing = app.descendants(matching: .any)["handoffShareSession"].firstMatch
        // Pairing controls may precede the sharing toggle in the scrolling sheet.
        for _ in 0..<8 where !sharing.isHittable { app.sheets.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(sharing.isHittable)
        sharing.click()
        let shared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: sharing)
        wait(for: [shared], timeout: 10)
        // Sharing alone must never imply that the phone can reach the Mac.
        XCTAssertFalse(((readiness.value as? String ?? "") + readiness.label).contains("Ready to Open on iPhone"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "handoff-preparation"
        attachment.lifetime = .keepAlways
        add(attachment)
        sharing.click()
        let privateAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 0"), object: sharing)
        wait(for: [privateAgain], timeout: 10)
    }
}
