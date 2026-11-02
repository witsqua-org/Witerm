import XCTest

/// Opt-in evidence for the iOS UI/UX audit (`docs/design/audit-ios.md`).
/// Writes screenshots to WITERM_AUDIT_DIR in several variants (language,
/// appearance, text size). Changes nothing it doesn't remove again: the one
/// host it saves is deleted, invitations are generated locally and never
/// sent, and the relay server address is unreachable on purpose.
///
/// `testAuditLiveSSH` also needs the disposable OpenSSH fixture
/// (WITERM_SSH_UI_PORT and WITERM_SSH_UI_FINGERPRINT); it removes its host
/// and the host's pinned key at the end.
@MainActor final class AuditScreenshotTests: XCTestCase {
    private struct Variant {
        let name: String
        let language: String
        let locale: String
        let dark: Bool
        let largestText: Bool
    }

    private let variants = [
        Variant(name: "en-light", language: "en", locale: "en_US", dark: false, largestText: false),
        Variant(name: "en-dark", language: "en", locale: "en_US", dark: true, largestText: false),
        Variant(name: "en-ax5", language: "en", locale: "en_US", dark: false, largestText: true),
        Variant(name: "zh-light", language: "zh-Hans", locale: "zh_CN", dark: false, largestText: false),
        Variant(name: "zh-ax5-dark", language: "zh-Hans", locale: "zh_CN", dark: true, largestText: true),
    ]

    private var root: URL!
    private var folder: URL!
    private var app: XCUIApplication!
    private var originalAppearance: XCUIDevice.Appearance = .light

