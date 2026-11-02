import XCTest

/// Opt-in acceptance with a Mac through a real server, run together with the
/// Mac's `PhoneContinuityFlowTests`. The two runs meet through files in
/// WITERM_E2E_DIR. Continues the Mac's fresh session here (the session opens
/// as soon as the Mac approves), types alongside the Mac, and exercises the
/// terminal's touch gestures.
@MainActor
final class MacContinuityFlowTests: XCTestCase {
    private var folder: URL!
    /// Where the Mac's sandboxed runner writes its files.
    private var macFolder: URL!
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("phone-\(name).png"))
    }

    private func signal(_ name: String, _ text: String = "") {
        try? Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func awaitSignal(_ name: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: macFolder.appendingPathComponent(name)) { return String(decoding: data, as: UTF8.self) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    private func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    func testPairOpenAndTypeAlongsideMac() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["WITERM_E2E_DIR"], let macDirectory = environment["WITERM_E2E_MAC_DIR"],
              let server = environment["WITERM_E2E_SERVER"] else {
            throw XCTSkip("Set WITERM_E2E_DIR, WITERM_E2E_MAC_DIR and WITERM_E2E_SERVER")
        }
        folder = URL(fileURLWithPath: directory)
        macFolder = URL(fileURLWithPath: macDirectory)
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-witerm.serverAddresses", "(\"\(server)\")",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // A blinking caret never lets XCTest see the app idle.
                               "--witerm-ui-test-steady-terminal-cursor"]
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }

        // Continue from Another Device, in Devices.
        app.tabBars.buttons["Devices"].tap()
        let start = app.buttons["continueFromDevice"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        shot("01-devices")
        let invitation = try XCTUnwrap(awaitSignal("invitation.txt", timeout: 240), "The Mac never published an invitation")
        _ = try XCTUnwrap(awaitSignal("session.txt", timeout: 5))
        start.tap()
        app.buttons["typeInvitation"].tap()
        let field = any("sessionInvitationField")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.typeText(invitation)
        app.buttons["preparePairing"].tap()
        // Typed, so the check screen shows the Mac's code.
        let join = app.buttons["joinPairing"]
        XCTAssertTrue(join.waitForExistence(timeout: 10))
        shot("02-check")
        join.tap()
        XCTAssertTrue(any("pairingActivity").waitForExistence(timeout: 10))
        shot("03-waiting")
        XCTAssertNotNil(awaitSignal("approved", timeout: 240), "The Mac never approved")

        // Allowed one session, the phone opens it directly.
        let status = any("terminalInputStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let typing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Input Enabled"), object: status)
        wait(for: [typing], timeout: 30)
        shot("07-terminal")
        signal("phone-attached", UIDevice.current.name)

        // Type while the Mac is attached too. The keyboard is already up:
        // a terminal that can type is ready the moment it connects.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The keyboard didn't come up with the connection")
        // The terminal isn't an accessibility text field (its reading view is),
        // so type with real software keys rather than app.typeText.
        for character in "echo phonetyped" {
            let key = character == " " ? keyboard.keys["space"] : keyboard.keys[String(character)]
            XCTAssertTrue(key.waitForExistence(timeout: 3), "Missing key \(character)")
            key.tap()
        }
        let returnKey = keyboard.buttons["return"].exists ? keyboard.buttons["return"] : keyboard.keys["return"]
        returnKey.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("08-typed")
        signal("phone-typed")
        XCTAssertNotNil(awaitSignal("mac-typed", timeout: 240), "The Mac never typed")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("09-together")
        app.buttons["remoteKeyboard"].tap()
        // Hiding the keyboard resizes the grid; let that settle first.
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        // Long press selects; the edit menu offers Copy.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).press(forDuration: 0.8)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("10-selection")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).tap()

        // An edge swipe goes back to the device's sessions.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remoteSession-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The edge swipe didn't go back")
        shot("11-back")
        signal("phone-done")
    }
}
