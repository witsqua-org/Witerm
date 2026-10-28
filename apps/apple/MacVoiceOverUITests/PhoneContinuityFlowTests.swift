import AppKit
import Foundation
import XCTest

/// Opt-in acceptance with an iPhone (or simulator) through a real server,
/// run together with `MacContinuityFlowTests` on the phone. The two runs
/// meet through files in WITERM_E2E_DIR. Creates one fresh session, pairs
/// the phone with control over all sessions, types alongside it, then ends
/// the session and revokes that pairing. Nothing else is touched. The
/// sandboxed runner reads the phone's files from WITERM_E2E_DIR and writes
/// its own to `witerm-e2e` in its temporary folder.
@MainActor
final class PhoneContinuityFlowTests: XCTestCase {
    private var folder: URL!
    private let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-e2e", isDirectory: true)
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        try? app.screenshot().pngRepresentation.write(to: outbox.appendingPathComponent("mac-\(name).png"))
    }

    private func signal(_ name: String, _ text: String = "") {
        try? Data(text.utf8).write(to: outbox.appendingPathComponent(name), options: .atomic)
    }

    private func awaitSignal(_ name: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { return String(decoding: data, as: UTF8.self) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    /// Chooses the server in a sheet's picker, when it shows one.
    private func chooseServer(_ host: String) {
        let picker = app.sheets.popUpButtons.firstMatch
        guard picker.waitForExistence(timeout: 3) else { return }
        guard !(picker.value as? String ?? "").contains(host) else { return }
        picker.click()
        let item = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", host)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    func testPairAndTypeAlongsidePhone() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], let directory = environment["WITERM_E2E_DIR"],
              let server = environment["WITERM_E2E_SERVER"], let host = URL(string: server)?.host else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP, WITERM_E2E_DIR and WITERM_E2E_SERVER")
        }
        folder = URL(fileURLWithPath: directory)
        try? FileManager.default.removeItem(at: outbox)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let enable = app.buttons["enableLocalTerminal"]
        if enable.waitForExistence(timeout: 3) { enable.click() }

        // A fresh session, the only one this test shares or ends.
        let name = "Phone E2E " + String(UUID().uuidString.prefix(6))
        app.typeKey("n", modifierFlags: .command)
        let nameField = app.textFields["localSessionName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        app.buttons["createLocalSession"].click()
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "localSession-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        addTeardownBlock { [app] in
            await MainActor.run {
                guard let app else { return }
                // A sheet left open by a failure would block the menu.
                if app.buttons["closePairing"].exists { app.buttons["closePairing"].click() }
                guard row.waitForExistence(timeout: 3) else { return }
                row.rightClick()
                app.menuItems["End Session"].click()
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
            }
        }
        signal("session.txt", name)
        row.click()
        shot("01-session")

        // The pairing sheet opens straight to a QR code.
        app.typeKey("p", modifierFlags: [.command, .option])
        chooseServer(host)
        let copy = app.buttons["copyPairingInvitation"]
        XCTAssertTrue(copy.waitForExistence(timeout: 30), "The pairing sheet didn't show an invitation")
        shot("02-pair-sheet")
        NSPasteboard.general.clearContents()
        copy.click()
        let invitation = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(invitation.hasPrefix("witerm://pair") && invitation.contains(host))
        signal("invitation.txt", invitation)

        // Approve the phone with control over every session.
        let approve = app.buttons["approvePairing"]
        XCTAssertTrue(approve.waitForExistence(timeout: 240), "No pairing request arrived")
        app.descendants(matching: .any)["pairingPermissionControl"].firstMatch.click()
        shot("03-request")
        approve.click()
        XCTAssertTrue(app.descendants(matching: .any)["pairingOutcome"].firstMatch.waitForExistence(timeout: 30))
        shot("04-approved")
        app.buttons["closePairing"].click()
        signal("approved")

        // Type alongside the phone in the same session.
        let phone = try XCTUnwrap(awaitSignal("phone-attached", timeout: 300), "The phone never attached")
        row.click()
        let terminal = app.descendants(matching: .any)["localTerminalSurface"].firstMatch
        if terminal.waitForExistence(timeout: 10) { terminal.click() }
        let status = app.descendants(matching: .any)["sessionSharingStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15), "The header didn't show the attached phone")
        // Take turns, as people do: the grid stays with whoever is typing.
        XCTAssertNotNil(awaitSignal("phone-typed", timeout: 120), "The phone never typed")
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        app.typeText("echo MAC_TYPED\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("05-together")
        signal("mac-typed")
        XCTAssertNotNil(awaitSignal("phone-done", timeout: 300), "The phone didn't finish")
        shot("06-after")

        // Revoke only this test's pairing.
        app.typeKey("p", modifierFlags: [.command, .option])
        chooseServer(host)
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "revokeGrant-", phone)).firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 20))
        revoke.click()
        let confirm = app.buttons["action-button-1"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.buttons["closePairing"].click()
    }
}
