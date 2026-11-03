import XCTest

/// How a live SSH terminal feels, measured against the disposable OpenSSH
/// fixture only: the time from approving a host (or tapping Connect) to a
/// terminal you can type in, `seq 1 100000` from the snippet's tap to the
/// prompt, the app's memory before and after (from the DEBUG layout probe),
/// scrolling through that output, the keyboard hiding and showing, and
/// rotation. Prints `PERF name value` lines for the round's table. The host
/// and the fixture's pin are removed at the end; nothing else is touched.
@MainActor final class TerminalPerformanceTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private var terminal: XCUIElement { app.descendants(matching: .any)["sshTerminalSurface"].firstMatch }
    private func text() -> String { terminal.exists ? (terminal.value as? String ?? "") : "" }
    private func lastLine() -> String {
        text().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }
    private func probe(_ key: String) -> Double? {
        guard terminal.exists else { return nil }
        let label = terminal.label
        guard let range = label.range(of: key + "=") else { return nil }
        return Double(label[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }
    private func now() -> Double { Date().timeIntervalSinceReferenceDate }
    private func report(_ name: String, _ value: Double, _ format: String = "%.2f") {
        print("PERF \(name) " + String(format: format, value))
    }

    /// Polls until `condition` holds; returns the seconds it took, or nil.
    /// The system's Save Password offer can cover the app at any time after
    /// the form closes; it's declined, never accepted.
    private func until(_ timeout: TimeInterval, poll: TimeInterval = 0.05, _ condition: () -> Bool) -> Double? {
        let start = now()
        while now() - start < timeout {
            if condition() { return now() - start }
            let offer = app.buttons["Not Now"]
            if offer.exists, offer.isHittable { offer.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        return condition() ? now() - start : nil
    }

    private var typeable: Bool { app.keyboards.firstMatch.exists && lastLine().hasSuffix("~$") }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func declinePasswordOffer() {
        for offer in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where offer.waitForExistence(timeout: 0.5) {
            offer.tap()
        }
    }

    private func runSnippet(_ name: String) {
        // After a rotation the keyboard may still be settling; toggling it
        // then would hide it.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 1.5) { app.buttons["sshKeyboard"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let key = app.buttons["terminalKey-snippets"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        for _ in 0..<6 where !key.isHittable {
            let escape = app.buttons["terminalKey-escape"]
            let start = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
        }
        key.tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), name)
        item.tap()
    }

    private func grid() -> (rows: Int, columns: Int)? {
        text().split(whereSeparator: \.isNewline).reversed().lazy.compactMap { line -> (Int, Int)? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 2, let rows = Int(parts[0]), let columns = Int(parts[1]) else { return nil }
            return (rows, columns)
        }.first
    }

    /// Removes a host this test made, and its pin only when it's the fixture's.
    private func removeHost(_ row: XCUIElement, fingerprint: String) {
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
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        app.buttons["Done"].tap()
        actions.tap()
        app.buttons["Delete Host"].tap()
        let dismiss = app.buttons["sshUndoDismiss"]
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// Opt-in recovery after an interrupted run: removes only hosts named
    /// "Perf SSH …" and only pins that show the fixture's fingerprint.
    func testRemoveLeftoverPerformanceHosts() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WITERM_PERF_CLEANUP"] == "1", let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"] else {
            throw XCTSkip("Explicit leftover cleanup only")
        }
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        app.tabBars.buttons.element(boundBy: 0).tap()
        let leftovers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "sshProfileRow-", "Perf SSH "))
        _ = leftovers.firstMatch.waitForExistence(timeout: 5)
        for _ in 0..<5 where leftovers.firstMatch.exists { removeHost(leftovers.firstMatch, fingerprint: fingerprint) }
        XCTAssertFalse(leftovers.firstMatch.exists)
    }

    func testTimeToTypeLongOutputScrollKeyboardAndRotation() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        let name = "Perf SSH " + String(UUID().uuidString.prefix(4))
        func snippet(_ id: Int, _ name: String, _ text: String) -> String {
            #"{"id":"7C2D3F1B-6B54-4A8F-8D9C-2E3F4051627\#(id)","name":"\#(name)","text":"\#(text)","runsImmediately":true}"#
        }
        let snippets = "[" + [snippet(1, "Hundred thousand", "seq 1 100000"), snippet(2, "Grid size", "stty size"),
                              snippet(3, "Clear screen", "clear")].joined(separator: ",") + "]"
        let hex = Data(snippets.utf8).map { String(format: "%02x", $0) }.joined()
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "--witerm-ui-test-steady-terminal-cursor",
                               "--witerm-ui-test-layout-probe", "-witerm.commandSnippets", "<\(hex)>",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        // 1. A new host: from approving its key to a terminal you can type in.
        app.tabBars.buttons.element(boundBy: 0).tap()
        let add = app.buttons["newSSHProfile"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        // Leftovers of an interrupted run of this test, by their unique prefix.
        let leftovers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "sshProfileRow-", "Perf SSH "))
        for _ in 0..<5 where leftovers.firstMatch.exists { removeHost(leftovers.firstMatch, fingerprint: fingerprint) }
        add.tap()
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
        let connect = app.buttons["sshConnect"]
        connect.tap()
        let identity = app.staticTexts["sshHostFingerprint"]
        let prompted = until(20) { identity.exists }
        XCTAssertNotNil(prompted, "The fixture's key must be reviewed first")
        report("connect_to_trust_prompt_s", prompted ?? -1)
        XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
        let trust = app.buttons["sshTrustHost"]
        XCTAssertNotNil(until(10) { trust.isHittable && !app.buttons["Not Now"].exists })
        trust.tap()
        let firstTypeable = until(20) { typeable }
        XCTAssertNotNil(firstTypeable, "The first connection never became typeable")
        report("trust_to_typeable_s", firstTypeable ?? -1)
        declinePasswordOffer()
        shot("perf-01-connected")
        let connectedMemory = probe("mem") ?? -1
        report("memory_connected_mb", connectedMemory, "%.1f")

        // 2. `seq 1 100000`: from the snippet's tap to the prompt after it.
        runSnippet("Grid size")
        XCTAssertNotNil(until(10) { grid() != nil })
        let portraitUp = try XCTUnwrap(grid())
        runSnippet("Hundred thousand")
        // Polled rarely: every query snapshots the app on its main thread,
        // which would slow the very output being timed. The app's own probe
        // says how long the output took from its first to its last delivery.
        let finished = until(120, poll: 2) { let page = text(); return page.contains("100000") && lastLine().hasSuffix("~$") }
        XCTAssertNotNil(finished, "seq 1 100000 never finished on screen")
        let burst = probe("burst") ?? -1
        report("seq100k_render_seconds", burst)
        report("seq100k_lines_per_s", 100_000 / max(0.001, burst), "%.0f")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let longMemory = probe("mem") ?? -1
        report("memory_after_seq100k_mb", longMemory, "%.1f")
        report("memory_growth_seq100k_mb", longMemory - connectedMemory, "%.1f")
        shot("perf-02-seq100k")

        // 3. Scrolling back through it, then back to the prompt with Jump to Latest.
        app.buttons["sshKeyboard"].tap()
        XCTAssertNotNil(until(5) { !app.keyboards.firstMatch.exists })
        // Hitches while a fling decelerates, as UIKit's scroll signposts count them.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            terminal.swipeDown(velocity: .fast)
            stopMeasuring()
        }
        for _ in 0..<3 { terminal.swipeDown(velocity: .fast) }
        XCTAssertFalse(lastLine().hasSuffix("~$"), "Flinging down must scroll back")
        let latest = app.buttons["terminalJumpToLatest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3), "Scrolled back, Jump to Latest must appear")
        shot("perf-03-scrolled-back")
        latest.tap()
        let back = until(5) { lastLine().hasSuffix("~$") }
        XCTAssertNotNil(back, "Jump to Latest must return to the prompt")
        report("jump_to_latest_s", back ?? -1)

        // 4. The keyboard: showing it keeps the prompt above the key row; hiding
        // it gives every row back, ten times over.
        let downFrame = terminal.frame
        var worstShow = 0.0, worstHide = 0.0
        for _ in 0..<5 {
            app.buttons["sshKeyboard"].tap()
            worstShow = max(worstShow, until(5) { typeable } ?? 99)
            app.buttons["sshKeyboard"].tap()
            worstHide = max(worstHide, until(5) { !app.keyboards.firstMatch.exists && abs(terminal.frame.maxY - downFrame.maxY) < 1 } ?? 99)
        }
        report("keyboard_show_prompt_worst_s", worstShow)
        report("keyboard_hide_restored_worst_s", worstHide)
        XCTAssertEqual(terminal.frame, downFrame, "Hiding the keyboard must restore the same frame")

        // 5. Rotation: landscape widens the grid, portrait restores it, and
        // the prompt stays on screen both ways.
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = until(5) { terminal.frame.width > terminal.frame.height }
        report("rotate_landscape_s", rotated ?? -1)
        runSnippet("Grid size")
        XCTAssertNotNil(until(10) { (grid()?.columns ?? 0) > portraitUp.columns })
        let landscape = grid()
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$") }, "The prompt must stay on screen in landscape")
        shot("perf-04-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertNotNil(until(5) { terminal.frame.width < terminal.frame.height })
        runSnippet("Grid size")
        XCTAssertNotNil(until(10) { grid().map { $0.columns == portraitUp.columns } ?? false }, "Portrait must restore the columns")
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$") }, "The prompt must stay on screen back in portrait")
        print("PERF grid portrait=\(portraitUp) landscape=\(String(describing: landscape)) back=\(String(describing: grid()))")
        shot("perf-05-portrait-again")

        // 6. Reconnecting a saved host: from Connect to typeable, no key review.
        app.buttons["sshSessionActions"].tap()
        app.buttons["Disconnect"].tap()
        let reconnect = app.buttons["sshReconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        let again = app.secureTextFields["sshHostPassword"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap(); again.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].tap()
        let second = until(20) { typeable }
        XCTAssertNotNil(second, "The reconnection never became typeable")
        report("reconnect_tap_to_typeable_s", second ?? -1)
        declinePasswordOffer()

        // Cleanup: disconnect, then remove the fixture's pin and the host.
        app.buttons["sshSessionActions"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        app.buttons["sshShowHosts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        removeHost(row, fingerprint: fingerprint)
        XCTAssertFalse(row.waitForExistence(timeout: 2), "The test's host must be gone")
    }
}
