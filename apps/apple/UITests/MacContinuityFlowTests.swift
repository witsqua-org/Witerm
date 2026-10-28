import XCTest

/// Opt-in acceptance with a Mac through a real server, run together with the
/// Mac's `PhoneContinuityFlowTests`. The two runs meet through files in
/// WITERM_E2E_DIR. Pairs this device, opens the Mac's fresh session, types
/// alongside the Mac, and exercises the terminal's touch gestures.
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
        app.launchArguments = ["-witerm.serverAddresses", "(\"\(server)\")", "-witerm.startTask", "mac",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // A blinking caret never lets XCTest see the app idle.
                               "--witerm-ui-test-steady-terminal-cursor"]
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }

        // Pair from Machines once the server answers.
        app.tabBars.buttons["Machines"].tap()
        let pair = app.buttons["devicePairing"].firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 30), "The server never offered pairing")
        shot("01-machines")
        let invitation = try XCTUnwrap(awaitSignal("invitation.txt", timeout: 240), "The Mac never published an invitation")
        let session = try XCTUnwrap(awaitSignal("session.txt", timeout: 5))
        pair.tap()
        let field = any("pairingInvitationField")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(invitation)
        app.buttons["preparePairing"].tap()
        let join = app.buttons["joinPairing"]
        XCTAssertTrue(join.waitForExistence(timeout: 10))
        shot("02-review")
        join.tap()
        shot("03-waiting")
        XCTAssertNotNil(awaitSignal("approved", timeout: 240), "The Mac never approved")
        XCTAssertTrue(any("pairingOutcome").waitForExistence(timeout: 30))
        shot("04-paired")
        app.buttons["closePairing"].tap()

        // Open the Mac in Terminals and its fresh session.
        app.tabBars.buttons["Terminals"].tap()
        let mac = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remoteMac-")).firstMatch
        XCTAssertTrue(mac.waitForExistence(timeout: 30))
        shot("05-terminals")
        mac.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "remoteSession-", session)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The session didn't appear")
        shot("06-sessions")
        // Pull to refresh keeps the list.
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let status = any("terminalInputStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let typing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Input Enabled"), object: status)
        wait(for: [typing], timeout: 30)
        shot("07-terminal")
        signal("phone-attached", UIDevice.current.name)

        // Type while the Mac is attached too.
        app.buttons["remoteKeyboard"].tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The keyboard button didn't focus the terminal")
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

        // An edge swipe goes back to the sessions.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The edge swipe didn't go back")
        shot("11-back")
        signal("phone-done")
    }
}
