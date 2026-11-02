import XCTest

/// Saved SSH credentials need Face ID, against the disposable OpenSSH
/// fixture only. The simulator's Face ID is driven from the host: the test
/// writes `match` or `nomatch` into WITERM_FACEID_SIGNALS and a helper posts
/// the matching `com.apple.BiometricKit_Sim.pearl.*` notification.
/// Enroll Face ID first (`notifyutil -s com.apple.BiometricKit.enrollmentChanged 1`).
/// The test removes its host and the fixture's pin at the end.
@MainActor final class SSHSavedCredentialTests: XCTestCase {
    private var app: XCUIApplication!
    private var signals: URL!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var cleanup: (name: String, fingerprint: String)?

    override func tearDown() async throws {
        if let cleanup { cleanUp(name: cleanup.name, fingerprint: cleanup.fingerprint) }
        try await super.tearDown()
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "--witerm-ui-test-steady-terminal-cursor"]
        app.launch()
    }

    private func signal(_ name: String) {
        try? Data().write(to: signals.appendingPathComponent(name))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_AUDIT_DIR"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("faceid")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url.appendingPathComponent(name + ".png"))
        }
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)")
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        element.tap()
    }

    private func declinePasswordOffer() {
        let offer = app.buttons["Not Now"]
        if offer.waitForExistence(timeout: 1) { offer.tap() }
    }

    private func row(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
    }

    private func disconnect(_ name: String) {
        let id = String(row(name).identifier.dropFirst("sshProfileRow-".count))
        app.buttons["sshProfileActions-" + id].tap()
        app.buttons["Disconnect"].tap()
    }

    func testSavedCredentialsNeedFaceIDOncePerConnection() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:"),
              let folder = environment["WITERM_FACEID_SIGNALS"] else {
            throw XCTSkip("Configure the SSH fixture and WITERM_FACEID_SIGNALS explicitly")
        }
        signals = URL(fileURLWithPath: folder)
        let name = "Saved SSH " + String(UUID().uuidString.prefix(4))
        launch()
        cleanup = (name, fingerprint)

        // Save the password: the form says what protects it.
        app.tabBars.buttons.element(boundBy: 0).tap()
        reveal(app.buttons["newSSHProfile"])
        let address = app.textFields["sshHostAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(address.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "A new host starts at its address")
        address.typeText("fixture@127.0.0.1:" + port)
        reveal(app.buttons["sshMoreOptions"])
        let nameField = app.textFields["sshProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        let middle = app.windows.firstMatch.frame.midY
        for _ in 0..<4 where !nameField.isHittable || nameField.frame.maxY > middle { app.swipeUp() }
        nameField.tap(); nameField.typeText(name)
        let password = app.secureTextFields["sshHostPassword"]
        let bar = app.navigationBars.firstMatch
        for _ in 0..<4 where !password.isHittable || (bar.exists && password.frame.minY < bar.frame.maxY + 8) {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        }
        password.tap(); password.typeText("witerm-fixture-only")
        let save = app.switches["Save Credentials on This Device"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let line = app.staticTexts["sshCredentialProtection"]
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        XCTAssertEqual(line.label, "Face ID protects them.")
        shot("01-save-face-id")
        reveal(app.buttons["sshConnect"])
        declinePasswordOffer()
        let identity = app.staticTexts["sshHostFingerprint"]
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        // The trust sheet can follow the system's password offer.
        for _ in 0..<20 where !terminal.exists {
            if identity.exists {
                XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
                app.buttons["sshTrustHost"].tap()
                break
            }
            declinePasswordOffer()
        }
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "The first connection didn't open")
        declinePasswordOffer()
        app.buttons["sshShowHosts"].tap()
        disconnect(name)

        // Reconnecting asks for Face ID once, then connects.
        XCTAssertTrue(row(name).waitForExistence(timeout: 5))
        row(name).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("02-face-id-prompt")
        signal("match")
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "Face ID match didn't connect")
        XCTAssertFalse(app.secureTextFields["sshHostPassword"].exists, "A match must not ask for the password")
        shot("03-connected-after-match")
        app.buttons["sshShowHosts"].tap()
        disconnect(name)

        // No match, then Enter Password: the form, no error, the saved one kept.
        row(name).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        signal("nomatch")
        let enterPassword = springboard.buttons["Enter Password"]
        XCTAssertTrue(enterPassword.waitForExistence(timeout: 10), "No match must offer Enter Password")
        shot("04-no-match")
        enterPassword.tap()
        XCTAssertTrue(app.secureTextFields["sshHostPassword"].waitForExistence(timeout: 10), "Enter Password must open the form")
        XCTAssertFalse(app.descendants(matching: .any)["sshIssue"].exists, "Falling back is not an error")
        shot("05-enter-password")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Cancelling: no error banner, and the saved credential still works.
        row(name).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        signal("nomatch")
        let cancel = springboard.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.descendants(matching: .any)["sshIssue"].exists, "Cancelling Face ID is not an error")
        if app.secureTextFields["sshHostPassword"].waitForExistence(timeout: 3) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        row(name).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        signal("match")
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "The saved credential must survive a cancelled attempt")
        app.buttons["sshShowHosts"].tap()
    }

    /// Deletes the host and, only when it's the fixture's, its pinned key.
    private func cleanUp(name: String, fingerprint: String) {
        launch()
        app.tabBars.buttons.element(boundBy: 0).tap()
        let saved = row(name)
        guard saved.waitForExistence(timeout: 8) else { return }
        let id = String(saved.identifier.dropFirst("sshProfileRow-".count))
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
        // Past the undo window, so the protected credential is removed too.
        let dismiss = app.buttons["sshUndoDismiss"]
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
    }
}
