import XCTest

@MainActor
final class ConnectionFlowTests: XCTestCase {
    /// The saved server list as a launch argument; an empty address means none.
    private func serverList(_ addresses: [String]) -> [String] {
        ["-witerm.serverAddresses", "(" + addresses.map { "\"\($0)\"" }.joined(separator: ", ") + ")"]
    }

    private func launchApp(address: String = "", language: String = "zh-Hans", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = serverList(address.isEmpty ? [] : [address])
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launchArguments += extra
        app.launch()
        return app
    }

    private func openDevices(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    private func openSettings(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    /// Settings → Continuation Servers, which lists one row per server.
    private func openServers(_ app: XCUIApplication) {
        openSettings(app)
        let servers = app.buttons["settingsServers"]
        XCTAssertTrue(servers.waitForExistence(timeout: 10))
        servers.tap()
    }

    private func openServer(_ app: XCUIApplication, index: Int = 0) {
        let row = app.buttons["settingsServerRow-\(index)"]
        if !row.waitForExistence(timeout: 2) { openServers(app) }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    /// Devices → Continue from Another Device, typing the invitation.
    private func openContinue(_ app: XCUIApplication, typing invitation: String? = nil) {
        openDevices(app)
        let start = app.buttons["continueFromDevice"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["pasteInvitation"].waitForExistence(timeout: 10))
        guard let invitation else { return }
        app.buttons["typeInvitation"].tap()
        let field = app.descendants(matching: .any)["sessionInvitationField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(invitation)
        app.buttons["preparePairing"].tap()
    }

    private func pairingLink(server: String, id: String) -> String {
        var parts = URLComponents()
        parts.scheme = "witerm"
        parts.host = "pair"
        parts.queryItems = [
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "secret", value: String(repeating: "A", count: 43)),
            URLQueryItem(name: "host_key", value: Data(repeating: 1, count: 32).base64EncodedString())
        ]
        return parts.string!
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The address field says what it understood and turns an SSH login into
    /// a way to add an SSH host, instead of a generic format error.
    func testAddressEntryExplainsAndFixes() {
        let app = launchApp()
        openServers(app)
        let add = app.buttons["settingsEditServer"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let field = app.textFields["serverAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("deploy@build.example.com")
        XCTAssertTrue(app.descendants(matching: .any)["addressValidationError"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["serverAddressAddSSH"].exists)
        XCTAssertFalse(app.buttons["saveServerAddress"].isEnabled)
        capture("02-ssh-login", app: app)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "deploy@build.example.com".count))
        field.typeText("test.witerm.dev")
        let understood = app.descendants(matching: .any)["serverAddressInterpretation"].firstMatch
        XCTAssertTrue(understood.waitForExistence(timeout: 5))
        XCTAssertTrue(understood.label.contains("https://test.witerm.dev"))
        XCTAssertTrue(app.buttons["saveServerAddress"].isEnabled)
        capture("02-understood", app: app)
        app.buttons["取消"].tap()
    }

    func testRealServerSuccess() {
        let app = launchApp(address: "http://localhost:37429")
        openDevices(app)
        XCTAssertTrue(app.buttons["continueFromDevice"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["remoteDevicesEmpty"].firstMatch.waitForExistence(timeout: 15))
        capture("03-devices", app: app)
        openServer(app)
        let feedback = app.descendants(matching: .any)["settingsConnectionFeedback"].firstMatch
        let success = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "服务器可以访问"), object: feedback)
        wait(for: [success], timeout: 10)
        capture("03-success", app: app)
    }

    func testDarkAppearance() {
        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let app = launchApp()
        XCTAssertTrue(app.buttons["firstUseContinue"].waitForExistence(timeout: 10))
        // The appearance change reaches the app asynchronously; capture only
        // once the rendered screen is actually dark.
        XCTAssertTrue(waitForDarkScreen(app), "The app did not render in dark appearance")
        capture("07-dark", app: app)
        openDevices(app)
        XCTAssertTrue(app.buttons["continueFromDevice"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDarkScreen(app))
        capture("07-dark-devices", app: app)
        openSettings(app)
        XCTAssertTrue(app.buttons["settingsDisplay"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDarkScreen(app))
        capture("07-dark-settings", app: app)
    }

    private func waitForDarkScreen(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if averageLuminance(app.screenshot().image) < 0.35 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return false
    }

    private func averageLuminance(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 1 }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        return total / Double(side * side) / 255
    }

    /// A refused connection says so and names the server.
    func testConnectionFailureHasRecovery() {
        let app = launchApp(address: "http://localhost:1")
        openServer(app)
        let check = app.buttons["settingsCheckConnection"]
        if check.waitForExistence(timeout: 10) { check.tap() }
        let feedback = app.descendants(matching: .any)["settingsConnectionFeedback"].firstMatch
        let failure = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "localhost:1"), object: feedback)
        wait(for: [failure], timeout: 15)
        capture("04-error", app: app)
    }

    func testCancelLoadingDoesNotBecomeSuccess() {
        // scripts/ui-test-server.py is deliberately slow; no demo state is
        // compiled into the app and cancellation uses the real URLSession task.
        // Usually the launch check is still running; if it already finished,
        // start a new one so the test never depends on launch timing.
        let app = launchApp(address: "http://localhost:18081")
        openServer(app)
        let cancel = app.buttons["cancelConnection"]
        if !cancel.waitForExistence(timeout: 2) {
            app.buttons["settingsCheckConnection"].tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        capture("05-loading", app: app)
        cancel.tap()
        XCTAssertTrue(app.buttons["settingsCheckConnection"].waitForExistence(timeout: 5))
        XCTAssertFalse(cancel.exists)
        let unexpectedSuccess = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "服务器可以访问"),
            object: app.descendants(matching: .any)["settingsConnectionFeedback"].firstMatch
        )
        unexpectedSuccess.isInverted = true
        wait(for: [unexpectedSuccess], timeout: 4)
    }

    func testAccessibilityLayout() {
        let app = launchApp(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openContinue(app)
        let paste = app.buttons["pasteInvitation"]
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        XCTAssertTrue(paste.isHittable)
        XCTAssertGreaterThanOrEqual(paste.frame.height, 44)
        capture("06-accessibility-type", app: app)
    }

    /// Two spellings of the local test server are two servers, each with its
    /// own identity: a duplicate is refused, and removing one leaves the other.
    func testSeveralServersAreUsedTogether() {
        let app = XCUIApplication()
        app.launchArguments = serverList(["http://localhost:37429", "http://127.0.0.1:37429"])
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openDevices(app)
        XCTAssertTrue(app.buttons["continueFromDevice"].waitForExistence(timeout: 15))
        capture("10-several-servers", app: app)

        openServers(app)
        XCTAssertTrue(app.buttons["settingsServerRow-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settingsServerRow-1"].exists)
        let add = app.buttons["settingsAddServer"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        capture("11-several-servers-settings", app: app)
        add.tap()
        let field = app.textFields["serverAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Another spelling of a saved server, with no scheme: the same server.
        field.typeText("LOCALHOST:37429")
        app.buttons["saveServerAddress"].tap()
        XCTAssertTrue(app.staticTexts["This server is already in your list."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        // Remove the second server from its own page; Settings returns to the list.
        openServer(app, index: 1)
        let remove = app.buttons["settingsRemoveServer"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        app.alerts.buttons["Remove"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.buttons["settingsServerRow-1"])
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.buttons["settingsServerRow-0"].exists)
    }

    func testMalformedInvitationCannotJoin() {
        let app = launchApp(address: "http://localhost:37429")
        openContinue(app, typing: "not-a-pairing-invitation")
        XCTAssertTrue(app.staticTexts["invitationProblem"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["joinPairing"].exists)
        capture("09-pairing-invalid", app: app)
    }

    func testScannerUnavailablePreservesPasteFlow() {
        let app = launchApp(address: "http://localhost:37429")
        openContinue(app)
        // The retained simulator has no camera: the flow still offers paste and typing.
        XCTAssertTrue(app.descendants(matching: .any)["pairingScannerUnavailable"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pasteInvitation"].exists)
        XCTAssertTrue(app.buttons["typeInvitation"].exists)
        capture("12-scanner-fallback", app: app)
    }

    /// An invitation naming a server you haven't added asks first and adds
    /// nothing until you tap; cancelling leaves the server list as it was.
    func testInvitationNeverSwitchesServerSilently() {
        let app = launchApp(address: "http://localhost:37429")
        openContinue(app, typing: pairingLink(server: "https://other-server.example.com", id: "00000000-0000-4000-8000-000000000001"))
        let request = app.buttons["joinPairing"]
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["other-server.example.com"].exists)
        capture("13-new-server", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["取消"].firstMatch.tap()
        openServers(app)
        XCTAssertTrue(app.buttons["settingsServerRow-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settingsServerRow-1"].exists, "The invitation added a server without asking")
    }

    func testReviewedInvitationSurvivesForegroundRefresh() {
        let app = launchApp(address: "http://localhost:37429")
        // Typed, so the check screen shows even though the server is saved.
        // Only review locally generated invitation text. Never submit a
        // pairing request or grant access to a real device in this test.
        openContinue(app, typing: pairingLink(server: "http://localhost:37429", id: "00000000-0000-4000-8000-000000000002"))
        let review = app.buttons["joinPairing"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isEnabled)
    }
}
