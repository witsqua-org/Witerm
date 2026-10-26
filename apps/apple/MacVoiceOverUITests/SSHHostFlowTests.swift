import XCTest

/// Opt-in Mac acceptance of the sidebar SSH flow against explicitly configured
/// disposable OpenSSH fixtures. Only hosts this test creates are connected,
/// inspected, and removed; other saved hosts are never touched.
@MainActor final class SSHHostFlowTests: XCTestCase {
    private struct Fixture {
        let port: String
        let fingerprint: String
        var name: String { "SSH Mac Fixture \(port)" }
    }

    private func configuration() throws -> (path: String, first: Fixture, second: Fixture?) {
        let environment = ProcessInfo.processInfo.environment
        func fixture(_ portKey: String, _ fingerprintKey: String) -> Fixture? {
            guard let port = environment[portKey], let number = Int(port), (1...65535).contains(number),
                  let fingerprint = environment[fingerprintKey], fingerprint.hasPrefix("SHA256:") else { return nil }
            return Fixture(port: port, fingerprint: fingerprint)
        }
        guard let path = environment["WITERM_SSH_MAC_APP_PATH"],
              let first = fixture("WITERM_SSH_UI_PORT", "WITERM_SSH_UI_FINGERPRINT") else {
            throw XCTSkip("Configure a disposable SSH fixture and the signed Mac app explicitly")
        }
        return (path, first, fixture("WITERM_SSH_UI_SECOND_PORT", "WITERM_SSH_UI_SECOND_FINGERPRINT"))
    }

    private func launch(_ path: String) -> XCUIApplication {
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        addTeardownBlock { await MainActor.run { app.terminate() } }
        // English keeps field lookups independent of translation wording.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    func testCreateTrustConnectAndRemoveFixtureHost() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let (path, fixture, _) = try configuration()
        let app = launch(path)
        let suffix = connectNewHost(fixture, in: app)
        capture(app, "mac-ssh-terminal")
        app.buttons["sshDisconnect"].click()
        XCTAssertTrue(app.buttons["sshConnectProfile"].waitForExistence(timeout: 10))
        capture(app, "mac-ssh-host")
        removeHost(suffix: suffix, fixture: fixture, in: app)
        app.typeKey("q", modifierFlags: .command)
    }

    /// Two hosts stay connected at once; switching keeps each session's
    /// output and input, and disconnecting one leaves the other running.
    func testTwoHostsStayConnectedAcrossSelection() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let (path, first, configuredSecond) = try configuration()
        guard let second = configuredSecond else { throw XCTSkip("Configure a second disposable SSH fixture") }
        let app = launch(path)

        let firstID = connectNewHost(first, in: app)
        run("echo first-$((6*7))", expect: "first-42", in: app)
        let secondID = connectNewHost(second, in: app)
        run("echo second-$((7*8))", expect: "second-56", in: app)
        XCTAssertTrue(row(first, in: app).value.map { "\($0)" }?.contains("connected") == true,
                      "The first host must stay connected while the second is shown")
        capture(app, "mac-ssh-two-sessions")

        // Return to the first host: its earlier output is still there and it
        // still executes input.
        row(first, in: app).click()
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        waitFor(terminal, contains: "first-42")
        run("echo again-$((5*9))", expect: "again-45", in: app)
        capture(app, "mac-ssh-first-again")

        app.buttons["sshDisconnect"].click()
        XCTAssertTrue(app.buttons["sshConnectProfile"].waitForExistence(timeout: 10))
        XCTAssertTrue(row(second, in: app).value.map { "\($0)" }?.contains("connected") == true,
                      "Disconnecting one host must leave the other connected")
        row(second, in: app).click()
        waitFor(terminal, contains: "second-56")
        app.buttons["sshDisconnect"].click()
        XCTAssertTrue(app.buttons["sshConnectProfile"].waitForExistence(timeout: 10))

        removeHost(suffix: firstID, fixture: first, in: app)
        removeHost(suffix: secondID, fixture: second, in: app)
        app.typeKey("q", modifierFlags: .command)
    }

    // MARK: Steps

    private func row(_ fixture: Fixture, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", fixture.name)).firstMatch
    }

    /// Creates the fixture host from the menu shortcut, verifies its key, and
    /// waits for a shell prompt. Returns the host's identifier suffix.
    private func connectNewHost(_ fixture: Fixture, in app: XCUIApplication) -> String {
        XCTAssertFalse(row(fixture, in: app).exists, "A host with the fixture name already exists; refusing to touch it")
        app.typeKey("n", modifierFlags: [.command, .shift])
        let name = app.textFields["sshProfileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText(fixture.name)
        // The target host's fields come first; jump hosts follow.
        let host = app.textFields.matching(identifier: "sshHostAddress").firstMatch
        host.click(); host.typeText("127.0.0.1")
        let portField = app.textFields.matching(identifier: "sshHostPort").firstMatch
        portField.click(); portField.typeKey("a", modifierFlags: .command); portField.typeText(fixture.port)
        let username = app.textFields.matching(identifier: "sshHostUsername").firstMatch
        username.click(); username.typeText("fixture")
        let password = app.secureTextFields.matching(identifier: "sshHostPassword").firstMatch
        password.click(); password.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].click()

        let identity = app.staticTexts["sshHostFingerprint"]
        XCTAssertTrue(identity.waitForExistence(timeout: 15))
        XCTAssertTrue(identity.label.contains(fixture.fingerprint) || (identity.value as? String ?? "").contains(fixture.fingerprint),
                      "Unexpected fixture host fingerprint")
        app.buttons["sshTrustHost"].click()

        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        waitFor(terminal, contains: "$ ")
        let created = row(fixture, in: app)
        XCTAssertTrue(created.exists)
        let suffix = String(created.identifier.dropFirst("sshProfileRow-".count))
        XCTAssertNotNil(UUID(uuidString: suffix))
        return suffix
    }

    private func run(_ command: String, expect output: String, in app: XCUIApplication) {
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.click()
        app.typeText(command + "\n")
        waitFor(terminal, contains: output)
    }

    private func waitFor(_ terminal: XCUIElement, contains text: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text), object: terminal)
        wait(for: [expectation], timeout: 15)
    }

    /// Removes this run's trust entry and host only.
    private func removeHost(suffix: String, fixture: Fixture, in app: XCUIApplication) {
        let created = app.descendants(matching: .any)["sshProfileRow-\(suffix)"].firstMatch
        created.click()
        let menu = app.descendants(matching: .any)["sshProfileActions-\(suffix)"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        app.menuItems["Host Keys"].click()
        let pin = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", fixture.fingerprint, fixture.fingerprint)).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch.click()
        app.buttons["sshConfirmForgetHostKey"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No Saved Host Key"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.click()
        menu.click()
        app.menuItems["Delete Connection"].click()
        app.windows.descendants(matching: .button).matching(NSPredicate(format: "label == %@", "Delete")).firstMatch.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: created)
        wait(for: [removed], timeout: 5)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
