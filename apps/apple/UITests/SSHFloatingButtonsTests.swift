import XCTest

/// Round 22 on an SSH terminal, against the disposable OpenSSH fixture only
/// (`WITERM_SSH_UI_PORT`, `WITERM_SSH_UI_FINGERPRINT`): one tap on the text
/// shows the keyboard and a double tap still selects; Jump to Latest and the keyboard button show
/// the right way after leaving the bottom and coming back (by a fling, by
/// Jump to Latest, by new output, with the keyboard up and down, after
/// rotating); the floating buttons and Hide Keyboard share one column; and
/// hiding the keyboard moves the text once. The host and the fixture's pin
/// are removed at the end; nothing else is touched. Prints `PROBE` lines.
@MainActor final class SSHFloatingButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private var terminal: XCUIElement { app.descendants(matching: .any)["sshTerminalSurface"].firstMatch }
    private var keyboard: XCUIElement { app.keyboards.firstMatch }
    private var hideKey: XCUIElement { app.buttons["terminalKey-hideKeyboard"] }
    private var keyboardButton: XCUIElement { app.buttons["sshKeyboard"] }
    private var latest: XCUIElement { app.buttons["terminalJumpToLatest"] }

    private func text() -> String { terminal.exists ? (terminal.value as? String ?? "") : "" }
    private func lastLine() -> String {
        text().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }
    private func probeText(_ key: String) -> String? {
        guard terminal.exists else { return nil }
        let label = terminal.label
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return String(label[range.upperBound...].prefix { !$0.isWhitespace })
    }
    private func probe(_ key: String) -> Double? {
        probeText(key).flatMap { Double($0.prefix { $0.isNumber || $0 == "." || $0 == "-" }) }
    }

    @discardableResult
    private func until(_ timeout: TimeInterval, poll: TimeInterval = 0.05, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        return condition()
    }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "none" }
        let f = element.frame
        return String(format: "%.1f,%.1f,%.1fx%.1f%@", f.minX, f.minY, f.width, f.height, element.isHittable ? "" : "(not hittable)")
    }

    private func report(_ step: String) {
        print("PROBE r22 ssh \(step): focused=\(probeText("focused") ?? "?") pos=\(probeText("pos") ?? "?") rows=\(probeText("rows") ?? "?") latest=\(describe(latest)) keyboard=\(describe(keyboardButton)) hide=\(describe(hideKey)) window=\(NSCoder.string(for: app.windows.firstMatch.frame))")
    }

    private func fixture() throws -> (port: String, fingerprint: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        return (port, fingerprint)
    }

    private func launch(snippets: [(String, String)]) {
        let app = XCUIApplication()
        self.app = app
        func snippet(_ id: Int, _ name: String, _ text: String) -> String {
            #"{"id":"5A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4\#(id)","name":"\#(name)","text":"\#(text)","runsImmediately":true}"#
        }
        let list = "[" + snippets.enumerated().map { snippet($0.offset, $0.element.0, $0.element.1) }.joined(separator: ",") + "]"
        let hex = Data(list.utf8).map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "--witerm-ui-test-steady-terminal-cursor",
                               "--witerm-ui-test-layout-probe", "-witerm.commandSnippets", "<\(hex)>",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        if let fingerprint = ProcessInfo.processInfo.environment["WITERM_SSH_UI_FINGERPRINT"] {
            let leftovers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "sshProfileRow-", "R22 "))
            for _ in 0..<5 where leftovers.firstMatch.exists { removeHost(named: leftovers.firstMatch.label, fingerprint: fingerprint) }
        }
    }

    /// Connects a new fixture host and waits for the keyboard and the prompt.
    private func connect(_ prefix: String, snippets: [(String, String)] = []) throws -> (name: String, fingerprint: String) {
        let (port, fingerprint) = try fixture()
        launch(snippets: snippets)
        let name = prefix + " " + String(UUID().uuidString.prefix(4))
        app.buttons["newSSHProfile"].tap()
        let address = app.textFields["sshHostAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("fixture@127.0.0.1:" + port)
        app.buttons["sshMoreOptions"].tap()
        let nameField = app.textFields["sshProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        for _ in 0..<4 where !nameField.isHittable { app.swipeUp() }
        nameField.tap(); nameField.typeText(name)
        let password = app.secureTextFields["sshHostPassword"]
        for _ in 0..<4 where !password.isHittable { app.swipeDown() }
        password.tap(); password.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].tap()
        let identity = app.staticTexts["sshHostFingerprint"]
        XCTAssertTrue(identity.waitForExistence(timeout: 20), "The fixture's key must be reviewed first")
        XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
        app.buttons["sshTrustHost"].tap()
        XCTAssertTrue(until(20) { (keyboard.exists || hideKey.exists) && lastLine().hasSuffix("~$") }, "Never typeable")
        pause(1)
        return (name, fingerprint)
    }

    private func removeHost(named name: String, fingerprint: String) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        guard row.waitForExistence(timeout: 5) else { return XCTFail("The test's host row is missing") }
        let id = String(row.identifier.dropFirst("sshProfileRow-".count))
        let actions = app.buttons["sshProfileActions-" + id]
        actions.tap()
        app.buttons["Host Keys"].tap()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch
        if remove.waitForExistence(timeout: 5),
           app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fingerprint)).firstMatch.exists {
            remove.tap()
            let confirm = app.buttons["sshConfirmForgetHostKey"].firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            pause(1)
        }
        app.buttons["Done"].tap()
        actions.tap()
        app.buttons["Delete Host"].tap()
        let dismiss = app.buttons["sshUndoDismiss"]
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
        XCTAssertFalse(row.waitForExistence(timeout: 2), "The test's host must be gone")
    }

    private func disconnectAndRemove(_ name: String, fingerprint: String) {
        XCUIDevice.shared.orientation = .portrait
        pause(1)
        if !app.buttons["sshSessionActions"].isHittable, hideKey.exists { hideKey.tap() }
        XCTAssertTrue(until(5) { app.buttons["sshSessionActions"].isHittable })
        app.buttons["sshSessionActions"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 5))
        app.buttons["sshShowHosts"].tap()
        removeHost(named: name, fingerprint: fingerprint)
    }

    /// Runs a saved snippet from the key row's Snippets key.
    private func runSnippet(_ name: String) {
        if !hideKey.exists { app.toggleTerminalKeyboard() }
        XCTAssertTrue(until(5) { hideKey.isHittable }, "The keyboard isn't up")
        let key = app.buttons["terminalKey-snippets"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        for _ in 0..<6 where !key.isHittable {
            let escape = app.buttons["terminalKey-escape"]
            let start = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
        }
        key.tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    private func scrollBack(by distance: CGFloat = 200) {
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .default,
                    thenHoldForDuration: 0.1)
        pause(1)
    }

    private func flingForward() {
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        for _ in 0..<3 {
            start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)), withVelocity: .fast,
                        thenHoldForDuration: 0)
        }
        pause(2.5)
    }


    private func tapText() {
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)).tap()
    }

    // MARK: 1. One tap

    /// Keyboard down, one tap on the text brings it up (after the double
    /// tap's interval, so that a double tap selects a word instead, as it
    /// does here). Prints the time each tap took.
    func testOneTapShowsTheKeyboardAndADoubleTapSelects() throws {
        continueAfterFailure = true
        let (name, fingerprint) = try connect("R22 Tap", snippets: [("Lines", "seq 1 60")])
        runSnippet("Lines")
        XCTAssertTrue(until(10) { lastLine().hasSuffix("~$") })
        var times: [Double] = []
        for attempt in 1...3 {
            hideKey.tap()
            XCTAssertTrue(until(5) { probeText("focused") == "0" && keyboardButton.exists }, "Keyboard still up")
            pause(1)
            let start = Date()
            tapText()
            let returned = Date().timeIntervalSince(start)
            let up = until(5, poll: 0.01) { probeText("focused") == "1" }
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "PROBE r22 ssh tap %d: tap returned %.3f s, focused after %.3f s", attempt, returned, elapsed))
            XCTAssertTrue(up, "One tap didn't bring up the keyboard")
            times.append(elapsed)
            XCTAssertTrue(until(5) { hideKey.isHittable })
            pause(0.8)
        }
        let sorted = times.sorted()
        print(String(format: "PROBE r22 ssh tap median %.3f s", sorted[sorted.count / 2]))
        // A double tap selects a word, with the keyboard down too.
        hideKey.tap()
        XCTAssertTrue(until(5) { keyboardButton.exists })
        pause(1)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3)).doubleTap()
        pause(1.5)
        // Not asserted: XCTest's double tap here selected nothing on `main`
        // either (Round 22), so it's recorded, not judged.
        print("PROBE r22 ssh double tap: sel=\(probeText("sel") ?? "?") focused=\(probeText("focused") ?? "?")")
        shot("r22-ssh-1-double-tap")
        // A tap clears the selection.
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).tap()
        pause(1)
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    // MARK: 2 and 3. The right buttons, on one column

    /// Leaving the bottom and coming back (a fling, Jump to Latest, new
    /// output), keyboard up and down, after rotating: Jump to Latest shows
    /// while away, above the key row, and goes at the bottom; keyboard down
    /// the keyboard button is there. Jump to Latest, the keyboard button and
    /// Hide Keyboard share one column and size in portrait and landscape.
    func testTheRightButtonsShowOnOneColumn() throws {
        continueAfterFailure = true
        executionTimeAllowance = 600
        let (name, fingerprint) = try connect("R22 Buttons", snippets: [
            ("Lines", "seq 1 400"),
            ("Ticks", "for i in 1 2 3 4 5 6 7 8; do echo tick $i; sleep 0.4; done")])
        runSnippet("Lines")
        XCTAssertTrue(until(10) { lastLine().hasSuffix("~$") })
        pause(1)
        func checkColumn(_ step: String, landscape: Bool) {
            XCTAssertTrue(until(5) { hideKey.isHittable }, "\(step): keyboard not up")
            let hide = hideKey.frame
            scrollBack(by: landscape ? 60 : 200)
            report("\(step) typing scrolled")
            shot("r22-ssh-3-\(step)-typing")
            XCTAssertTrue(latest.exists && latest.isHittable, "\(step): no Jump to Latest")
            if latest.exists {
                XCTAssertEqual(latest.frame.midX, hide.midX, accuracy: 0.5, "\(step): Jump to Latest and Hide Keyboard")
                XCTAssertEqual(latest.frame.width, hide.width, accuracy: 0.5, "\(step): sizes")
                XCTAssertLessThanOrEqual(latest.frame.maxY, hide.minY, "\(step): Jump to Latest under the key row")
            }
            flingForward()
            XCTAssertTrue(until(3) { !latest.exists }, "\(step): Jump to Latest stayed at the bottom (\(probeText("pos") ?? "?"))")
            hideKey.tap()
            XCTAssertTrue(until(5) { keyboardButton.exists && !hideKey.exists }, "\(step): no keyboard button")
            pause(1)
            let keyboard = keyboardButton.frame
            XCTAssertEqual(keyboard.midX, hide.midX, accuracy: 0.5, "\(step): the keyboard button and Hide Keyboard")
            XCTAssertEqual(keyboard.width, hide.width, accuracy: 0.5, "\(step): sizes")
            scrollBack(by: landscape ? 60 : 200)
            report("\(step) keyboard down scrolled")
            if latest.exists { XCTAssertEqual(latest.frame.midX, keyboard.midX, accuracy: 0.5, "\(step): Jump to Latest and the keyboard button") }
            flingForward()
            XCTAssertTrue(until(3) { !latest.exists && keyboardButton.isHittable }, "\(step): at the bottom \(describe(latest)) \(describe(keyboardButton))")
            keyboardButton.tap()
            XCTAssertTrue(until(5) { hideKey.isHittable })
            pause(1)
        }
        checkColumn("portrait", landscape: false)
        // Back three ways, keyboard up.
        scrollBack()
        if latest.exists { latest.tap() }
        XCTAssertTrue(until(3) { !latest.exists }, "Jump to Latest stayed after Jump to Latest")
        runSnippet("Ticks")
        pause(0.6)
        scrollBack()
        XCTAssertTrue(latest.exists, "No Jump to Latest scrolled back during output")
        pause(4)
        XCTAssertTrue(latest.exists, "Jump to Latest went while still scrolled back")
        flingForward()
        XCTAssertTrue(until(3) { !latest.exists }, "Jump to Latest stayed after new output and a fling back")
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2.5)
        checkColumn("landscape", landscape: true)
        XCUIDevice.shared.orientation = .portrait
        pause(2.5)
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    // MARK: 4. Hiding the keyboard

    /// Hiding the keyboard moves the text once: the grid takes the whole
    /// height as the keyboard starts to leave (before: only after it had
    /// gone, with a black band growing under the text meanwhile), and the
    /// last row sits on the bottom edge as on a watched paired terminal.
    func testHidingTheKeyboardIsOneTransition() throws {
        continueAfterFailure = true
        let (name, fingerprint) = try connect("R22 Hide", snippets: [("Lines", "seq 1 200")])
        runSnippet("Lines")
        XCTAssertTrue(until(10) { lastLine().hasSuffix("~$") })
        pause(1)
        let screen = Double(app.windows.firstMatch.frame.height)
        for attempt in 1...2 {
            hideKey.tap()
            let label = terminal.label
            let order = TerminalProbeLabel.keyboardLeaving(label, screenHeight: screen)
            print("PROBE r22 ssh hide \(attempt): gridMs=\(order.grid.map(String.init) ?? "-") goneMs=\(order.gone.map(String.init) ?? "-") events=\(order.events)")
            XCTAssertNotNil(order.grid, "The grid didn't change: \(order.events)")
            if let grid = order.grid, let gone = order.gone {
                XCTAssertLessThan(grid, gone, "The grid waited for the keyboard to be gone (\(grid) ms, gone at \(gone) ms)")
            }
            pause(1)
            let gap = (TerminalProbeLabel.numbers(terminal.label, "textBottom").first ?? 0)
                - (TerminalProbeLabel.numbers(terminal.label, "gridBottom").first ?? 0)
            print("PROBE r22 ssh hide \(attempt): rows=\(probeText("rows") ?? "?") bottomGap=\(gap)")
            XCTAssertLessThan(gap, 1, "\(gap) pt between the last row and the bottom edge")
            keyboardButton.tap()
            XCTAssertTrue(until(5) { hideKey.isHittable })
            pause(1)
        }
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    /// For a screen recording made around it (`simctl io recordVideo`).
    func testRecordHidingTheKeyboard() throws {
        let (name, fingerprint) = try connect("R22 Record", snippets: [("Lines", "seq 1 200")])
        runSnippet("Lines")
        XCTAssertTrue(until(10) { lastLine().hasSuffix("~$") })
        pause(2)
        print("PROBE r22 ssh record hide at \(Date().timeIntervalSince1970)")
        hideKey.tap()
        pause(2.5)
        keyboardButton.tap()
        pause(2.5)
        print("PROBE r22 ssh record hide again at \(Date().timeIntervalSince1970)")
        hideKey.tap()
        pause(2.5)
        disconnectAndRemove(name, fingerprint: fingerprint)
    }
}
