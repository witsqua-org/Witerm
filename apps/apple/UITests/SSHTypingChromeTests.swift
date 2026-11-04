import UIKit
import XCTest

/// Round 13, against the disposable OpenSSH fixture only: connecting from the
/// host form never brings up the system's Save Password offer (typing and
/// pasting into the password field still work), and on iPhone in landscape
/// the navigation bar steps aside while the keyboard is up, with Hide
/// Keyboard and the terminal's actions on the key row. Round 14 adds the
/// grid after rotating with the key row up and after a text size change,
/// each checked against what the host's `stty size` says. Prints `PERF` lines.
/// The host and the fixture's pin are removed at the end; nothing else is
/// touched. `WITERM_R13_BASELINE=1` measures without asserting the new
/// behavior, for the numbers before.
@MainActor final class SSHTypingChromeTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let baseline = ProcessInfo.processInfo.environment["WITERM_R13_BASELINE"] == "1"

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private var terminal: XCUIElement { app.descendants(matching: .any)["sshTerminalSurface"].firstMatch }
    private var keyboard: XCUIElement { app.keyboards.firstMatch }
    private func text() -> String { terminal.exists ? (terminal.value as? String ?? "") : "" }
    private func lastLine() -> String {
        text().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }
    private func probe(_ key: String) -> Double? {
        guard terminal.exists else { return nil }
        let label = terminal.label
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return Double(label[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }
    private func now() -> Double { Date().timeIntervalSinceReferenceDate }
    private func report(_ name: String, _ value: Double, _ format: String = "%.2f") {
        print("PERF \(name) " + String(format: format, value))
    }
    private var typeable: Bool {
        (keyboard.exists || app.buttons["terminalKey-hideKeyboard"].exists) && lastLine().hasSuffix("~$")
    }
    /// Round 17: the DEBUG stand-in for the software keyboard, on a simulator
    /// that has a hardware keyboard.
    private var standInKeyboard = false

    /// The system's offer to save the password, wherever iOS puts it.
    private var passwordOffer: XCUIElement? {
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"],
                          app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Save Password")).firstMatch,
                          springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Save Password")).firstMatch]
        where candidate.exists { return candidate }
        return nil
    }
    private var offersSeen = 0

    /// Polls until `condition` holds; returns the seconds it took, or nil.
    /// Counts (and declines, never accepts) any Save Password offer meanwhile.
    private func until(_ timeout: TimeInterval, poll: TimeInterval = 0.05, _ condition: () -> Bool) -> Double? {
        let start = now()
        while now() - start < timeout {
            if condition() { return now() - start }
            noteOffer()
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        return condition() ? now() - start : nil
    }

    private func noteOffer() {
        guard passwordOffer != nil else { return }
        offersSeen += 1
        shot("offer-\(offersSeen)")
        for button in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where button.exists {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func launch(snippets: [(String, String)] = []) {
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
        // Round 15's renderer trial (DEBUG builds): `WITERM_RENDERER=metal`,
        // and `WITERM_METAL_RAW=1` for SwiftTerm's renderer without Witerm's fixes.
        let environment = ProcessInfo.processInfo.environment
        if let renderer = environment["WITERM_RENDERER"] { app.launchArguments += ["-witerm.debug.renderer", renderer] }
        if environment["WITERM_METAL_RAW"] == "1" { app.launchArguments += ["-witerm.debug.metalRaw", "YES"] }
        if standInKeyboard { app.launchArguments += ["-witerm.debug.softwareKeyboard", "YES"] }
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        // Leftovers of an interrupted run of these tests, by their unique prefix.
        if let fingerprint = ProcessInfo.processInfo.environment["WITERM_SSH_UI_FINGERPRINT"] {
            let leftovers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label MATCHES %@", "sshProfileRow-", "R1[3-7] .*"))
            for _ in 0..<5 where leftovers.firstMatch.exists { removeHost(named: leftovers.firstMatch.label, fingerprint: fingerprint) }
        }
    }

    private func fixture() throws -> (port: String, fingerprint: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        return (port, fingerprint)
    }

    /// Fills the form for a new fixture host: the address, a unique name, and
    /// the password, part typed and part pasted when `paste` is set.
    private func fillForm(port: String, name: String, paste: Bool) {
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
        password.tap()
        guard paste else { password.typeText("witerm-fixture-only"); return }
        password.typeText("witerm-")
        UIPasteboard.general.string = "fixture-only"
        // A tap on the focused field shows its edit menu with Paste.
        var pasted = false
        for attempt in 0..<4 where !pasted {
            if attempt % 2 == 0 { password.tap() } else { password.press(forDuration: 1.0) }
            for item in [app.menuItems["Paste"], app.buttons["Paste"]] where item.waitForExistence(timeout: 2) {
                item.tap(); pasted = true; break
            }
        }
        XCTAssertTrue(pasted, "The password field must offer Paste")
        // A secure field reads back as one dot per character.
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "^.{19}$"), object: password)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 5), .completed,
                       "Typed and pasted text must both reach the password field (\(String(describing: password.value)))")
    }

    /// Approves the fixture's key and waits for a terminal to type in.
    private func trustAndWait(fingerprint: String) {
        let identity = app.staticTexts["sshHostFingerprint"]
        XCTAssertNotNil(until(20) { identity.exists }, "The fixture's key must be reviewed first")
        XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
        let trust = app.buttons["sshTrustHost"]
        XCTAssertNotNil(until(10) { trust.isHittable && passwordOffer == nil })
        trust.tap()
        XCTAssertNotNil(until(20) { typeable }, "The connection never became typeable")
    }

    /// Removes a host this test made, and its pin only when it's the fixture's.
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
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        app.buttons["Done"].tap()
        actions.tap()
        app.buttons["Delete Host"].tap()
        let dismiss = app.buttons["sshUndoDismiss"]
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
        XCTAssertFalse(row.waitForExistence(timeout: 2), "The test's host must be gone")
    }

    private func disconnectAndRemove(_ name: String, fingerprint: String) {
        if !app.buttons["sshSessionActions"].isHittable, keyboard.exists { app.buttons["terminalKey-hideKeyboard"].tap() }
        XCTAssertNotNil(until(5) { app.buttons["sshSessionActions"].isHittable })
        app.buttons["sshSessionActions"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 5))
        app.buttons["sshShowHosts"].tap()
        removeHost(named: name, fingerprint: fingerprint)
    }

    // MARK: Grid

    /// The newest `rows columns` line the fixture's `stty size` printed.
    private func grid() -> (rows: Int, columns: Int)? {
        text().split(whereSeparator: \.isNewline).reversed().lazy.compactMap { line -> (Int, Int)? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 2, let rows = Int(parts[0]), let columns = Int(parts[1]) else { return nil }
            return (rows, columns)
        }.first
    }

    /// The renderer's own grid, from the layout probe.
    private func probedGrid() -> String { "\(Int(probe("cols") ?? -1))x\(Int(probe("rows") ?? -1))" }

    /// Runs the "Grid size" snippet (`stty size`) from the key row and
    /// returns what the host says its window is.
    private func stty() -> (rows: Int, columns: Int)? {
        runSnippet("Grid size")
        let marker = probe("rows")
        _ = until(5) { grid() != nil && lastLine().hasSuffix("~$") && probe("rows") == marker }
        return grid()
    }

    /// Runs a saved snippet from the key row's Snippets key.
    private func runSnippet(_ name: String) {
        // The DEBUG stand-in isn't a system keyboard: its key row says it's up.
        let up = { [self] in keyboard.exists || (standInKeyboard && app.buttons["terminalKey-hideKeyboard"].isHittable) }
        if until(1.5, up) == nil { app.toggleTerminalKeyboard() }
        XCTAssertNotNil(until(5, up), "The keyboard isn't up")
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

    // MARK: Save Password

    func testConnectingDoesNotOfferToSaveThePassword() throws {
        continueAfterFailure = true
        executionTimeAllowance = 240
        let (port, fingerprint) = try fixture()
        launch()
        let name = "R13 Pwd " + String(UUID().uuidString.prefix(4))
        fillForm(port: port, name: name, paste: true)
        shot("password-form-filled")
        app.buttons["sshConnect"].tap()
        trustAndWait(fingerprint: fingerprint)
        // The offer, when iOS makes it, comes within a few seconds of the form closing.
        _ = until(6) { false }
        shot("password-connected")
        let first = offersSeen
        report("save_password_offers_after_new_host", Double(first), "%.0f")

        // Reconnecting through the form again (the credential wasn't saved).
        app.buttons["sshSessionActions"].tap()
        app.buttons["Disconnect"].tap()
        let reconnect = app.buttons["sshReconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        let password = app.secureTextFields["sshHostPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap(); password.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].tap()
        XCTAssertNotNil(until(20) { typeable }, "The reconnection never became typeable")
        _ = until(6) { false }
        let second = offersSeen
        report("save_password_offers_after_reconnect", Double(second - first), "%.0f")

        // Typing a password, then leaving the form with Cancel or a swipe down.
        app.buttons["sshSessionActions"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        for leave in ["cancel", "swipe"] {
            reconnect.tap()
            XCTAssertTrue(password.waitForExistence(timeout: 5))
            password.tap(); password.typeText("witerm-fixture-only")
            if leave == "cancel" {
                app.buttons["Cancel"].tap()
            } else {
                let sheet = app.navigationBars.firstMatch
                sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            }
            XCTAssertNotNil(until(5) { !password.exists }, "The form must close (\(leave))")
            _ = until(5) { false }
        }
        report("save_password_offers_after_cancel_or_swipe", Double(offersSeen - second), "%.0f")
        if !baseline { XCTAssertEqual(offersSeen, 0, "iOS must not offer to save the SSH password") }

        app.buttons["sshShowHosts"].tap()
        removeHost(named: name, fingerprint: fingerprint)
    }

    // MARK: Landscape typing

    func testLandscapeTypingGivesTheTerminalTheBarsRows() throws {
        continueAfterFailure = false
        executionTimeAllowance = 400
        let (port, fingerprint) = try fixture()
        launch(snippets: [("Grid size", "stty size")])
        let name = "R13 Land " + String(UUID().uuidString.prefix(4))
        fillForm(port: port, name: name, paste: false)
        app.buttons["sshConnect"].tap()
        trustAndWait(fingerprint: fingerprint)
        _ = until(3) { false }

        let actions = app.buttons["sshSessionActions"]
        let hideKey = app.buttons["terminalKey-hideKeyboard"]
        let actionsKey = app.buttons["terminalKey-actions"]

        // Portrait, keyboard up: the bar stays, as before.
        let portrait = try XCTUnwrap(stty())
        XCTAssertTrue(actions.isHittable, "Portrait keeps the navigation bar while typing")
        XCTAssertTrue(hideKey.isHittable, "Hide Keyboard ends the key row in portrait too (Round 16)")
        XCTAssertFalse(app.buttons["sshKeyboard"].exists, "The keyboard button shows only while the keyboard is hidden")
        shot("portrait-keyboard-up")

        // Landscape, keyboard up.
        XCUIDevice.shared.orientation = .landscapeLeft
        report("rotate_landscape_s", until(5) { terminal.frame.width > terminal.frame.height } ?? -1)
        let landscape = try XCTUnwrap(stty())
        print("PERF grid portrait_kb=\(portrait.columns)x\(portrait.rows) landscape_kb=\(landscape.columns)x\(landscape.rows)")
        shot("landscape-keyboard-up")
        if !baseline {
            XCTAssertFalse(actions.isHittable, "In landscape the bar hides while typing")
            XCTAssertTrue(hideKey.isHittable, "The key row offers Hide Keyboard while the bar is hidden")
            XCTAssertTrue(actionsKey.isHittable, "The key row offers the terminal's actions while the bar is hidden")
            XCTAssertGreaterThan(landscape.rows, 5, "Hiding the bar gives the terminal rows")
            // The actions menu from the key row has what the bar's had.
            actionsKey.tap()
            for item in ["SFTP Files", "Port Forwarding", "Increase Text Size", "Find in Terminal", "Disconnect"] {
                // In landscape the menu opens upward from the key row, so its
                // items run bottom to top and the last ones (Port Forwarding,
                // Disconnect) start scrolled out of view above Find, where
                // XCUITest doesn't list them. Drag the menu down from its top
                // visible item, slowly so it scrolls rather than closes.
                for _ in 0..<3 where !app.buttons[item].waitForExistence(timeout: 2) {
                    let top = ["SFTP Files", "Find in Terminal"].map { app.buttons[$0] }.first { $0.exists && $0.isHittable }
                    guard let top else { break }
                    let from = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 160)), withVelocity: .slow,
                               thenHoldForDuration: 0.2)
                }
                if !app.buttons[item].waitForExistence(timeout: 3) {
                    print("PROBE menu buttons: " + app.buttons.allElementsBoundByIndex.map {
                        "\($0.identifier)|\($0.label)|\(Int($0.frame.minY))|\($0.isHittable)" }.joined(separator: ", "))
                    shot("landscape-actions-menu-missing")
                }
                XCTAssertTrue(app.buttons[item].exists, item)
            }
            shot("landscape-actions-menu")
            // Text size works from it like from the bar's menu: the cell grows,
            // then shrinks back (the size is kept, so the test restores it).
            func sizeItem(_ id: String, _ label: String) -> XCUIElement {
                app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, label)).firstMatch
            }
            func closeMenu() {
                if app.buttons["SFTP Files"].exists || sizeItem("terminalSmallerText", "Decrease Text Size").exists {
                    terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
                }
                XCTAssertNotNil(until(5) { !app.buttons["SFTP Files"].exists && !sizeItem("terminalSmallerText", "Decrease Text Size").exists })
            }
            let cell = probe("cell") ?? 0
            app.openTextAndColors()
            sizeItem("terminalLargerText", "Increase Text Size").tap()
            let larger = until(5) { (probe("cell") ?? 0) > cell }
            closeMenu()
            actionsKey.tap()
            app.openTextAndColors()
            XCTAssertTrue(sizeItem("terminalSmallerText", "Decrease Text Size").waitForExistence(timeout: 5))
            sizeItem("terminalSmallerText", "Decrease Text Size").tap()
            let restored = until(5) { abs((probe("cell") ?? 0) - cell) < 0.01 }
            closeMenu()
            XCTAssertNotNil(larger, "Larger text from the key row's menu must apply")
            XCTAssertNotNil(restored, "Smaller text from the key row's menu must apply")
            XCTAssertTrue(keyboard.exists, "Using the key row's menu keeps the keyboard up")
        }

        // Hide and show, five times: how long, how many grids on the way, and
        // how far apart the first and last of them were (the probe logs each
        // grid with the milliseconds since the one before).
        // Since Round 14 the frame right after rotating is already the one
        // each later show lands on (before, the key row's inset arrived only
        // with the next show).
        let rotatedFrame = terminal.frame
        var upFrame = CGRect.zero, downFrame = CGRect.zero
        var shows: [Double] = [], hides: [Double] = []
        var showSteps: [Int] = [], hideSteps: [Int] = [], showSpans: [Int] = [], hideSpans: [Int] = []
        /// Grid changes since `before`, and the milliseconds from the first to the last.
        func steps(since before: Double) -> (count: Int, span: Int) {
            let count = Int((probe("grids") ?? 0) - before)
            let log = (terminal.label.components(separatedBy: "gridlog=").last ?? "").split(separator: ">")
            let gaps = log.suffix(max(0, count)).dropFirst().compactMap { Int($0.split(separator: "+").last ?? "") }
            print("PROBE gridlog=\(log.joined(separator: ">")) events=\(terminal.label.components(separatedBy: " events=").last?.components(separatedBy: " gridlog=").first ?? "")")
            return (count, gaps.reduce(0, +))
        }
        for index in 0..<5 {
            var changes = probe("grids") ?? 0
            if baseline { app.toggleTerminalKeyboard() } else { XCTAssertTrue(hideKey.isHittable); hideKey.tap() }
            hides.append(until(5) { !keyboard.exists && (baseline || terminal.frame.minY > 40) } ?? 99)
            _ = until(1) { false }
            let hide = steps(since: changes)
            hideSteps.append(hide.count); hideSpans.append(hide.span)
            if index == 0 {
                downFrame = terminal.frame
                print("PERF grid landscape_no_kb=\(probedGrid()) frame=\(downFrame)")
                shot("landscape-keyboard-down")
            } else {
                XCTAssertEqual(terminal.frame, downFrame, "Hiding the keyboard must restore the same frame")
            }
            XCTAssertTrue(actions.isHittable, "The bar is back once the keyboard is hidden")
            changes = probe("grids") ?? 0
            app.toggleTerminalKeyboard()
            // The terminal at the top of the screen says the bar is gone; the
            // bar's buttons stay hittable to XCTest for a while after.
            shows.append(until(5) { typeable && (baseline || (terminal.frame.minY < 10 && hideKey.exists)) } ?? 99)
            _ = until(1) { false }
            let show = steps(since: changes)
            showSteps.append(show.count); showSpans.append(show.span)
            if index == 0 {
                upFrame = terminal.frame
                print("PERF grid landscape_kb=\(probedGrid()) frame=\(upFrame) after_rotation_frame=\(rotatedFrame)")
                shot("landscape-keyboard-again")
                if !baseline { XCTAssertEqual(rotatedFrame, upFrame, "Rotating must already give the frame a show gives") }
            } else {
                XCTAssertEqual(terminal.frame, upFrame, "Showing the keyboard must land on the same frame")
            }
        }
        print("PERF landscape_keyboard_show_s " + shows.map { String(format: "%.2f", $0) }.joined(separator: ","))
        print("PERF landscape_keyboard_hide_s " + hides.map { String(format: "%.2f", $0) }.joined(separator: ","))
        print("PERF landscape_keyboard_show_grids \(showSteps) span_ms \(showSpans)")
        print("PERF landscape_keyboard_hide_grids \(hideSteps) span_ms \(hideSpans)")
        // At most the bar and the key row's inset, close enough together that
        // the host is resized once (SSH waits 75 ms for the size to settle).
        XCTAssertLessThanOrEqual(showSteps.max() ?? 0, 2, "Showing the keyboard must not step through grids")
        // Before Round 14 the first hide also applied the key row's inset that
        // rotating had left out, so the baseline skips it.
        let checkedHides = baseline ? Array(hideSteps.dropFirst()) : hideSteps
        let checkedHideSpans = baseline ? Array(hideSpans.dropFirst()) : hideSpans
        XCTAssertLessThanOrEqual(checkedHides.max() ?? 0, 2, "Hiding the keyboard must not step through grids")
        XCTAssertLessThan(showSpans.max() ?? 0, 75, "The grids on the way must come within one resize")
        XCTAssertLessThan(checkedHideSpans.max() ?? 0, 75, "The grids on the way must come within one resize")

        // Back to portrait with the keyboard up: the bar returns.
        XCUIDevice.shared.orientation = .portrait
        _ = until(5) { terminal.frame.width < terminal.frame.height }
        XCTAssertNotNil(until(5) { actions.isHittable }, "Portrait brings the bar back")
        let again = try XCTUnwrap(stty())
        shot("portrait-keyboard-again")
        print("PERF grid portrait_again_kb=\(again.columns)x\(again.rows) frame=\(terminal.frame) \(terminal.label)")
        XCTAssertEqual(again.columns, portrait.columns, "Portrait restores the columns")
        // Before Round 14, with only the key row up (a hardware keyboard),
        // coming back to portrait left the terminal 13 rows tall until the
        // keyboard was next hidden or shown (see the HCI log, Round 14: iOS).
        if !baseline { XCTAssertEqual(again.rows, portrait.rows, "Portrait restores the rows") }
        XCTAssertTrue(hideKey.exists, "Hide Keyboard stays on the key row in portrait")

        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    // MARK: Round 14: layout

    /// Connects a new fixture host whose snippet prints the host's window size.
    private func connectForGrid(_ prefix: String, more: [(String, String)] = []) throws -> (name: String, fingerprint: String) {
        let (port, fingerprint) = try fixture()
        launch(snippets: [("Grid size", "stty size")] + more)
        let name = prefix + " " + String(UUID().uuidString.prefix(4))
        fillForm(port: port, name: name, paste: false)
        app.buttons["sshConnect"].tap()
        trustAndWait(fingerprint: fingerprint)
        _ = until(3) { false }
        return (name, fingerprint)
    }

    /// How far the terminal's text area ends below the top of the first key:
    /// more than usual when rows run under the key row, less for a gap above
    /// it. (The key sits 4 pt inside the row, so a text area that ends on the
    /// row reads -4.)
    private func underKeyRow() -> Double {
        let row = app.buttons["terminalKey-escape"]
        guard row.exists else { return .nan }
        return Double(terminal.frame.maxY - row.frame.minY)
    }

    /// The diagnostics the layout probe adds about the keyboard.
    private func keyboardDiagnostics() -> String {
        guard let range = terminal.label.range(of: "kbdiag=[") else { return "" }
        return String(terminal.label[range.upperBound...].prefix { $0 != "]" })
    }

    /// Rotating with the key row up (a hardware keyboard) gives each
    /// orientation the grid it has after the keyboard is hidden and shown
    /// again there: the terminal never runs under the key row nor leaves the
    /// rest of the screen empty, and the host is told the same size.
    func testRotationWithTheKeyRowUpFitsEachOrientation() throws {
        continueAfterFailure = true
        executionTimeAllowance = 400
        let (name, fingerprint) = try connectForGrid("R14 Rot")
        let hideKey = app.buttons["terminalKey-hideKeyboard"]

        // Portrait: the key row up, then down, then up again.
        let portrait = try XCTUnwrap(stty())
        let portraitGrid = probedGrid()
        let portraitReferenceUnder = underKeyRow()
        report("r14_portrait_kb_under_key_row_pt", portraitReferenceUnder)
        shot("r14-rotation-1-portrait-keyrow")
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { !keyboard.exists })
        _ = until(1) { false }
        let portraitDown = probedGrid()
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { typeable })
        _ = until(1) { false }
        XCTAssertEqual(probedGrid(), portraitGrid, "Showing the key row again gives the same grid")
        print("PERF r14 portrait_kb=\(portrait.columns)x\(portrait.rows) probe=\(portraitGrid) portrait_no_kb=\(portraitDown)")

        // Landscape with the key row up, before any hide or show there.
        var changes = probe("grids") ?? 0
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = until(5) { terminal.frame.width > terminal.frame.height }
        report("r14_rotate_landscape_s", rotated ?? -1)
        _ = until(1.5) { false }
        let landscapeGrid = probedGrid()
        let landscapeUnder = underKeyRow()
        let landscapeSteps = Int((probe("grids") ?? 0) - changes)
        print("PERF r14 landscape_after_rotation=\(landscapeGrid) under_key_row_pt=\(landscapeUnder) grid_changes=\(landscapeSteps) kbdiag=\(keyboardDiagnostics())")
        print("PROBE gridlog=\(terminal.label.components(separatedBy: "gridlog=").last ?? "")")
        shot("r14-rotation-2-landscape-keyrow")
        let landscape = try XCTUnwrap(stty())
        XCTAssertEqual("\(landscape.columns)x\(landscape.rows)", landscapeGrid, "The host has the landscape grid")
        // The reference: the same orientation after the key row hides and shows.
        XCTAssertTrue(hideKey.waitForExistence(timeout: 5))
        hideKey.tap()
        XCTAssertNotNil(until(5) { !keyboard.exists })
        _ = until(1) { false }
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { typeable && hideKey.exists })
        _ = until(1) { false }
        let landscapeReference = probedGrid()
        let landscapeReferenceUnder = underKeyRow()
        print("PERF r14 landscape_reference=\(landscapeReference) under_key_row_pt=\(landscapeReferenceUnder)")
        XCTAssertEqual(landscapeGrid, landscapeReference, "Rotating must give landscape the grid it has after the key row hides and shows")
        XCTAssertEqual(landscapeUnder, landscapeReferenceUnder, accuracy: 1, "After rotating, the terminal must end on the key row, not run under it")
        XCTAssertLessThanOrEqual(landscapeSteps, 3, "Rotating must not step through grids")

        // Back to portrait with the key row up.
        changes = probe("grids") ?? 0
        XCUIDevice.shared.orientation = .portrait
        let back = until(5) { terminal.frame.width < terminal.frame.height && probedGrid() == portraitGrid }
        report("r14_rotate_portrait_to_full_grid_s", back ?? -1)
        _ = until(1.5) { false }
        let portraitAgainGrid = probedGrid()
        let portraitUnder = underKeyRow()
        let portraitSteps = Int((probe("grids") ?? 0) - changes)
        print("PERF r14 portrait_after_rotation=\(portraitAgainGrid) under_key_row_pt=\(portraitUnder) grid_changes=\(portraitSteps) kbdiag=\(keyboardDiagnostics())")
        print("PROBE gridlog=\(terminal.label.components(separatedBy: "gridlog=").last ?? "")")
        shot("r14-rotation-3-portrait-again-keyrow")
        let again = try XCTUnwrap(stty())
        print("PERF r14 portrait_again_host=\(again.columns)x\(again.rows)")
        XCTAssertEqual(portraitAgainGrid, portraitGrid, "Back in portrait, the key row-up grid is the full portrait one")
        XCTAssertEqual(again.rows, portrait.rows, "The host gets the portrait rows back")
        XCTAssertEqual(again.columns, portrait.columns)
        XCTAssertEqual(portraitUnder, portraitReferenceUnder, accuracy: 1, "Back in portrait, the terminal must end on the key row, with no empty band")
        XCTAssertLessThanOrEqual(portraitSteps, 3, "Rotating must not step through grids")

        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    /// Larger and Smaller text from the actions menu reflow the grid at once
    /// to whole cells of the new size, and the host is told that size.
    /// Round 17, with the software keyboard (or its DEBUG stand-in with
    /// `WITERM_SOFT_KEYBOARD=1` where the simulator has a hardware keyboard):
    /// hiding it gives every row back, with the key and with a swipe down on
    /// the key row, and the host is told; nothing blank stays where the
    /// keyboard was. A drag from the text into the keyboard (interactive
    /// dismissal) is tried and reported, not required.
    func testHidingTheSoftwareKeyboardGivesEveryRowBack() throws {
        continueAfterFailure = true
        standInKeyboard = ProcessInfo.processInfo.environment["WITERM_SOFT_KEYBOARD"] == "1"
        let (name, fingerprint) = try connectForGrid("R17 Soft")
        let hide = app.buttons["terminalKey-hideKeyboard"]
        XCTAssertNotNil(until(5) { hide.isHittable })
        _ = until(1) { false }
        let up = Int(probe("rows") ?? -1)
        print("PROBE r17 ssh keyboard up rows=\(up) label=\(keyboardDiagnostics())")
        shot("r17-ssh-1-keyboard-up")
        func assertRowsBack(_ step: String) {
            XCTAssertNotNil(until(5) { Int(probe("rows") ?? -1) > up + 10 }, "\(step): the rows didn't come back (\(probedGrid()))")
            _ = until(1) { false }
            let gap = probe("gap") ?? -1, cell = probe("cell") ?? 0
            print("PROBE r17 ssh \(step) grid=\(probedGrid()) gap=\(gap) overflow=\(probe("overflow") ?? -1) \(keyboardDiagnostics())")
            XCTAssertLessThan(gap, cell, "\(step): \(gap) pt blank under the grid")
            XCTAssertLessThan(probe("overflow") ?? 99, 1, "\(step): rows under the keyboard button")
        }
        hide.tap()
        assertRowsBack("hide key")
        shot("r17-ssh-2-hidden")
        let full = probedGrid()
        // Up again, then a drag from the text into the keyboard.
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { hide.isHittable && Int(probe("rows") ?? -1) == up }, "Keyboard up again: \(probedGrid())")
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 520)), withVelocity: .slow,
                    thenHoldForDuration: 0.1)
        let dismissed = until(3) { Int(probe("rows") ?? -1) > up + 10 } != nil
        print("PROBE r17 ssh drag from text dismissed=\(dismissed) grid=\(probedGrid())")
        if !dismissed {
            // A swipe down on the key row.
            let escape = app.buttons["terminalKey-escape"]
            let key = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            key.press(forDuration: 0.02, thenDragTo: key.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: .fast, thenHoldForDuration: 0)
        }
        assertRowsBack("swipe down")
        XCTAssertEqual(probedGrid(), full, "The same rows as with the key")
        shot("r17-ssh-3-swiped-down")
        let host = stty()
        XCTAssertEqual(host.map { "\($0.columns)x\($0.rows)" }, up > 0 ? probedGrid() : nil, "The host's size")
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    /// Round 18: with the keyboard down the terminal uses the full height.
    /// The keyboard button floats over the text instead of reserving a
    /// 60 pt strip under it (the owner's "obstruction at the bottom"), in
    /// portrait and landscape; the host is told the larger size.
    func testTheTerminalUsesTheFullHeightWithTheKeyboardDown() throws {
        continueAfterFailure = true
        let (name, fingerprint) = try connectForGrid("R18 Band")
        func band(_ step: String) {
            _ = until(1.5) { false }
            let label = terminal.label
            func value(_ key: String) -> Double? {
                guard let range = label.range(of: key) else { return nil }
                return Double(label[range.upperBound...].prefix { $0.isNumber || $0 == "." })
            }
            let surface = label.range(of: " surface=").map { label[$0.upperBound...].prefix { !$0.isWhitespace && $0 != "]" } }
            let height = surface.flatMap { Double($0.split(separator: ",").last ?? "") } ?? -1
            let overlap = value("kbdiag=[overlap=") ?? -1, grid = value(" frameH=") ?? -1
            let shown = value(" boundsH=") ?? -1, cell = value(" cell=") ?? 0
            let measured = height - overlap - min(grid, shown)
            print("PROBE r18 ssh band \(step): band=\(String(format: "%.1f", measured)) cell=\(cell) grid=\(probedGrid()) overlap=\(overlap)")
            XCTAssertLessThan(measured, cell, "\(step): \(measured) pt at the bottom with no text (a band)")
        }
        band("keyboard up, portrait")
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { !app.buttons["terminalKey-hideKeyboard"].exists })
        band("keyboard down, portrait")
        shot("r18-ssh-1-keyboard-down")
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = until(1.5) { false }
        band("keyboard down, landscape")
        shot("r18-ssh-2-keyboard-down-landscape")
        XCUIDevice.shared.orientation = .portrait
        _ = until(1.5) { false }
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    /// Round 17: returning within 3 minutes continues the same SSH
    /// connection and shell (the same `$$`), with nothing to reconnect.
    /// Away times from `WITERM_BG_SECONDS` (default 10 and 60). Prints
    /// `PROBE b5 ssh` lines with the time until the terminal can type.
    func testReturningWithinThreeMinutesKeepsTheSameShell() throws {
        continueAfterFailure = true
        executionTimeAllowance = 900
        let (name, fingerprint) = try connectForGrid("R17 Back", more: [("Shell", "echo shell-$$")])
        func shell() -> String? {
            runSnippet("Shell")
            _ = until(5) { text().contains("shell-") && lastLine().hasSuffix("~$") }
            return text().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("shell-") }
        }
        let first = shell()
        XCTAssertNotNil(first, "No shell id")
        let times = (ProcessInfo.processInfo.environment["WITERM_BG_SECONDS"] ?? "10,60").split(separator: ",").compactMap { Double($0) }
        for seconds in times {
            XCUIDevice.shared.press(.home)
            _ = until(seconds) { false }
            app.activate()
            let back = now()
            let usable = until(15) { typeable && app.buttons["sshSessionActions"].exists }
            let reconnect = app.buttons["sshReconnect"].exists
            print("PROBE b5 ssh away=\(Int(seconds)) usable=\(usable.map { String(format: "%.2f", $0) } ?? "never") reconnectShown=\(reconnect) since=\(String(format: "%.2f", now() - back))")
            shot("r17-ssh-back-\(Int(seconds))s")
            XCTAssertNotNil(usable, "Not typeable after \(seconds) s away")
            XCTAssertFalse(reconnect, "Reconnect showed after \(seconds) s away")
            XCTAssertEqual(shell(), first, "Not the same shell after \(seconds) s away")
        }
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    func testTextSizeReflowsTheGridAndResizesTheHost() throws {
        continueAfterFailure = true
        executionTimeAllowance = 300
        let (name, fingerprint) = try connectForGrid("R14 Size")
        let actions = app.buttons["sshSessionActions"]
        func sizeItem(_ id: String, _ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, label)).firstMatch
        }
        func closeMenu() {
            if sizeItem("terminalLargerText", "Increase Text Size").exists {
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            }
            XCTAssertNotNil(until(5) { !sizeItem("terminalLargerText", "Increase Text Size").exists })
        }
        /// Rows that fit the text area in whole cells of the probed height.
        func fittingRows() -> Int {
            let cell = probe("cell") ?? 0
            return cell > 0 ? Int((Double(terminal.frame.height) / cell) * (1 + 1e-9)) : -1
        }
        /// Taps a size step and returns how long the grid took to change.
        func step(_ id: String, _ label: String, from grid: String) -> Double? {
            XCTAssertNotNil(until(5) { actions.isHittable })
            actions.tap()
            app.openTextAndColors()
            let item = sizeItem(id, label)
            XCTAssertTrue(item.waitForExistence(timeout: 5), label)
            let cell = probe("cell") ?? 0
            item.tap()
            let changed = until(5, poll: 0.02) { probedGrid() != grid }
            report("r14_text_size_cell_changed", (probe("cell") ?? 0) - cell)
            closeMenu()
            return changed
        }

        let before = try XCTUnwrap(stty())
        let beforeGrid = probedGrid()
        XCTAssertEqual("\(before.columns)x\(before.rows)", beforeGrid, "The host starts with the renderer's grid")
        shot("r14-text-size-1-before")

        // Larger.
        let larger = step("terminalLargerText", "Increase Text Size", from: beforeGrid)
        report("r14_text_size_larger_reflow_s", larger ?? -1)
        _ = until(1) { false }
        let largerGrid = probedGrid()
        print("PERF r14 text_size before=\(beforeGrid) larger=\(largerGrid) fitting_rows=\(fittingRows()) label=\(terminal.label)")
        shot("r14-text-size-2-larger")
        XCTAssertNotNil(larger, "Larger text must reflow the grid")
        XCTAssertLessThan(larger ?? 99, 1, "The grid must reflow within a second")
        XCTAssertEqual(Int(probe("rows") ?? -1), fittingRows(), "The rows are the whole cells that fit")
        let largerHost = try XCTUnwrap(stty())
        XCTAssertEqual("\(largerHost.columns)x\(largerHost.rows)", largerGrid, "The host must see the new size")
        XCTAssertLessThan(largerHost.columns, before.columns)

        // Smaller, back to where it was (the size is kept, so this restores it).
        let smaller = step("terminalSmallerText", "Decrease Text Size", from: largerGrid)
        report("r14_text_size_smaller_reflow_s", smaller ?? -1)
        _ = until(1) { false }
        shot("r14-text-size-3-restored")
        XCTAssertNotNil(smaller, "Smaller text must reflow the grid")
        XCTAssertLessThan(smaller ?? 99, 1, "The grid must reflow within a second")
        XCTAssertEqual(probedGrid(), beforeGrid, "The original size gives the original grid")
        let restoredHost = try XCTUnwrap(stty())
        XCTAssertEqual("\(restoredHost.columns)x\(restoredHost.rows)", beforeGrid, "The host must see the original size again")

        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    // MARK: Round 14: smoothness

    /// The probe's last motion: frames, hitches, drawing and layout from the
    /// first movement of a scroll or pinch until 0.4 s after the last.
    private func motion() -> [String: Double] {
        guard let part = terminal.label.components(separatedBy: " motion=").last?.components(separatedBy: " ").first else { return [:] }
        var values: [String: Double] = [:]
        for pair in part.split(separator: ",") {
            let kv = pair.split(separator: ":")
            if kv.count == 2, let value = Double(kv[1]) { values[String(kv[0])] = value }
        }
        return values
    }

    private func motionLine() -> String {
        terminal.label.components(separatedBy: " motion=").last?.components(separatedBy: " events=").first ?? ""
    }

    /// Waits for a motion that differs from `before` to be reported.
    /// Every XCTest query snapshots the app's accessibility on its main
    /// thread, which itself costs frames, so this waits without querying
    /// until the motion (and a fling's coast) is over, then reads once.
    private func nextMotion(after before: [String: Double], quiet: TimeInterval = 4) -> [String: Double] {
        RunLoop.current.run(until: Date().addingTimeInterval(quiet))
        var latest = motion()
        for _ in 0..<5 where latest == before || latest.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            latest = motion()
        }
        return latest
    }

    /// Scrolling through `seq 1 100000` and through live output, and a pinch:
    /// frame pacing from the app's own display-link probe, the main thread's
    /// drawing and layout per frame, and how long a pinch takes to settle on
    /// its new font and grid (with the host told that grid).
    func testScrollingAndPinchStaySmooth() throws {
        continueAfterFailure = true
        executionTimeAllowance = 600
        let (name, fingerprint) = try connectForGrid("R14 Smooth", more: [("Hundred thousand", "seq 1 100000"),
                                                                         ("Three million", "seq 1 3000000")])
        runSnippet("Hundred thousand")
        XCTAssertNotNil(until(60, poll: 1) { text().contains("100000") && lastLine().hasSuffix("~$") }, "seq 1 100000 must finish")
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { !keyboard.exists })
        _ = until(1) { false }

        // Flings back through the scrollback.
        var worst = 0.0, hitches = 0.0, frames = 0.0, draws = 0.0, drawMs = 0.0, drawWorst = 0.0, readings = 0.0, layouts = 0.0
        for index in 0..<3 {
            let before = motion()
            terminal.swipeDown(velocity: .fast)
            let m = nextMotion(after: before)
            print("PERF r14 scroll_fling_\(index) \(motionLine())")
            worst = max(worst, m["worstms"] ?? 0); hitches += m["hitches"] ?? 0; frames += m["frames"] ?? 0
            draws += m["draws"] ?? 0; drawMs += (m["drawms"] ?? 0) * (m["draws"] ?? 0); drawWorst = max(drawWorst, m["drawworstms"] ?? 0)
            readings += m["readings"] ?? 0; layouts += m["layouts"] ?? 0
        }
        report("r14_scroll_frames", frames, "%.0f")
        report("r14_scroll_hitches", hitches, "%.0f")
        report("r14_scroll_worst_frame_ms", worst)
        report("r14_scroll_draw_mean_ms", draws > 0 ? drawMs / draws : 0)
        report("r14_scroll_draw_worst_ms", drawWorst)
        report("r14_scroll_draws_per_frame", frames > 0 ? draws / frames : 0)
        report("r14_scroll_readings_per_frame", frames > 0 ? readings / frames : 0)
        report("r14_scroll_layouts_per_frame", frames > 0 ? layouts / frames : 0)
        XCTAssertGreaterThan(frames, 0, "The probe must have seen the scroll")
        XCTAssertLessThan(readings / max(1, frames), 0.1, "A touch scroll must not rebuild the reading page every frame")
        shot("r14-smooth-1-scrolled-back")
        report("r15_memory_after_100k_mb", probe("mem") ?? -1, "%.1f")
        let latest = app.buttons["terminalJumpToLatest"]
        if latest.waitForExistence(timeout: 3) { latest.tap() }
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$") })

        // A drag through live output (three million lines stream for several seconds).
        runSnippet("Three million")
        _ = until(1.5) { false }
        let beforeLive = motion()
        terminal.swipeDown(velocity: .slow)
        let live = nextMotion(after: beforeLive)
        print("PERF r14 scroll_live \(motionLine())")
        report("r14_live_scroll_hitches", live["hitches"] ?? -1, "%.0f")
        report("r14_live_scroll_worst_frame_ms", live["worstms"] ?? -1)
        report("r14_live_scroll_draw_mean_ms", live["drawms"] ?? -1)
        shot("r14-smooth-2-live-output")
        if !keyboard.exists { app.toggleTerminalKeyboard() }
        let interrupt = app.buttons["terminalInterrupt"]
        if interrupt.waitForExistence(timeout: 5) { interrupt.tap() }
        XCTAssertNotNil(until(30, poll: 1) { lastLine().hasSuffix("~$") }, "Ctrl+C must stop the output")
        if latest.exists { latest.tap() }
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { !keyboard.exists })
        _ = until(1) { false }

        // A pinch: live scaling, then one font, one grid and one resize.
        let cell = probe("cell") ?? 0
        let gridBefore = probedGrid()
        let beforePinch = motion()
        terminal.pinch(withScale: 1.5, velocity: 1.5)
        let pinch = nextMotion(after: beforePinch)
        _ = until(1) { false }
        let settle = terminal.label.components(separatedBy: " settle=").last?.components(separatedBy: " ").first ?? ""
        print("PERF r14 pinch \(motionLine()) grid \(gridBefore) -> \(probedGrid()) cell \(cell) -> \(probe("cell") ?? 0)")
        report("r14_pinch_steps", pinch["pinchsteps"] ?? -1, "%.0f")
        report("r14_pinch_step_worst_ms", pinch["pinchstepworstms"] ?? -1)
        report("r14_pinch_layouts", pinch["layouts"] ?? -1, "%.0f")
        report("r14_pinch_readings", pinch["readings"] ?? -1, "%.0f")
        report("r14_pinch_hitches", pinch["hitches"] ?? -1, "%.0f")
        report("r14_pinch_worst_frame_ms", pinch["worstms"] ?? -1)
        print("PERF r14 pinch_settle \(settle)")
        XCTAssertGreaterThan(pinch["pinchsteps"] ?? 0, 0, "The probe must have seen the pinch")
        XCTAssertLessThanOrEqual(pinch["layouts"] ?? 99, 2, "Pinching must not lay the terminal out at every step")
        shot("r14-smooth-3-pinched")
        report("r15_memory_after_3m_and_pinch_mb", probe("mem") ?? -1, "%.1f")
        XCTAssertGreaterThan(probe("cell") ?? 0, cell, "Pinching out must enlarge the text")
        XCTAssertNotEqual(probedGrid(), gridBefore, "Pinching out must reflow the grid")
        let host = try XCTUnwrap(stty())
        XCTAssertEqual("\(host.columns)x\(host.rows)", probedGrid(), "The host must get the pinched grid")

        // Back to the size it started with, from the actions menu.
        let actions = app.buttons["sshSessionActions"]
        for _ in 0..<12 where (probe("cell") ?? 0) > cell + 0.01 {
            XCTAssertNotNil(until(5) { actions.isHittable })
            actions.tap()
            app.openTextAndColors()
            let smaller = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "terminalSmallerText", "Decrease Text Size")).firstMatch
            XCTAssertTrue(smaller.waitForExistence(timeout: 5))
            smaller.tap()
            _ = until(1) { false }
            if smaller.exists { terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
            _ = until(5) { !smaller.exists }
        }
        XCTAssertEqual(probe("cell") ?? 0, cell, accuracy: 0.01, "The text size must be back where it started")
        if keyboard.exists { app.toggleTerminalKeyboard() }
        _ = until(5) { !keyboard.exists && probedGrid() == gridBefore }
        XCTAssertEqual(probedGrid(), gridBefore, "With the keyboard down again, the grid it started with")

        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    // MARK: Round 15: selection and scrolling

    /// One long word per line, so a selection is wide and its handles are far apart.
    private static let word = "abcdefghijklmnopqrstuvwxyz0123456789"

    /// Connects, fills the scrollback with `word` lines, and hides the keyboard.
    private func connectWithWords(_ prefix: String) throws -> (name: String, fingerprint: String) {
        let host = try connectForGrid(prefix, more: [("Long words", "yes \(Self.word) | head -400")])
        runSnippet("Long words")
        XCTAssertNotNil(until(30, poll: 0.5) { text().contains(Self.word) && lastLine().hasSuffix("~$") }, "The words must print")
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { !keyboard.exists })
        _ = until(1) { false }
        return host
    }

    /// Characters selected, from the layout probe.
    private func selected() -> Int { Int(probe("sel") ?? -1) }

    /// The handle knobs' centers, in screen points, from the layout probe.
    private func knobs() -> (start: CGPoint, end: CGPoint)? {
        guard terminal.exists, let range = terminal.label.range(of: " knobs=") else { return nil }
        let values = terminal.label[range.upperBound...].prefix { $0 != " " }.split(separator: ",").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return (CGPoint(x: values[0], y: values[1]), CGPoint(x: values[2], y: values[3]))
    }

    private func screen(_ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private var copyItem: XCUIElement { app.buttons["Copy"].exists ? app.buttons["Copy"] : app.menuItems["Copy"] }

    /// A finger that rests a moment (0.4 s, under the system's 0.5 s long
    /// press) and then swipes scrolls the output: no selection starts, and
    /// no edit menu appears.
    func testSlowStartSwipeScrollsWithoutSelecting() throws {
        continueAfterFailure = true
        executionTimeAllowance = 300
        let (name, fingerprint) = try connectWithWords("R15 Rest")
        for attempt in 0..<3 {
            let top = probe("yDisp") ?? -1
            let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.4, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 200)),
                        withVelocity: .default, thenHoldForDuration: 0.1)
            _ = until(1.5) { false }
            let chars = selected(), after = probe("yDisp") ?? -1
            print("PERF r15 slow_start_swipe_\(attempt) selected=\(chars) yDisp \(top) -> \(after) menu=\(copyItem.exists)")
            shot("r15-slow-start-\(attempt)")
            XCTAssertEqual(chars, 0, "A swipe after the finger rests must not select")
            XCTAssertFalse(copyItem.exists, "A swipe after the finger rests must not offer Copy")
            XCTAssertLessThan(after, top, "A swipe after the finger rests must scroll back")
            if chars > 0 { terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap(); _ = until(1) { false } }
        }
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    /// After a deliberate long press: a swipe that starts on the text about
    /// 30 pt from a handle scrolls (the selection stays as it was), a drag
    /// that starts on a handle's knob moves that end, and Copy copies exactly
    /// what's selected (typed back with the key row's Paste key).
    func testSwipesNearASelectionScrollAndItsHandlesStillDrag() throws {
        continueAfterFailure = true
        executionTimeAllowance = 300
        let (name, fingerprint) = try connectWithWords("R15 Handles")

        // A long press selects the word under the finger; lifting offers Copy.
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35)).press(forDuration: 0.8)
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5), "Lifting a long press must offer Copy")
        _ = until(0.5) { false }
        let word = selected()
        XCTAssertEqual(word, Self.word.count, "A long press selects the word under it")
        shot("r15-handles-1-selected")

        // A swipe from the selected text about 30 pt from the start handle's
        // knob (25 pt to its right, near the row's foot) scrolls. The edit
        // menu sits beside the selection, so the row itself is free.
        let knobsBefore = try XCTUnwrap(knobs(), "The probe must report the handles")
        let top = probe("yDisp") ?? -1
        let cell = probe("cell") ?? 17
        let from = CGPoint(x: knobsBefore.start.x + 25, y: knobsBefore.start.y + 6 + cell * 0.8)
        screen(from).press(forDuration: 0.05, thenDragTo: screen(from).withOffset(CGVector(dx: 0, dy: 120)),
                           withVelocity: .slow, thenHoldForDuration: 0.3)
        _ = until(1.5) { false }
        let afterSwipe = selected(), scrolledTop = probe("yDisp") ?? -1
        print("PERF r15 swipe_near_handle selected \(word) -> \(afterSwipe) yDisp \(top) -> \(scrolledTop) menu=\(copyItem.exists)")
        shot("r15-handles-2-swiped")
        XCTAssertEqual(afterSwipe, word, "A swipe that starts on the text must not move the selection")
        XCTAssertLessThan(scrolledTop, top, "A swipe that starts on the text must scroll")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 3), "The edit menu returns once the scroll stops")
        let knobsScrolled = try XCTUnwrap(knobs(), "The selection must still be there")
        XCTAssertEqual(knobsScrolled.start.y - knobsBefore.start.y, 120, accuracy: 25, "The selection scrolls with its text")

        // A swipe up from the text 30 pt below the end handle's knob, toward
        // it, scrolls forward. (The old target was tested where the finger
        // was once the drag was recognized, so this one took the handle.)
        let below = CGPoint(x: knobsScrolled.end.x - 10, y: knobsScrolled.end.y + 30)
        screen(below).press(forDuration: 0.05, thenDragTo: screen(below).withOffset(CGVector(dx: 0, dy: -80)),
                            withVelocity: .slow, thenHoldForDuration: 0.3)
        _ = until(1.5) { false }
        let afterUp = selected(), forwardTop = probe("yDisp") ?? -1
        print("PERF r15 swipe_toward_handle selected \(word) -> \(afterUp) yDisp \(scrolledTop) -> \(forwardTop) menu=\(copyItem.exists)")
        shot("r15-handles-2b-swiped-up")
        XCTAssertEqual(afterUp, word, "A swipe toward a handle that starts on the text must not move the selection")
        XCTAssertGreaterThan(forwardTop, scrolledTop, "A swipe up that starts on the text must scroll forward")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 3), "The edit menu returns once the scroll stops")

        // A drag that starts on the end handle's knob shortens the selection.
        let knobsNow = try XCTUnwrap(knobs(), "The selection must still be there")
        screen(knobsNow.end).press(forDuration: 0.05, thenDragTo: screen(knobsNow.end).withOffset(CGVector(dx: -100, dy: 0)),
                                   withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5), "Lifting a handle offers Copy again")
        _ = until(0.5) { false }
        let shorter = selected(), handleTop = probe("yDisp") ?? -1
        print("PERF r15 handle_drag selected \(word) -> \(shorter) yDisp \(forwardTop) -> \(handleTop)")
        shot("r15-handles-3-dragged")
        XCTAssertGreaterThan(shorter, 0, "Dragging a handle keeps a selection")
        XCTAssertLessThan(shorter, word, "Dragging the end handle left must shorten the selection")
        XCTAssertEqual(handleTop, forwardTop, "Dragging a handle must not scroll")

        // Copy, then the Paste key types exactly that back at the prompt.
        copyItem.tap()
        _ = until(1) { false }
        XCTAssertEqual(selected(), 0, "Copy ends the selection")
        app.buttons["terminalJumpToLatest"].tap()
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$") })
        app.toggleTerminalKeyboard()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let paste = app.buttons["terminalKey-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        for _ in 0..<6 where !paste.isHittable {
            let escape = app.buttons["terminalKey-escape"]
            let start = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
        }
        paste.tap()
        let expected = String(Self.word.prefix(max(0, shorter)))
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$ " + expected) }, "Copy must copy exactly the selection (\(lastLine()))")
        shot("r15-handles-4-pasted")
        app.buttons["terminalInterrupt"].tap()
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$") })
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    // MARK: Round 15: programs that ask for the mouse

    /// The visible lines, trimmed.
    private func lines() -> [String] {
        text().split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// tmux's copy-mode position, `[top/total]`, in the pane's corner.
    private func tmuxPosition() -> String? {
        guard let range = text().range(of: #"\[\d+/\d+\]"#, options: .regularExpression) else { return nil }
        return String(text()[range])
    }

    /// vim's ruler, `line,column`, at the end of its last line.
    private func vimRuler() -> String? {
        guard let last = lines().last(where: { !$0.isEmpty }),
              let range = last.range(of: #"\d+,\d+"#, options: [.regularExpression, .backwards]) else { return nil }
        return String(last[range])
    }

    /// While typing, in tmux with `mouse on` and in vim with `mouse=a` (both
    /// inside the fixture's shell, not Witerm's own tmux): a swipe scrolls the
    /// program's view and starts no selection, a tap in vim moves its cursor,
    /// and Witerm selects nothing. A held-button drag (what SwiftTerm sent
    /// before) makes tmux select and copy, and vim enter Visual mode.
    func testSwipesScrollProgramsThatAskForTheMouse() throws {
        continueAfterFailure = true
        executionTimeAllowance = 400
        let (name, fingerprint) = try connectForGrid("R15 Mouse", more: [
            ("Tmux", "echo set -g mouse on > ~/.tmux.conf && tmux -L r15 new -A -s r15"),
            ("Fill", "seq 1 400"),
            ("End tmux", "tmux -L r15 kill-server"),
            // Without bracketed paste, so the snippet that quits is typed, not pasted.
            ("Vim", "seq 1 400 > /tmp/r15.txt && vim -n -i NONE -c 'set mouse=a ruler t_BE=' /tmp/r15.txt"),
            ("Leave vim", ":q!"),
        ])
        // A plain shell (no mouse) with the keyboard up: a swipe scrolls Witerm's scrollback.
        runSnippet("Fill")
        XCTAssertNotNil(until(15) { lines().contains("400") && lastLine().hasSuffix("~$") }, "seq must print")
        _ = until(1) { false }
        let shellTop = probe("yDisp") ?? -1
        let shellStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        shellStart.press(forDuration: 0.05, thenDragTo: shellStart.withOffset(CGVector(dx: 0, dy: 220)), withVelocity: .default, thenHoldForDuration: 0.3)
        _ = until(2) { false }
        print("PERF r15 shell_typing_swipe yDisp \(shellTop) -> \(probe("yDisp") ?? -1) selected=\(selected()) keyboard=\(keyboard.exists)")
        XCTAssertLessThan(probe("yDisp") ?? 0, shellTop, "With the keyboard up, a swipe at a shell prompt scrolls Witerm's scrollback")
        XCTAssertEqual(selected(), 0, "and selects nothing")
        let latest = app.buttons["terminalJumpToLatest"]
        if latest.waitForExistence(timeout: 3) { latest.tap() }
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$") })

        // tmux, its status line at the bottom.
        runSnippet("Tmux")
        XCTAssertNotNil(until(15) { text().contains("[r15]") }, "tmux must start")
        runSnippet("Fill")
        XCTAssertNotNil(until(15) { lines().contains("400") && lastLine().contains("[r15]") }, "seq must print inside tmux")
        _ = until(1) { false }
        shot("r15-mouse-1-tmux")
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)), withVelocity: .default, thenHoldForDuration: 0.3)
        _ = until(2) { false }
        let position = tmuxPosition()
        print("PERF r15 tmux_swipe position=\(position ?? "none") selected=\(selected()) lastline=\(lastLine())")
        shot("r15-mouse-2-tmux-swiped")
        XCTAssertNotNil(position, "A swipe must scroll tmux's own view (copy mode's [top/total])")
        XCTAssertFalse(lines().contains("400"), "The pane must show earlier output")
        XCTAssertEqual(selected(), 0, "Witerm selects nothing")
        // Ctrl+C leaves copy mode (a snippet arrives as a paste, which copy mode ignores).
        app.buttons["terminalInterrupt"].tap()
        XCTAssertNotNil(until(5) { tmuxPosition() == nil }, "Ctrl+C leaves copy mode")
        runSnippet("End tmux")
        XCTAssertNotNil(until(10) { lastLine().hasSuffix("~$") && !text().contains("[r15]") }, "tmux must end")

        // vim on a long file, with its ruler.
        runSnippet("Vim")
        XCTAssertNotNil(until(15) { vimRuler() != nil && lines().first == "1" }, "vim must open at the top (it may put the cursor back where it was)")
        _ = until(1) { false }
        shot("r15-mouse-3-vim")
        let lower = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        lower.press(forDuration: 0.05, thenDragTo: lower.withOffset(CGVector(dx: 0, dy: -220)), withVelocity: .default, thenHoldForDuration: 0.3)
        _ = until(2) { false }
        let top = lines().first ?? ""
        print("PERF r15 vim_swipe top=\(top) ruler=\(vimRuler() ?? "none") visual=\(text().contains("VISUAL")) selected=\(selected())")
        shot("r15-mouse-4-vim-swiped")
        XCTAssertNotEqual(top, "1", "A swipe up must scroll vim's view down")
        XCTAssertFalse(text().contains("VISUAL"), "A swipe must not start Visual mode")
        XCTAssertEqual(selected(), 0, "Witerm selects nothing")
        // A tap on a line puts vim's cursor there (keyboard up: taps are clicks).
        if !keyboard.exists { app.toggleTerminalKeyboard() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        _ = until(1) { false }
        let rows = lines()
        let cell = probe("cell") ?? 17
        let index = 5, target = rows.count > index ? rows[index] : ""
        terminal.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: (CGFloat(index) + 0.5) * cell)).tap()
        XCTAssertNotNil(until(5) { vimRuler()?.hasPrefix(target + ",") == true }, "A tap must move vim's cursor to line \(target) (\(vimRuler() ?? "none"))")
        shot("r15-mouse-5-vim-tapped")
        // Escape first, in case a drag left vim in Visual mode.
        let escape = app.buttons["terminalKey-escape"]
        if escape.isHittable { escape.tap() }
        runSnippet("Leave vim")
        XCTAssertNotNil(until(10) { lastLine().hasSuffix("~$") }, "vim must quit")
        disconnectAndRemove(name, fingerprint: fingerprint)
    }

    // MARK: Round 15: renderer trial

    /// Picks a color scheme from the actions menu's Text and Colors, or
    /// toggles Increase Terminal Contrast in Settings ▸ Advanced (Round 16
    /// moved it there), coming back to the same connected terminal.
    private func changeTerminalDisplay(scheme: String? = nil) {
        let actions = app.buttons["sshSessionActions"]
        if !actions.isHittable, keyboard.exists { app.toggleTerminalKeyboard() }
        XCTAssertNotNil(until(5) { actions.isHittable })
        if let scheme {
            actions.tap()
            app.openTextAndColors()
            let choice = app.buttons[scheme].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "The \(scheme) scheme must be offered")
            choice.tap()
            _ = until(1) { false }
            return
        }
        app.buttons["sshShowHosts"].tap()
        let settings = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["settingsAdvanced"].tap()
        let contrast = app.switches["terminalHighContrast"]
        XCTAssertTrue(contrast.waitForExistence(timeout: 5))
        contrast.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons.element(boundBy: 0).tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshProfileRow-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertNotNil(until(5) { actions.isHittable })
        _ = until(1) { false }
    }

    /// Screens to compare the two renderers by eye, with the same steps:
    /// the prompt and cursor, a selection with its handles and menu, Increase
    /// Terminal Contrast on and off again, landscape, scrolled back, and
    /// after Jump to Latest. Run with `WITERM_RENDERER=metal` (and
    /// `WITERM_METAL_RAW=1`) and without; `WITERM_SHOTS_DIR` keeps the
    /// captures. The reading text (what VoiceOver reads) is checked either way.
    func testRendererTrialScreens() throws {
        continueAfterFailure = true
        executionTimeAllowance = 300
        let expected = ProcessInfo.processInfo.environment["WITERM_RENDERER"] == "metal" ? "metal" : "coretext"
        let (name, fingerprint) = try connectWithWords("R15 Render")
        XCTAssertTrue(terminal.label.contains(" renderer=" + expected), "The probe must report the \(expected) renderer")
        app.toggleTerminalKeyboard()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        _ = until(1) { false }
        shot("r15-render-\(expected)-1-prompt")
        XCTAssertTrue(lastLine().hasSuffix("~$"), "The reading text ends with the prompt")
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { !keyboard.exists })

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35)).press(forDuration: 0.8)
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5))
        _ = until(0.5) { false }
        XCTAssertEqual(selected(), Self.word.count)
        shot("r15-render-\(expected)-2-selection")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        XCTAssertNotNil(until(3) { selected() == 0 })

        changeTerminalDisplay()
        shot("r15-render-\(expected)-3-contrast-on")
        changeTerminalDisplay()
        shot("r15-render-\(expected)-4-contrast-off")
        // A scheme with its own text color (Ocean's is navy), then back.
        changeTerminalDisplay(scheme: "Ocean")
        shot("r15-render-\(expected)-4b-ocean")
        changeTerminalDisplay(scheme: "System")
        shot("r15-render-\(expected)-4c-system")

        XCUIDevice.shared.orientation = .landscapeLeft
        _ = until(3) { terminal.frame.width > terminal.frame.height }
        _ = until(1) { false }
        shot("r15-render-\(expected)-5-landscape")
        XCUIDevice.shared.orientation = .portrait
        _ = until(3) { terminal.frame.width < terminal.frame.height }

        terminal.swipeDown(velocity: .fast)
        let latest = app.buttons["terminalJumpToLatest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "Scrolled back shows Jump to Latest")
        _ = until(2) { false }
        shot("r15-render-\(expected)-6-scrolled-back")
        latest.tap()
        XCTAssertNotNil(until(5) { lastLine().hasSuffix("~$") }, "Jump to Latest returns to the prompt")
        _ = until(1) { false }
        shot("r15-render-\(expected)-7-latest")
        report("r15_memory_\(expected)_mb", probe("mem") ?? -1, "%.1f")
        disconnectAndRemove(name, fingerprint: fingerprint)
    }
}
