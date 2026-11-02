import XCTest

/// Opt-in acceptance with a Mac through a real server, run together with the
/// Mac's `PhoneContinuityFlowTests`. The two runs exchange signals through
/// `scripts/e2e-signal-server.py` when WITERM_E2E_SIGNALS names it, otherwise
/// through files; screenshots go to WITERM_E2E_DIR. Continues the Mac's fresh session here (the session opens
/// as soon as the Mac approves), types alongside the Mac, and exercises the
/// terminal's touch gestures.
@MainActor
final class MacContinuityFlowTests: XCTestCase {
    private var folder: URL!
    /// Where the Mac's sandboxed runner writes its files, without a signal server.
    private var macFolder: URL?
    private var signals: E2ESignals?
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("phone-\(name).png"))
    }

    private func signal(_ name: String, _ text: String = "") {
        if let signals { signals.put(name, text); return }
        try? Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func awaitSignal(_ name: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let signals {
                if let text = signals.get(name) { return text }
            } else if let macFolder, let data = try? Data(contentsOf: macFolder.appendingPathComponent(name)) {
                return String(decoding: data, as: UTF8.self)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    private func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    func testPairOpenAndTypeAlongsideMac() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["WITERM_E2E_DIR"], let server = environment["WITERM_E2E_SERVER"],
              environment["WITERM_E2E_SIGNALS"] != nil || environment["WITERM_E2E_MAC_DIR"] != nil else {
            throw XCTSkip("Set WITERM_E2E_DIR, WITERM_E2E_SERVER, and WITERM_E2E_SIGNALS or WITERM_E2E_MAC_DIR")
        }
        folder = URL(fileURLWithPath: directory)
        signals = environment["WITERM_E2E_SIGNALS"].flatMap(URL.init(string:)).map(E2ESignals.init)
        macFolder = environment["WITERM_E2E_MAC_DIR"].map { URL(fileURLWithPath: $0) }
        app = XCUIApplication()
        // A launch-only snippet, never saved, for typing without software keys.
        let snippet = #"[{"id":"0F3D8E2A-6C11-4B7A-9E55-2A9C4D1B7E31","name":"Phone typed","text":"echo phonetyped","runsImmediately":true}]"#
        let snippetHex = Data(snippet.utf8).map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-witerm.serverAddresses", "(\"\(server)\")",
                               "-witerm.commandSnippets", "<\(snippetHex)>",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // A blinking caret never lets XCTest see the app idle.
                               "--witerm-ui-test-steady-terminal-cursor"]
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }

        // Add Device, in Devices.
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
        // The title bar says Typing (not "Switching to Typing…") before the device name.
        func state(_ word: String) -> XCTNSPredicateExpectation {
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", word + ","), object: status)
        }
        wait(for: [state("Typing")], timeout: 30)
        shot("07-terminal")
        signal("phone-attached", UIDevice.current.name)

        // Type while the Mac is attached too. The keyboard is already up:
        // a terminal that can type is ready the moment it connects.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The keyboard didn't come up with the connection")
        // The terminal isn't an accessibility text field (its reading view is),
        // so type with real software keys. After an earlier typeText, XCTest's
        // virtual hardware keyboard can stay attached and the software keys
        // sit off screen; then type the same command with the key row's
        // Snippets key.
        if keyboard.keys["e"].isHittable {
            for character in "echo phonetyped" {
                let key = character == " " ? keyboard.keys["space"] : keyboard.keys[String(character)]
                XCTAssertTrue(key.waitForExistence(timeout: 3), "Missing key \(character)")
                key.tap()
            }
            let returnKey = keyboard.buttons["return"].exists ? keyboard.buttons["return"] : keyboard.keys["return"]
            returnKey.tap()
        } else {
            let snippetsKey = app.buttons["terminalKey-snippets"]
            XCTAssertTrue(snippetsKey.waitForExistence(timeout: 5))
            for _ in 0..<4 where !snippetsKey.isHittable { app.buttons["terminalKey-escape"].swipeLeft() }
            snippetsKey.tap()
            let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Phone typed")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "The Snippets key must list the snippet")
            item.tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("08-typed")
        signal("phone-typed")
        XCTAssertNotNil(awaitSignal("mac-typed", timeout: 240), "The Mac never typed")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("09-together")

        // Stop Typing, then Start Typing: the menu item names the switch from
        // the current state, and the title bar changes as soon as it's done.
        app.buttons["terminalActionsMenu"].tap()
        let stop = app.buttons["Stop Typing"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Typing must offer Stop Typing")
        XCTAssertFalse(app.buttons["Start Typing"].exists)
        shot("09a-menu-typing")
        stop.tap()
        wait(for: [state("Watching")], timeout: 30)
        // The Mac still has the terminal open and can type, so the title says
        // where typing is (from the list it polls while watching).
        let typingOn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Typing on"), object: status)
        wait(for: [typingOn], timeout: 20)
        XCTAssertFalse(app.buttons["remoteKeyboard"].exists, "Watching has no keyboard")
        shot("09b-watching")
        app.buttons["terminalActionsMenu"].tap()
        let startTyping = app.buttons["Start Typing"]
        XCTAssertTrue(startTyping.waitForExistence(timeout: 5), "Watching must offer Start Typing")
        XCTAssertFalse(app.buttons["Stop Typing"].exists)
        shot("09c-menu-watching")
        startTyping.tap()
        wait(for: [state("Typing")], timeout: 30)
        // Start Typing brings the keyboard up, as a new connection does.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        shot("09d-typing-again")
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

/// Signals exchanged with the Mac's runner through the loopback server in
/// `scripts/e2e-signal-server.py`: PUT stores one, GET returns it or 404.
struct E2ESignals {
    let base: URL

    private final class Box: @unchecked Sendable { var text: String? }

    func put(_ name: String, _ text: String) {
        var request = URLRequest(url: base.appendingPathComponent("signal/\(name)"))
        request.httpMethod = "PUT"
        request.httpBody = Data(text.utf8)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
    }

    func get(_ name: String) -> String? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: base.appendingPathComponent("signal/\(name)")) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data { box.text = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return box.text
    }
}
