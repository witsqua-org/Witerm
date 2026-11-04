import XCTest

/// Uses the normal signed app and an explicitly configured disposable OpenSSH
/// server. No user host, saved SSH credential or terminal session is selected.
@MainActor final class SSHWorkspaceTests: XCTestCase {
    func testDirectSSHTrustTerminalKeyboardAndSFTP() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        guard let port = ProcessInfo.processInfo.environment["WITERM_SSH_UI_PORT"],
              let number = Int(port), (1...65535).contains(number),
              let fingerprint = ProcessInfo.processInfo.environment["WITERM_SSH_UI_FINGERPRINT"],
              fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        let app = XCUIApplication()
        let profileName = "SSH 验收 iOS 1026"
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "--witerm-ui-test-steady-terminal-cursor"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sshTab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(sshTab.waitForExistence(timeout: 10))
        sshTab.tap()
        app.buttons["newSSHProfile"].tap()
        let host = app.textFields.matching(identifier: "sshHostAddress").firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap(); host.typeText("fixture@127.0.0.1:" + port)
        app.buttons["sshMoreOptions"].tap()
        let name = app.textFields["sshProfileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let middle = app.windows.firstMatch.frame.midY
        for _ in 0..<4 where !name.isHittable || name.frame.maxY > middle { app.swipeUp() }
        name.tap(); name.typeText(profileName)
        let password = app.secureTextFields.matching(identifier: "sshHostPassword").firstMatch
        reveal(password, in: app); password.tap(); password.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].tap()
        let identity = app.staticTexts["sshHostFingerprint"]
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        // The system password offer can cover the trust sheet; decline it first.
        declinePasswordOffer(app, timeout: 3)
        if identity.waitForExistence(timeout: 10) {
            XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
            app.buttons["sshTrustHost"].tap()
        }
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let prompt = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "~$ ", "~$ "), object: terminal)
        wait(for: [prompt], timeout: 10)
        declinePasswordOffer(app, timeout: 2)
        // A new connection is ready to type into: the keyboard is already up,
        // and the keyboard button hides and shows it again.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard must be up when the terminal connects")
        app.toggleTerminalKeyboard()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        wait(for: [hidden], timeout: 5)
        app.toggleTerminalKeyboard()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard control must focus the real SSH input view")
        let marker = "~$ z"
        XCTAssertFalse((terminal.value as? String ?? terminal.label).contains(marker))
        // The terminal's separate AX reading view intentionally hides its input
        // view. Use a real software key instead of app.typeText's AX-focus search.
        typeLetter("z", until: marker, in: terminal, app: app)
        let delete = app.keyboards.keys["delete"].firstMatch
        XCTAssertTrue(delete.exists)
        delete.tap()
        let erased = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (value CONTAINS %@ OR label CONTAINS %@)", marker, marker), object: terminal)
        wait(for: [erased], timeout: 10)
        tapVisibleControl(app.buttons["sshSessionActions"], in: app)
        app.buttons["SFTP 文件"].tap()
        XCTAssertTrue(app.textFields["sshSFTPPath"].waitForExistence(timeout: 10))
        let parentDirectory = app.buttons["上一级"]
        XCTAssertTrue(parentDirectory.waitForExistence(timeout: 5))
        let directoryLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: parentDirectory)
        wait(for: [directoryLoaded], timeout: 10)
        XCTAssertTrue(app.buttons["文件操作"].exists)
        XCTAssertFalse(app.staticTexts["sshSFTPIssue"].exists)
        tapVisibleControl(app.buttons["完成"], in: app)
        XCTAssertTrue(terminal.exists, "Opening SFTP must preserve the SSH terminal")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 10))
        XCTAssertFalse(terminal.exists)
        tapVisibleControl(app.buttons["sshReconnect"], in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap(); password.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sshTrustHost"].exists, "Reconnect must use the existing verified fixture pin")
        declinePasswordOffer(app, timeout: 3)

        tapVisibleControl(app.buttons["sshSessionActions"], in: app)
        app.buttons["断开"].tap()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 5))
        tapVisibleControl(app.buttons["sshShowHosts"], in: app)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))

        // Reopen an actual persisted fixture row. The form must receive its
        // immutable editor request rather than a stale nil/new-profile capture.
        let savedRow = fixtureRows(app, name: profileName, port: port).firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        tapVisibleControl(savedRow, in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let populated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", profileName), object: name)
        wait(for: [populated], timeout: 5)
        // A saved custom name opens More Options; the address reads back as typed.
        XCTAssertEqual(host.value as? String, "fixture@127.0.0.1:" + port)
        tapVisibleControl(app.buttons["取消"], in: app)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        XCTAssertFalse(terminal.exists, "Canceling the saved profile must not reconnect")

        // Only the exact disposable fixture rows and their expected pin are
        // eligible. If the native cleanup UI differs, leave the remaining data
        // for explicit cleanup instead of touching another host or credential.
        let failure = cleanupFixtures(app, name: profileName, expectedFingerprint: fingerprint)
        print("SSH_FIXTURE_CLEANUP completed=\(failure == nil)" + (failure.map { " reason=\($0)" } ?? ""))
    }

    /// Scrolling down to a field lower in the form can leave one above it under
    /// the navigation bar, where a tap lands on the bar. Drag the form back
    /// until the element is below the bar.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let bar = app.navigationBars.firstMatch
        for _ in 0..<4 where !element.isHittable || (bar.exists && element.frame.minY < bar.frame.maxY + 8) {
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        }
    }

    private func tapVisibleControl(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let frame = element.frame
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "Control must be visible in the app window")
        // iOS glass toolbar controls can expose a valid visible frame but an
        // invalid AX activation point. Tap the observed element's real center.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Two hosts stay connected at once. Returning to a host shows its live
    /// terminal state, and disconnecting one leaves the other running.
    func testTwoHostsStayConnected() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let environment = ProcessInfo.processInfo.environment
        guard let firstPort = environment["WITERM_SSH_UI_PORT"], Int(firstPort) != nil,
              let firstPin = environment["WITERM_SSH_UI_FINGERPRINT"], firstPin.hasPrefix("SHA256:"),
              let secondPort = environment["WITERM_SSH_UI_SECOND_PORT"], Int(secondPort) != nil,
              let secondPin = environment["WITERM_SSH_UI_SECOND_FINGERPRINT"], secondPin.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure two disposable SSH UI fixtures explicitly")
        }
        let app = XCUIApplication()
        let firstName = "SSH 验收 iOS 双会话 A", secondName = "SSH 验收 iOS 双会话 B"
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "--witerm-ui-test-steady-terminal-cursor"]
        // Optional text size, e.g. UICTContentSizeCategoryAccessibilityL, for layout review.
        if let size = environment["WITERM_UI_CONTENT_SIZE"] {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sshTab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(sshTab.waitForExistence(timeout: 10))
        sshTab.tap()

        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        connectNewHost(app, name: firstName, port: firstPort, fingerprint: firstPin)
        // Leave a marker in the first session's live line.
        // The keyboard comes up with the connection.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        typeLetter("z", until: "~$ z", in: terminal, app: app)

        tapVisibleControl(app.buttons["sshShowHosts"], in: app)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        XCTAssertTrue(connectedRow(app, name: firstName).waitForExistence(timeout: 5), "The first host must stay connected")
        connectNewHost(app, name: secondName, port: secondPort, fingerprint: secondPin)
        tapVisibleControl(app.buttons["sshShowHosts"], in: app)
        XCTAssertTrue(connectedRow(app, name: firstName).waitForExistence(timeout: 5))
        XCTAssertTrue(connectedRow(app, name: secondName).waitForExistence(timeout: 5))
        let both = XCTAttachment(screenshot: app.screenshot())
        both.name = "ios-ssh-two-sessions"; both.lifetime = .keepAlways; add(both)

        // The first session still shows its marker and remains usable.
        tapVisibleControl(connectedRow(app, name: firstName), in: app)
        let kept = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "~$ z", "~$ z"), object: terminal)
        wait(for: [kept], timeout: 10)
        let shown = XCTAttachment(screenshot: app.screenshot())
        shown.name = "ios-ssh-terminal"; shown.lifetime = .keepAlways; add(shown)
        tapVisibleControl(app.buttons["sshSessionActions"], in: app)
        app.buttons["断开"].tap()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 5))
        tapVisibleControl(app.buttons["sshShowHosts"], in: app)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        XCTAssertFalse(connectedRow(app, name: firstName).exists)
        XCTAssertTrue(connectedRow(app, name: secondName).exists, "Disconnecting one host must leave the other connected")

        tapVisibleControl(connectedRow(app, name: secondName), in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        tapVisibleControl(app.buttons["sshSessionActions"], in: app)
        app.buttons["断开"].tap()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 5))
        tapVisibleControl(app.buttons["sshShowHosts"], in: app)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))

        let firstCleanup = cleanupFixtures(app, name: firstName, expectedFingerprint: firstPin)
        let secondCleanup = cleanupFixtures(app, name: secondName, expectedFingerprint: secondPin)
        print("SSH_FIXTURE_CLEANUP completed=\(firstCleanup == nil && secondCleanup == nil)"
              + ((firstCleanup ?? secondCleanup).map { " reason=\($0)" } ?? ""))
    }

    private func connectedRow(_ app: XCUIApplication, name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@ AND value ENDSWITH %@",
            "sshProfileRow-", name, "，已连接")).firstMatch
    }

    /// In a live terminal: the Snippets key types a saved command, and Find in
    /// Terminal counts its matches without sending anything to the shell.
    /// The snippet exists only in this launch's arguments, never in saved
    /// preferences.
    func testSnippetKeyAndFindBarInLiveTerminal() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        let profileName = "SSH 验收 iOS 查找"
        let marker = "witerm-find-marker"
        let snippet = #"[{"id":"6B1C2E0A-5A43-4F7E-9C8B-1D2E3F405162","name":"Find marker","text":"echo "# + marker + #"","runsImmediately":true}]"#
        let hex = Data(snippet.utf8).map { String(format: "%02x", $0) }.joined()
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "--witerm-ui-test-steady-terminal-cursor", "-witerm.commandSnippets", "<\(hex)>",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        let sshTab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(sshTab.waitForExistence(timeout: 10))
        sshTab.tap()
        connectNewHost(app, name: profileName, port: port, fingerprint: fingerprint)
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch

        // The Snippets key lists the saved command and types it with Return.
        // The keyboard comes up with the connection.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let snippetsKey = app.buttons["terminalKey-snippets"]
        XCTAssertTrue(snippetsKey.waitForExistence(timeout: 5))
        for _ in 0..<4 where !snippetsKey.isHittable { app.buttons["terminalKey-escape"].swipeLeft() }
        XCTAssertTrue(snippetsKey.isHittable, "The Snippets key must be reachable in the key row")
        snippetsKey.tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Find marker")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The Snippets key must list the saved snippet")
        item.tap()
        // The command line and its output: the shell ran it once.
        let ran = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "~$ echo " + marker, "~$ echo " + marker),
            object: terminal)
        wait(for: [ran], timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let ranShot = XCTAttachment(screenshot: app.screenshot())
        ranShot.name = "ios-ssh-snippet"; ranShot.lifetime = .keepAlways; add(ranShot)
        app.toggleTerminalKeyboard()

        // Find counts both lines and reports no match for anything else. On
        // iPhone it lives in the terminal's actions menu.
        tapVisibleControl(app.buttons["sshSessionActions"], in: app)
        tapVisibleControl(app.buttons["在终端中查找"], in: app)
        let field = app.textFields["terminalFindField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(marker)
        let count = app.staticTexts["terminalFindCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "共 2 个"), object: count)
        wait(for: [two], timeout: 5)
        let findShot = XCTAttachment(screenshot: app.screenshot())
        findShot.name = "ios-ssh-find"; findShot.lifetime = .keepAlways; add(findShot)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: marker.count) + "zqxjv")
        let none = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "无匹配项"), object: count)
        wait(for: [none], timeout: 5)
        tapVisibleControl(app.buttons["terminalFindDone"], in: app)
        XCTAssertFalse(field.waitForExistence(timeout: 2))
        // Searching never typed into the shell.
        let value = terminal.value as? String ?? terminal.label
        XCTAssertFalse(value.contains("zqxjv"), "Find must not send input to the terminal")

        tapVisibleControl(app.buttons["sshSessionActions"], in: app)
        app.buttons["断开"].tap()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 5))
        tapVisibleControl(app.buttons["sshShowHosts"], in: app)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        let failure = cleanupFixtures(app, name: profileName, expectedFingerprint: fingerprint)
        print("SSH_FIXTURE_CLEANUP completed=\(failure == nil)" + (failure.map { " reason=\($0)" } ?? ""))
        XCTAssertNil(failure)
    }

    /// The terminal around the keyboard, scrolling, and selection, against
    /// the fixture: the keyboard keeps the width and the prompt in view, and
    /// hiding it restores the same grid; long output scrolls back and returns;
    /// a long press copies exactly the word without typing anything.
    func testKeyboardScrollAndSelectionInLiveTerminal() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        let shots = environment["WITERM_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
        let profileName = "SSH 验收 iOS 布局"
        func snippet(_ id: Int, _ name: String, _ text: String) -> String {
            #"{"id":"6B1C2E0A-5A43-4F7E-9C8B-1D2E3F40516\#(id)","name":"\#(name)","text":"\#(text)","runsImmediately":true}"#
        }
        let snippets = "[" + [snippet(3, "Grid now", "stty size"), snippet(4, "Grid later", "sleep 6; stty size"),
                              snippet(5, "Long output", "seq 1 3000"), snippet(6, "Pager", "seq 1 300 | less"), snippet(7, "Quit pager", "q"),
                              snippet(8, "Ticks", "for i in $(seq 1 30); do echo tick$i; sleep 0.3; done")]
            .joined(separator: ",") + "]"
        let hex = Data(snippets.utf8).map { String(format: "%02x", $0) }.joined()
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "--witerm-ui-test-steady-terminal-cursor",
                               "-witerm.commandSnippets", "<\(hex)>", "--witerm-ui-test-layout-probe", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        // Round 15's renderer trial (DEBUG builds): `WITERM_RENDERER=metal`.
        if let renderer = environment["WITERM_RENDERER"] { app.launchArguments += ["-witerm.debug.renderer", renderer] }
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        func shot(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            if let shots { try? app.screenshot().pngRepresentation.write(to: shots.appendingPathComponent(name + ".png")) }
        }
        let sshTab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(sshTab.waitForExistence(timeout: 10))
        sshTab.tap()
        connectNewHost(app, name: profileName, port: port, fingerprint: fingerprint)
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        let keyboard = app.keyboards.firstMatch
        func text() -> String { terminal.exists ? (terminal.value as? String ?? terminal.label) : "" }
        func waitFor(_ predicate: @escaping (String) -> Bool, timeout: TimeInterval = 10, _ message: String) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, !predicate(text()) { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            XCTAssertTrue(predicate(text()), message + "\n" + text() + "\n" + (terminal.exists ? terminal.label : ""))
        }
        /// The last `rows cols` line `stty size` printed on screen.
        func grid() -> (rows: Int, columns: Int)? {
            text().split(whereSeparator: \.isNewline).reversed().lazy.compactMap { line -> (Int, Int)? in
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard parts.count == 2, let rows = Int(parts[0]), let columns = Int(parts[1]) else { return nil }
                return (rows, columns)
            }.first
        }
        /// Scrolls the key row until `key` is on screen, from wherever it was left.
        func reveal(_ key: XCUIElement) {
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminalKey-"))
            let width = app.windows.firstMatch.frame.width
            for _ in 0..<8 where !key.isHittable {
                // Never start on a key that repeats while held.
                let repeating = ["left", "up", "down", "right", "pageUp", "pageDown"].map { "terminalKey-" + $0 }
                guard let visible = (0..<row.count).lazy.map({ row.element(boundBy: $0) })
                    .first(where: { $0.isHittable && !repeating.contains($0.identifier) }) else { return }
                // A short drag toward the key; a drag never sends the key it starts on.
                let start = visible.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let dx: CGFloat = key.frame.midX > width / 2 ? -width / 3 : width / 3
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
            }
        }
        func run(_ name: String) {
            if !keyboard.exists { app.toggleTerminalKeyboard() }
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            let key = app.buttons["terminalKey-snippets"]
            reveal(key)
            key.tap()
            let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), name)
            item.tap()
        }
        let window = app.windows.firstMatch.frame

        // 1. The keyboard is up with the connection; the terminal ends above
        // the key row, and the prompt line is on screen.
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let escape = app.buttons["terminalKey-escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(terminal.frame.maxY, escape.frame.minY + 1, "The terminal must end above the key row")
        // The first seven keys (Esc, Ctrl, Tab and the arrows) fit the width.
        XCTAssertLessThanOrEqual(app.buttons["terminalKey-right"].frame.maxX, window.maxX, "Esc, Ctrl, Tab and the arrows must fit without scrolling")
        run("Grid now")
        waitFor({ _ in grid() != nil }, "stty size never printed")
        let up = try XCTUnwrap(grid())
        print("TERMINAL_PROBE keyboard-up \(terminal.label)")
        waitFor({ $0.split(whereSeparator: \.isNewline).last?.contains("~$") == true }, "The prompt must be the last visible line above the keyboard")
        shot("terminal-keyboard-up")

        // 2. Hiding the keyboard keeps the width, gives back the rows, and
        // leaves no band under the terminal.
        run("Grid later")
        app.toggleTerminalKeyboard()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        wait(for: [gone], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        let down = try XCTUnwrap(grid())
        let downFrame = terminal.frame
        print("TERMINAL_GRID keyboard-up \(up) keyboard-down \(down) frame \(downFrame) \(terminal.label)")
        XCTAssertEqual(down.columns, up.columns, "The keyboard must never change the width")
        XCTAssertGreaterThan(down.rows, up.rows, "Hidden keyboard gives the rows back")
        // Round 18: the text uses the full height and the keyboard button
        // floats over its bottom right (no strip of its own any more).
        let keyboardButton = app.buttons["sshKeyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 5), "The keyboard button shows while the keyboard is hidden")
        XCTAssertGreaterThan(terminal.frame.maxY, window.maxY - 60, "The terminal must fill the screen again")
        XCTAssertLessThanOrEqual(keyboardButton.frame.maxY, terminal.frame.maxY, "The keyboard button floats over the text")
        XCTAssertGreaterThan(keyboardButton.frame.midX, window.midX, "The keyboard button is at the bottom right")
        XCTAssertGreaterThanOrEqual(keyboardButton.frame.width, 44)
        shot("terminal-keyboard-down")

        // 3. Showing and hiding it again lands on the same grid: the view is restored.
        app.toggleTerminalKeyboard()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        shot("terminal-keyboard-again")
        run("Grid later")
        app.toggleTerminalKeyboard()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        let restored = try XCTUnwrap(grid())
        print("TERMINAL_GRID restored \(restored) frame \(terminal.frame) \(terminal.label)")
        XCTAssertEqual(terminal.frame, downFrame, "Hiding the keyboard again must restore the same frame")
        XCTAssertEqual(restored.rows, down.rows, "Hiding the keyboard again must restore the same rows")
        XCTAssertEqual(restored.columns, down.columns)
        shot("terminal-keyboard-restored")

        // 4. Long output: the view follows it to the end, scrolls back through
        // it, and returns to the bottom.
        let streaming = Date()
        run("Long output")
        waitFor({ $0.contains("3000\n") || $0.contains("\n3000") }, timeout: 30, "The view must follow output to its end")
        print("TERMINAL_SEQ_3000_SECONDS " + String(format: "%.1f", Date().timeIntervalSince(streaming)))
        app.toggleTerminalKeyboard()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)], timeout: 5)
        for _ in 0..<3 { terminal.swipeDown(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(text().contains("\n3000"), "Swiping down must scroll back")
        shot("terminal-scrolled-back")
        for _ in 0..<40 { terminal.swipeDown(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let top = text()
        terminal.swipeDown(velocity: .fast)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(text(), top, "Scrollback has a top that stays put")
        shot("terminal-scrollback-top")
        for _ in 0..<45 { terminal.swipeUp(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        waitFor({ $0.contains("3000") && $0.contains("~$") }, "Swiping up must return to the live prompt")

        // 5. A long press selects the word under it; Copy puts exactly that
        // word on the pasteboard and types nothing. (The test runner may not
        // read the pasteboard, so the Paste key types it back to check.)
        let before = text()
        let lines = before.split(separator: "\n", omittingEmptySubsequences: false)
        let row = try XCTUnwrap(lines.lastIndex { $0 == "2999" }, "2999 must be on screen")
        let point = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 12, dy: (CGFloat(row) + 0.5) * terminal.frame.height / CGFloat(lines.count)))
        point.press(forDuration: 0.8)
        let copy = app.buttons["拷贝"].exists ? app.buttons["拷贝"] : app.menuItems["拷贝"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Lifting a long press must offer Copy")
        shot("terminal-selection")
        copy.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(text(), before, "Selecting and copying must not type into the shell")
        app.toggleTerminalKeyboard()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let paste = app.buttons["terminalKey-paste"]
        reveal(paste)
        paste.tap()
        /// The last line with text, without the padding a terminal row keeps.
        func lastLine(_ page: String) -> String {
            page.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        }
        waitFor({ lastLine($0).hasSuffix("~$ 2999") }, "Copy must put exactly the selected word on the pasteboard")
        app.buttons["terminalInterrupt"].tap()
        waitFor({ lastLine($0).hasSuffix("~$") }, "Ctrl+C clears the line")

        // 6. A pager opens, fills the view, and quits cleanly. (BusyBox less
        // draws on the main screen; the alternate screen is unit-tested.)
        run("Pager")
        waitFor({ $0.contains("standard input") || $0.contains("(END)") }, "less never opened")
        XCTAssertFalse(text().contains("~$"), "The pager's page replaces the shell's lines")
        shot("terminal-pager")
        run("Quit pager")
        waitFor({ lastLine($0).hasSuffix("~$") }, "Quitting less must return to the prompt")
        XCTAssertFalse(text().contains("standard input"), "The pager's status line leaves with it")

        // 7. Scrolled back while output keeps arriving, the view stays put;
        // back at the bottom, it follows again.
        run("Ticks")
        waitFor({ $0.contains("tick3") }, "The slow output never started")
        app.toggleTerminalKeyboard()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)], timeout: 5)
        for _ in 0..<2 { terminal.swipeDown(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let held = text()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(text(), held, "New output must not pull a scrolled-back view")
        shot("terminal-held-while-streaming")
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        for _ in 0..<6 { terminal.swipeUp(velocity: .fast) }
        waitFor({ $0.contains("tick30") }, "Back at the bottom, the view shows the latest output")

        tapVisibleControl(app.buttons["sshSessionActions"], in: app)
        app.buttons["断开"].tap()
        XCTAssertTrue(app.buttons["sshReconnect"].waitForExistence(timeout: 5))
        tapVisibleControl(app.buttons["sshShowHosts"], in: app)
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        let failure = cleanupFixtures(app, name: profileName, expectedFingerprint: fingerprint)
        print("SSH_FIXTURE_CLEANUP completed=\(failure == nil)" + (failure.map { " reason=\($0)" } ?? ""))
        XCTAssertNil(failure)
    }

    /// Taps a letter on the software keyboard until it reaches the shell.
    /// With an input method such as Pinyin active (as on a simulator set up
    /// for Chinese), the letter composes instead of typing; clear that and
    /// move to the next keyboard, as a person would with the globe key.
    private func typeLetter(_ letter: String, until marker: String, in terminal: XCUIElement, app: XCUIApplication) {
        let next = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘"])).firstMatch
        for _ in 0..<4 {
            let key = app.keyboards.keys[letter].firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            // It exists as soon as it starts sliding in; wait until it's on screen.
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: key)], timeout: 5)
            key.tap()
            let shown = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", marker, marker)
            let typed = { XCTNSPredicateExpectation(predicate: shown, object: terminal) }
            if XCTWaiter.wait(for: [typed()], timeout: 2) == .completed { return }
            // Round 20: composing, Return reads Confirm (确认) and commits
            // the letter as typed, as a person would do. Tapped where it is:
            // XCUITest can't scroll the keyboard's own key into view.
            let confirm = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["确认", "Confirm", "confirm"])).firstMatch
            if confirm.exists {
                confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                if XCTWaiter.wait(for: [typed()], timeout: 2) == .completed { return }
            }
            app.keyboards.keys["delete"].firstMatch.tap()
            guard next.exists else { break }
            next.tap()
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "letter-not-typed"; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("letter-not-typed.png"))
        }
        print("TERMINAL_TEXT", (terminal.value as? String ?? terminal.label).suffix(300))
        XCTFail("The letter \(letter) never reached the shell")
    }

    /// Creates a fixture host from the list, verifies its key, and waits for
    /// the shell prompt.
    private func connectNewHost(_ app: XCUIApplication, name profileName: String, port: String, fingerprint: String) {
        XCTAssertFalse(anyFixtureRows(app, name: profileName).firstMatch.exists, "Fixture host already exists; refusing to touch it")
        app.buttons["newSSHProfile"].tap()
        let host = app.textFields.matching(identifier: "sshHostAddress").firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap(); host.typeText("fixture@127.0.0.1:" + port)
        app.buttons["sshMoreOptions"].tap()
        let name = app.textFields["sshProfileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let middle = app.windows.firstMatch.frame.midY
        for _ in 0..<4 where !name.isHittable || name.frame.maxY > middle { app.swipeUp() }
        name.tap(); name.typeText(profileName)
        let password = app.secureTextFields.matching(identifier: "sshHostPassword").firstMatch
        reveal(password, in: app); password.tap(); password.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].tap()
        declinePasswordOffer(app, timeout: 3)
        let identity = app.staticTexts["sshHostFingerprint"]
        if identity.waitForExistence(timeout: 10) {
            XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
            app.buttons["sshTrustHost"].tap()
        }
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        let prompt = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "~$ ", "~$ "), object: terminal)
        wait(for: [prompt], timeout: 10)
        declinePasswordOffer(app, timeout: 2)
    }

    /// Opt-in recovery after an interrupted run: removes only rows carrying
    /// this test's unique name and the pins of their own loopback ports.
    func testRemoveLeftoverFixtureHosts() throws {
        guard ProcessInfo.processInfo.environment["WITERM_SSH_UI_CLEANUP"] == "1" else {
            throw XCTSkip("Explicit leftover fixture cleanup only")
        }
        let app = XCUIApplication()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchArguments += ["-witerm.onboarding.completedVersion", "1", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sshTab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(sshTab.waitForExistence(timeout: 10))
        sshTab.tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        // Every fixture name these tests use; each is unique to them.
        for name in ["SSH 验收 iOS 1026", "SSH 验收 iOS 双会话 A", "SSH 验收 iOS 双会话 B", "SSH 验收 iOS 查找", "SSH 验收 iOS 布局"] {
            let failure = cleanupFixtures(app, name: name, expectedFingerprint: nil, anyLoopbackPin: true)
            XCTAssertNil(failure, "\(name): \(failure ?? "")")
        }
    }

    /// iOS can offer its own password manager after the login form closes.
    /// Decline it: this fixture never authorizes saving a credential there.
    private func declinePasswordOffer(_ app: XCUIApplication, timeout: TimeInterval) {
        let passwordOffer = app.buttons["Not Now"]
        guard passwordOffer.waitForExistence(timeout: timeout) else { return }
        // The offer can arrive mid-transition between sheets, when a single
        // tap is not delivered. Retry until it is actually gone.
        for _ in 0..<6 where passwordOffer.exists {
            passwordOffer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: passwordOffer)
            _ = XCTWaiter.wait(for: [dismissed], timeout: 2)
        }
        XCTAssertFalse(passwordOffer.exists, "The system password offer could not be declined")
    }

    /// Rows created by this test on any fixture port, including leftovers from
    /// an interrupted earlier run. The name is unique to this test.
    private func anyFixtureRows(_ app: XCUIApplication, name: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@ AND value BEGINSWITH %@",
            "sshProfileRow-", name, "fixture@127.0.0.1:"))
    }

    private func fixtureRows(_ app: XCUIApplication, name: String, port: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            // A host that disconnected while the app was open says so after its address.
            format: "identifier BEGINSWITH %@ AND label == %@ AND (value == %@ OR value BEGINSWITH %@)",
            "sshProfileRow-", name, "fixture@127.0.0.1:\(port)", "fixture@127.0.0.1:\(port)，"))
    }

    /// Removes rows with this test's unique name. A row's pin is removed only
    /// when its loopback authority shows `expectedFingerprint`, or, with
    /// `anyLoopbackPin` (explicit leftover recovery), whatever pin that row's
    /// own `[127.0.0.1]:port` authority shows. Returns nil on success, or why
    /// it stopped so the remaining data can be cleaned explicitly.
    private func cleanupFixtures(_ app: XCUIApplication, name: String, expectedFingerprint: String?,
                                 anyLoopbackPin: Bool = false) -> String? {
        let deadline = Date().addingTimeInterval(90)
        for _ in 0..<10 {
            guard Date() < deadline else { return "timed out" }
            let row = anyFixtureRows(app, name: name).firstMatch
            guard row.exists else { return nil }
            let identifier = row.identifier
            let suffix = String(identifier.dropFirst("sshProfileRow-".count))
            guard UUID(uuidString: suffix) != nil else { return "unexpected row identifier" }
            // The address may be followed by its state, such as "，已断开".
            let address = (row.value as? String ?? "").components(separatedBy: "，").first ?? ""
            let rowPort = address.components(separatedBy: ":").last ?? ""
            guard Int(rowPort) != nil else { return "unexpected row value" }
            let menu = app.buttons["sshProfileActions-\(suffix)"]

            guard tapIfVisible(menu, in: app) else { return "actions menu not visible" }
            let keyAction = app.buttons["主机密钥"]
            guard keyAction.waitForExistence(timeout: 3) else { return "host keys action missing" }
            keyAction.tap()
            guard app.staticTexts["[127.0.0.1]:\(rowPort)"].waitForExistence(timeout: 5) else { return "host keys view missing authority" }
            let absent = app.staticTexts["未记住此主机密钥"]
            let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch
            if remove.waitForExistence(timeout: 3) {
                if !anyLoopbackPin {
                    guard let expectedFingerprint,
                          app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedFingerprint)).firstMatch.exists
                    else { return "row \(rowPort) has an unexpected pin" }
                }
                guard tapIfVisible(remove, in: app) else { return "remove trust not visible" }
                let confirmation = app.alerts["移除主机信任？"]
                guard confirmation.waitForExistence(timeout: 3) else { return "remove trust confirmation missing" }
                confirmation.buttons["移除信任"].firstMatch.tap()
                guard absent.waitForExistence(timeout: 5) else { return "pin still present" }
            } else if !absent.waitForExistence(timeout: 2) {
                return "pin state unknown"
            }
            guard tapIfVisible(app.buttons["完成"], in: app) else { return "host keys Done not visible" }
            guard app.buttons["newSSHProfile"].waitForExistence(timeout: 5) else { return "host list did not return" }

            guard tapIfVisible(menu, in: app) else { return "actions menu not visible for delete" }
            // Chinese once the catalog has the new key, English until then.
            let deletion = app.buttons.matching(NSPredicate(format: "label IN %@", ["删除主机", "Delete Host"])).firstMatch
            guard deletion.waitForExistence(timeout: 3) else { return "delete action missing" }
            // Deletion is immediate and offers Undo instead of a confirmation.
            deletion.tap()
            guard app.buttons["sshUndoRemove"].waitForExistence(timeout: 5) else { return "undo offer missing" }
            let deletedRow = app.buttons[identifier]
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: deletedRow)
            guard XCTWaiter.wait(for: [gone], timeout: 5) == .completed else { return "row was not deleted" }
        }
        return anyFixtureRows(app, name: name).firstMatch.exists ? "rows remain" : nil
    }

    @discardableResult private func tapIfVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 3) else { return false }
        let frame = element.frame
        guard !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite,
              app.windows.firstMatch.frame.contains(frame) else { return false }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }
}
