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
        app.launchArguments = ["--witerm-ui-test-steady-terminal-cursor"]
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sshTab = app.tabBars.buttons["SSH"]
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
        password.tap(); password.typeText("witerm-fixture-only")
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
        tapVisibleControl(app.buttons["sshKeyboard"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard control must focus the real SSH input view")
        let marker = "~$ z"
        XCTAssertFalse((terminal.value as? String ?? terminal.label).contains(marker))
        // The terminal's separate AX reading view intentionally hides its input
        // view. Use a real software key instead of app.typeText's AX-focus search.
        let character = app.keyboards.keys["z"].firstMatch
        XCTAssertTrue(character.waitForExistence(timeout: 5))
        character.tap()
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", marker, marker),
            object: terminal)
        wait(for: [rendered], timeout: 10)
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
        app.launchArguments = ["--witerm-ui-test-steady-terminal-cursor"]
        // Optional text size, e.g. UICTContentSizeCategoryAccessibilityL, for layout review.
        if let size = environment["WITERM_UI_CONTENT_SIZE"] {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sshTab = app.tabBars.buttons["SSH"]
        XCTAssertTrue(sshTab.waitForExistence(timeout: 10))
        sshTab.tap()

        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        connectNewHost(app, name: firstName, port: firstPort, fingerprint: firstPin)
        // Leave a marker in the first session's live line.
        tapVisibleControl(app.buttons["sshKeyboard"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.keyboards.keys["z"].firstMatch.tap()
        let marker = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "~$ z", "~$ z"), object: terminal)
        wait(for: [marker], timeout: 10)

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
        password.tap(); password.typeText("witerm-fixture-only")
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
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sshTab = app.tabBars.buttons["SSH"]
        XCTAssertTrue(sshTab.waitForExistence(timeout: 10))
        sshTab.tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        // Every fixture name these tests use; each is unique to them.
        for name in ["SSH 验收 iOS 1026", "SSH 验收 iOS 双会话 A", "SSH 验收 iOS 双会话 B"] {
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
            format: "identifier BEGINSWITH %@ AND label == %@ AND value == %@",
            "sshProfileRow-", name, "fixture@127.0.0.1:\(port)"))
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
            let rowPort = (row.value as? String ?? "").components(separatedBy: ":").last ?? ""
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
            let deletion = app.buttons["删除连接"]
            guard deletion.waitForExistence(timeout: 3) else { return "delete action missing" }
            deletion.tap()
            let confirmation = app.alerts["删除 SSH 连接？"]
            guard confirmation.waitForExistence(timeout: 3) else { return "delete confirmation missing" }
            confirmation.buttons["删除"].firstMatch.tap()
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
