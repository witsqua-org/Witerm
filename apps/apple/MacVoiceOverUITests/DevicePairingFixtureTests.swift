import Foundation
import XCTest

/// Opt-in, against a DEBUG build at WITERM_HCI_FIXED_APP: the device Edit
/// sheet and the Approve step's "Also unpair the older…" choice, without a
/// phone. `-witerm.debug.pairingFixture 1` replaces the relay server's
/// pairing data with an in-memory fixture (`PairingFixture`): "Fixture
/// iPhone" (can watch and type, under an earlier identity) and "Fixture iPad"
/// (can only watch), and Pair a Device… brings a request from "Fixture
/// iPhone" under a new identity. Nothing reaches the relay server or the
/// background service's device access list, and no terminal is touched.
@MainActor
final class DevicePairingFixtureTests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(language: String = "en") throws {
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP to a DEBUG build of the signed app")
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN",
                               "-witerm.onboarding.completedVersion", "1", "-witerm.debug.pairingFixture", "1"]
        app.launch()
        // Quit from the menu so the fixture gives back its colors.
        let launched = app!
        addTeardownBlock { await MainActor.run { launched.typeKey("q", modifierFlags: .command) } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    }

    private func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func openDevices() {
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Devices"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
        XCTAssertTrue(any("editDevice-fixture-phone-older").waitForExistence(timeout: 10), "The fixture's devices aren't listed")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func texts(containing text: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
    }

    // MARK: Edit sheet

    func testDeviceEditSheet() throws {
        continueAfterFailure = false
        try launch()
        openDevices()
        XCTAssertEqual(texts(containing: "Can only watch").count, 1, "Only the iPad starts watch-only")
        capture("fixture-devices")

        // The row's context menu offers the same Edit… and Unpair….
        let tabletEdit = any("editDevice-fixture-tablet")
        tabletEdit.rightClick()
        XCTAssertTrue(any("unpairDeviceMenu-fixture-tablet").waitForExistence(timeout: 3))
        capture("fixture-device-context-menu")
        app.typeKey(.escape, modifierFlags: [])

        // A device that can type: access, typing at once, its code, Unpair….
        any("editDevice-fixture-phone-older").click()
        let watchOnly = app.radioButtons["Can only watch"]
        XCTAssertTrue(watchOnly.waitForExistence(timeout: 5))
        XCTAssertTrue(app.radioButtons["Can watch and type"].exists)
        XCTAssertTrue(app.staticTexts["Device Code"].exists)
        XCTAssertTrue(app.staticTexts["Fixture iPhone"].exists, "The sheet names the device")
        let coTyping = app.checkBoxes["deviceCoTyping-fixture-phone-older"]
        XCTAssertTrue(coTyping.exists)
        XCTAssertTrue(coTyping.isEnabled)
        XCTAssertTrue(any("revokeGrant-grant-fixture-phone-older").exists)
        capture("fixture-edit-sheet-typing")
        watchOnly.click()
        XCTAssertFalse(coTyping.isEnabled, "Typing at the same time needs typing")
        capture("fixture-edit-sheet-watch-only")
        // Esc closes, and the change was already stored.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(watchOnly.waitForNonExistence(timeout: 5))
        let both = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: texts(containing: "Can only watch"))
        XCTAssertEqual(XCTWaiter.wait(for: [both], timeout: 5), .completed, "The row should say Can only watch now")

        // A device paired to only watch says how it could type.
        tabletEdit.click()
        XCTAssertTrue(texts(containing: "Paired to only watch").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.radioButtons["Can watch and type"].exists)
        capture("fixture-edit-sheet-paired-watch-only")
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(texts(containing: "Paired to only watch").firstMatch.waitForNonExistence(timeout: 5))

        // Unpair… confirms, then the device leaves the list.
        any("editDevice-fixture-phone-older").click()
        let unpair = any("revokeGrant-grant-fixture-phone-older")
        XCTAssertTrue(unpair.waitForExistence(timeout: 5))
        unpair.click()
        let confirm = app.buttons["Unpair"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("fixture-unpair-confirmation")
        confirm.click()
        XCTAssertTrue(any("editDevice-fixture-phone-older").waitForNonExistence(timeout: 10))
        XCTAssertTrue(any("editDevice-fixture-tablet").exists)
    }

    // MARK: Approve

    /// Pair a Device…, then the request from the same device under a new
    /// identity, at Approve.
    private func reachApprove() -> XCUIElement {
        openDevices()
        any("createPairingInvitation").click()
        let title = app.staticTexts["continueStepTitle"]
        let approving = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Approve"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [approving], timeout: 15), .completed, "Approve didn't appear: \(title.label)")
        let older = app.checkBoxes["pairingUnpairOlder"]
        XCTAssertTrue(older.waitForExistence(timeout: 5))
        XCTAssertTrue(older.label.contains("Fixture iPhone"), older.label)
        XCTAssertEqual(older.value as? Int, 1, "Also unpair the older… is on by default")
        // Approve stays off until the device may open something.
        // Its label carries the note under it too.
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@ OR title BEGINSWITH %@", "All terminals", "All terminals"))
            .firstMatch.click()
        XCTAssertTrue(any("continueApprove").isEnabled)
        return older
    }

    private func approveAndClose() {
        // Esc must never approve or reject: it's Cancel.
        any("continueApprove").click()
        let title = app.staticTexts["continueStepTitle"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Ready on"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, title.label)
        capture("fixture-approved")
        any("continueDone").click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
    }

    func testApproveAlsoUnpairsTheOlderPairing() throws {
        continueAfterFailure = false
        try launch()
        _ = reachApprove()
        capture("fixture-approve-unpair-older")
        approveAndClose()
        // One "Fixture iPhone": the new pairing.
        XCTAssertTrue(any("editDevice-fixture-phone-new").waitForExistence(timeout: 10))
        XCTAssertFalse(any("editDevice-fixture-phone-older").exists, "The older pairing should have ended")
        // Row text may carry its words in its value rather than its label.
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Fixture iPhone", "Fixture iPhone")).count, 1)
        capture("fixture-devices-after-replace")
    }

    func testApproveKeepingTheOlderPairingTellsThemApart() throws {
        continueAfterFailure = false
        try launch()
        let older = reachApprove()
        older.click()
        XCTAssertEqual(older.value as? Int, 0)
        approveAndClose()
        XCTAssertTrue(any("editDevice-fixture-phone-new").waitForExistence(timeout: 10))
        XCTAssertTrue(any("editDevice-fixture-phone-older").exists)
        // Two rows with one name say when each was paired.
        XCTAssertEqual(texts(containing: "Paired ").matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "·", "·")).count, 2)
        capture("fixture-devices-both-kept")
    }

    /// The Approve step in Chinese: 同时取消与较早的…的配对.
    func testApproveInChinese() throws {
        continueAfterFailure = false
        try launch(language: "zh-Hans")
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["设备"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
        XCTAssertTrue(any("createPairingInvitation").waitForExistence(timeout: 10))
        any("createPairingInvitation").click()
        let older = app.checkBoxes["pairingUnpairOlder"]
        XCTAssertTrue(older.waitForExistence(timeout: 15))
        XCTAssertTrue(older.label.contains("同时取消"), older.label)
        capture("fixture-approve-zh")
        any("continueCancel").click()
    }
}