    override func setUp() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WITERM_AUDIT_DIR"] else {
            throw XCTSkip("Set WITERM_AUDIT_DIR")
        }
        root = URL(fileURLWithPath: directory)
        originalAppearance = XCUIDevice.shared.appearance
    }

    override func tearDown() async throws {
        app?.terminate()
        XCUIDevice.shared.appearance = originalAppearance
    }

    // MARK: Helpers

    private func shot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? image.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func launch(_ variant: Variant, tour: Bool = false) {
        app?.terminate()
        XCUIDevice.shared.appearance = variant.dark ? .dark : .light
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", tour ? "0" : "1",
                               // Unreachable on purpose: nothing is ever sent there.
                               "-witerm.serverAddresses", "(\"http://localhost:37429\")",
                               "-AppleLanguages", "(\(variant.language))", "-AppleLocale", variant.locale,
                               "--witerm-ui-test-steady-terminal-cursor"]
        if variant.largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
    }

    private func tab(_ index: Int) {
        let button = app.tabBars.buttons.element(boundBy: index)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    /// Scrolls until the element can be tapped, then taps it.
    private func reveal(_ element: XCUIElement, tap: Bool = true) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)")
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        if tap { element.tap() }
    }

    private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.waitForExistence(timeout: 3) { button.tap() }
    }

    private func link(_ host: String, _ items: [(String, String)]) -> String {
        var parts = URLComponents()
        parts.scheme = "witerm"
        parts.host = host
        parts.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.string!
    }

    // MARK: Screens without a network

    func testAuditScreens() throws {
        continueAfterFailure = true
        executionTimeAllowance = 1800
        for variant in variants {
            folder = root.appendingPathComponent(variant.name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            XCTContext.runActivity(named: variant.name) { _ in capture(variant) }
        }
    }

    private func capture(_ v: Variant) {
        // Welcome Tour, all three pages.
        launch(v, tour: true)
        if app.buttons["welcomeTourNext"].waitForExistence(timeout: 10) {
            shot("01-tour-1")
            app.buttons["welcomeTourNext"].tap(); shot("02-tour-2")
            app.buttons["welcomeTourNext"].tap(); shot("03-tour-3")
        }

        // The three tabs, empty.
        launch(v)
        tab(0); shot("04-terminals-empty")
        tab(1)
        _ = app.buttons["continueFromDevice"].waitForExistence(timeout: 10)
        shot("05-devices-empty")
        tab(2)
        _ = app.buttons["settingsServers"].waitForExistence(timeout: 10)
        shot("06-settings")
        reveal(app.buttons["settingsDisplay"]); shot("07-settings-text-colors")
        app.swipeUp(); shot("07b-settings-text-colors-scrolled")
        back()
        reveal(app.buttons["settingsFeedback"]); shot("08-settings-bell"); back()
        reveal(app.buttons["mobileKeyRowSettings"]); shot("09-settings-keyboard-row"); back()
        reveal(app.buttons["snippetSettings"]); shot("10-settings-snippets")
        if app.buttons["addSnippet"].waitForExistence(timeout: 3) {
            app.buttons["addSnippet"].tap(); shot("10b-snippet-editor")
        }
        launch(v)
        tab(2)
        reveal(app.buttons["settingsServers"]); shot("11-relay-servers")
        let row = app.buttons["settingsServerRow-0"]
        if row.waitForExistence(timeout: 5) {
            row.tap(); RunLoop.current.run(until: Date().addingTimeInterval(2)); shot("12-relay-server-page")
            back()
        }
        if app.buttons["settingsAddServer"].waitForExistence(timeout: 5) {
            app.buttons["settingsAddServer"].tap(); shot("13-add-relay-server")
        }

        // Add Device: camera step, typing, and the check screen.
        launch(v)
        tab(1)
        reveal(app.buttons["continueFromDevice"])
        _ = app.buttons["pasteInvitation"].waitForExistence(timeout: 5)
        shot("14-add-device")
        reveal(app.buttons["typeInvitation"])
        let field = app.descendants(matching: .any)["sessionInvitationField"].firstMatch
        if field.waitForExistence(timeout: 5) {
            shot("15-add-device-typing")
            field.typeText("not an invitation")
            reveal(app.buttons["preparePairing"])
            shot("16-add-device-invalid")
        }
        launch(v)
        tab(1)
        reveal(app.buttons["continueFromDevice"])
        reveal(app.buttons["typeInvitation"])
        if field.waitForExistence(timeout: 5) {
            field.typeText(link("pair", [("server", "https://other-server.example.com"),
                                         ("id", "00000000-0000-4000-8000-000000000082"),
                                         ("secret", String(repeating: "A", count: 43)),
                                         ("host_key", Data(repeating: 1, count: 32).base64EncodedString())]))
            reveal(app.buttons["preparePairing"])
            if app.buttons["joinPairing"].waitForExistence(timeout: 5) { shot("17-add-device-check") }
        }

        // The SSH form: empty, parsed address, private key, and more options.
        launch(v)
        tab(0)
        reveal(app.buttons["newSSHProfile"])
        let address = app.textFields["sshHostAddress"]
        if address.waitForExistence(timeout: 5) {
            shot("18-ssh-form-empty")
            address.tap(); address.typeText("deploy@build.example.invalid:2222")
            shot("19-ssh-form-address")
            let auth = app.segmentedControls["sshAuthentication"].buttons.element(boundBy: 1)
            if auth.waitForExistence(timeout: 3) { reveal(auth); shot("20-ssh-form-private-key") }
            reveal(app.buttons["sshMoreOptions"]); shot("21-ssh-form-more-options")
            // At accessibility sizes the pinned Connect / Save for Later bar
            // can sit over a field the scroll reported as hittable; leave by
            // Cancel so nothing is saved by accident.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // A saved host: Terminals, its actions, Devices, then delete it.
        launch(v)
        tab(0)
        let name = "Audit host " + String(UUID().uuidString.prefix(4))
        reveal(app.buttons["newSSHProfile"])
        guard address.waitForExistence(timeout: 5) else { return }
        address.tap(); address.typeText("audit@example.invalid")
        reveal(app.buttons["sshMoreOptions"])
        let nameField = app.textFields["sshProfileName"]
        reveal(nameField); nameField.typeText(name)
        reveal(app.buttons["sshSaveOnly"])
        let host = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        guard host.waitForExistence(timeout: 5) else { return }
        shot("22-terminals-one-host")
        let id = String(host.identifier.dropFirst("sshProfileRow-".count))
        let menu = app.buttons["sshProfileActions-" + id]
        menu.tap(); shot("23-host-actions")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        tab(1); RunLoop.current.run(until: Date().addingTimeInterval(1)); shot("24-devices-one-host")
        tab(0)
        menu.tap()
        let delete = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete Host", "删除主机"])).firstMatch
        if delete.waitForExistence(timeout: 3) {
            delete.tap()
            if app.buttons["sshUndoRemove"].waitForExistence(timeout: 5) { shot("25-host-deleted-undo") }
        }
    }

    /// Removes hosts this test class may have left after an interrupted run:
    /// only its own names, never anything else.
    func testAuditCleanup() throws {
        guard ProcessInfo.processInfo.environment["WITERM_AUDIT_CLEANUP"] == "1" else {
            throw XCTSkip("Explicit cleanup only")
        }
        launch(variants[0])
        tab(0)
        let ours = NSPredicate(format: "identifier BEGINSWITH %@ AND (label BEGINSWITH %@ OR label BEGINSWITH %@ OR label == %@)",
                               "sshProfileRow-", "Audit host ", "Audit SSH ", "deploy@build.example.invalid")
        // A fixture host's pin is removed only when it is the fixture's.
        let fingerprint = ProcessInfo.processInfo.environment["WITERM_SSH_UI_FINGERPRINT"]
        for _ in 0..<10 {
            let row = app.buttons.matching(ours).firstMatch
            guard row.waitForExistence(timeout: 3) else { break }
            let id = String(row.identifier.dropFirst("sshProfileRow-".count))
            let actions = app.buttons["sshProfileActions-" + id]
            if let fingerprint, row.label.hasPrefix("Audit SSH ") {
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
            }
            actions.tap()
            let delete = app.buttons["Delete Host"]
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            delete.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        tab(2)
        reveal(app.buttons["snippetSettings"])
        for _ in 0..<3 {
            let snippetRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.snippet)).firstMatch
            guard snippetRow.waitForExistence(timeout: 3) else { break }
            snippetRow.tap()
            let deleteSnippet = app.buttons["Delete Snippet"]
            if deleteSnippet.waitForExistence(timeout: 3) { deleteSnippet.tap() }
        }
    }

    // MARK: A live SSH terminal (disposable fixture only)

    func testAuditLiveSSH() throws {
        continueAfterFailure = true
        executionTimeAllowance = 900
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        folder = root.appendingPathComponent("ssh-live")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let light = variants[0]
        let name = "Audit SSH " + String(UUID().uuidString.prefix(4))
        launch(light)
        // A snippet produces output without typing into the terminal (XCTest
        // can't focus a terminal's input view); it is deleted at the end.
        tab(2)
        reveal(app.buttons["snippetSettings"])
        reveal(app.buttons["addSnippet"])
        let snippetName = app.textFields["snippetName"]
        if snippetName.waitForExistence(timeout: 5) {
            snippetName.tap(); snippetName.typeText(Self.snippet)
            let text = app.textViews["snippetText"]
            text.tap(); text.typeText("seq 1 120; ls -la /etc | head -40")
            let enter = app.switches.matching(NSPredicate(format: "label == %@", "Press Return After Inserting")).firstMatch
            if enter.waitForExistence(timeout: 3) {
                enter.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            }
            app.buttons["saveSnippet"].tap()
        }
        tab(0)
        reveal(app.buttons["newSSHProfile"])
        let address = app.textFields["sshHostAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("fixture@127.0.0.1:" + port)
        reveal(app.buttons["sshMoreOptions"])
        let nameField = app.textFields["sshProfileName"]
        reveal(nameField); nameField.typeText(name)
        let password = app.secureTextFields["sshHostPassword"]
        reveal(password); password.typeText("witerm-fixture-only")
        shot("01-form-filled")
        reveal(app.buttons["sshConnect"])
        declinePasswordOffer(timeout: 3)
        let identity = app.staticTexts["sshHostFingerprint"]
        if identity.waitForExistence(timeout: 10) {
            XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
            shot("02-trust-sheet")
            app.buttons["sshTrustHost"].tap()
        }
        let terminal = app.descendants(matching: .any)["sshTerminalSurface"].firstMatch
        guard terminal.waitForExistence(timeout: 15) else { return XCTFail("No terminal") }
        declinePasswordOffer(timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("03-terminal-connected-tip")
        if app.buttons["sshBackgroundTipDismiss"].exists { app.buttons["sshBackgroundTipDismiss"].tap() }
        let snippets = app.buttons["terminalKey-snippets"]
        if snippets.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !snippets.isHittable { app.buttons["terminalKey-escape"].swipeLeft() }
            snippets.tap()
            let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.snippet)).firstMatch
            if item.waitForExistence(timeout: 3) {
                shot("04a-snippet-menu")
                item.tap()
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("04-terminal-output-keyboard")
        app.buttons["sshKeyboard"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("05-terminal-keyboard-hidden")
        terminal.swipeDown(); terminal.swipeDown()
        shot("06-terminal-scrolled-back")
        terminal.press(forDuration: 0.6)
        shot("07-terminal-selection")
        terminal.tap()
        app.buttons["sshSessionActions"].tap()
        shot("08-terminal-actions-menu")
        if app.buttons["terminalFind"].waitForExistence(timeout: 3) {
            app.buttons["terminalFind"].tap()
            let find = app.textFields["terminalFindField"]
            if find.waitForExistence(timeout: 3) { find.typeText("passwd"); shot("09-terminal-find") }
            if app.buttons["terminalFindDone"].exists { app.buttons["terminalFindDone"].tap() }
        }
        XCUIDevice.shared.appearance = .dark
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("10-terminal-dark")
        XCUIDevice.shared.appearance = .light
        app.buttons["sshShowHosts"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("11-terminals-open-card")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        let id = String(row.identifier.dropFirst("sshProfileRow-".count))
        let menu = app.buttons["sshProfileActions-" + id]
        menu.tap(); shot("12-open-host-actions")
        let disconnect = app.buttons.matching(NSPredicate(format: "label == %@", "Disconnect")).firstMatch
        if disconnect.waitForExistence(timeout: 3) { disconnect.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("13-after-disconnect")

        // The same host at the largest text size: tapping it asks for the password again.
        launch(variants[2])
        tab(0)
        let large = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        if large.waitForExistence(timeout: 8) {
            shot("14-ax5-terminals-host")
            reveal(large)
            let again = app.secureTextFields["sshHostPassword"]
            if again.waitForExistence(timeout: 8) {
                shot("15-ax5-connect-form")
                reveal(again); again.typeText("witerm-fixture-only")
                reveal(app.buttons["sshConnect"])
                declinePasswordOffer(timeout: 3)
                if terminal.waitForExistence(timeout: 15) {
                    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                    shot("16-ax5-terminal")
                    app.buttons["sshSessionActions"].tap(); shot("17-ax5-actions-menu")
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    app.buttons["sshShowHosts"].tap()
                }
            }
        }

        // Clean up: the pinned key, then the host.
        launch(light)
        tab(0)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        guard saved.waitForExistence(timeout: 8) else { return XCTFail("Host to clean up is missing") }
        let savedID = String(saved.identifier.dropFirst("sshProfileRow-".count))
        let actions = app.buttons["sshProfileActions-" + savedID]
        actions.tap()
        app.buttons["Host Keys"].tap()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch
        if remove.waitForExistence(timeout: 5) {
            shot("18-host-keys")
            let fixturePin = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", fingerprint)).firstMatch.exists
            XCTAssertTrue(fixturePin, "Refusing to remove a pin that isn't the fixture's")
            if fixturePin {
                remove.tap()
                let confirm = app.buttons["sshConfirmForgetHostKey"].firstMatch
                if confirm.waitForExistence(timeout: 3) { confirm.tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
        }
        app.buttons["Done"].tap()
        actions.tap()
        app.buttons["Delete Host"].tap()
        XCTAssertTrue(app.buttons["sshUndoRemove"].waitForExistence(timeout: 5))

        // And the snippet.
        tab(2)
        reveal(app.buttons["snippetSettings"])
        let snippetRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.snippet)).firstMatch
        if snippetRow.waitForExistence(timeout: 5) {
            snippetRow.tap()
            let deleteSnippet = app.buttons["Delete Snippet"]
            if deleteSnippet.waitForExistence(timeout: 3) { deleteSnippet.tap() }
        }
    }

    private static let snippet = "Audit output"

    private func declinePasswordOffer(timeout: TimeInterval) {
        let offer = app.buttons["Not Now"]
        guard offer.waitForExistence(timeout: timeout) else { return }
        for _ in 0..<6 where offer.exists {
            offer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: offer)],
                               timeout: 2)
        }
    }
}
