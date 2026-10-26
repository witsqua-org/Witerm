import XCTest

@MainActor
final class ConnectionFlowTests: XCTestCase {
    /// Launches without assuming which Devices tab state appears: a configured
    /// server is checked automatically, and a relay-capable one opens Devices.
    /// The saved server list as a launch argument; an empty address means none.
    private func serverList(_ addresses: [String]) -> [String] {
        ["-witerm.serverAddresses", "(" + addresses.map { "\"\($0)\"" }.joined(separator: ", ") + ")"]
    }

    private func launchApp(address: String = "") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = serverList(address.isEmpty ? [] : [address])
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    private func launch(address: String = "") -> XCUIApplication {
        let app = launchApp(address: address)
        XCTAssertTrue(app.buttons["primaryAction"].waitForExistence(timeout: 10))
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["设置"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEmptyStateAndAddressValidation() {
        let app = launch()
        XCTAssertTrue(app.buttons["primaryAction"].label.contains("添加服务器"))
        capture("01-empty", app: app)
        app.buttons["primaryAction"].tap()
        let field = app.textFields["serverAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://")
        app.buttons["saveServerAddress"].tap()
        XCTAssertTrue(app.staticTexts["addressValidationError"].waitForExistence(timeout: 5))
        capture("02-validation", app: app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["primaryAction"].label.contains("添加服务器"))
    }

    func testRealServerSuccess() {
        let app = launchApp(address: "http://localhost:8080")
        // The launch check succeeds and the relay-capable server opens Devices.
        XCTAssertTrue(app.buttons["refreshRemoteSessions"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["primaryAction"].exists)
        capture("03-macs", app: app)
        openSettings(app)
        let feedback = app.descendants(matching: .any)["settingsConnectionFeedback"].firstMatch
        let success = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "服务器可以访问"), object: feedback)
        wait(for: [success], timeout: 10)
        capture("03-success", app: app)
    }

    func testDarkAppearance() {
        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let app = launch()
        // The appearance change reaches the app asynchronously; capture only
        // once the rendered screen is actually dark.
        XCTAssertTrue(waitForDarkScreen(app), "The app did not render in dark appearance")
        capture("07-dark", app: app)
        app.tabBars.buttons["SSH"].tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDarkScreen(app))
        capture("07-dark-ssh", app: app)
        openSettings(app)
        XCTAssertTrue(app.buttons["settingsEditServer"].waitForExistence(timeout: 5))
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

    func testConnectionFailureHasRecovery() {
        let app = launch(address: "http://localhost:1")
        app.buttons["primaryAction"].tap()
        let feedback = app.descendants(matching: .any)["connectionFeedback"].firstMatch
        let failure = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "无法连接服务器"), object: feedback)
        wait(for: [failure], timeout: 15)
        XCTAssertTrue(feedback.label.contains("请确认地址、网络与服务器是否可用，然后重试。"))
        capture("04-error", app: app)
    }

    func testCancelLoadingDoesNotBecomeSuccess() {
        // scripts/ui-test-server.py is deliberately slow; no demo state is
        // compiled into the app and cancellation uses the real URLSession task.
        // Usually the launch check is still running; if it already finished,
        // start a new one so the test never depends on launch timing.
        let app = launch(address: "http://localhost:18081")
        let cancel = app.buttons["cancelConnection"]
        if !cancel.waitForExistence(timeout: 2) {
            app.buttons["primaryAction"].tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        capture("05-loading", app: app)
        cancel.tap()
        XCTAssertTrue(app.buttons["primaryAction"].isEnabled)
        XCTAssertFalse(cancel.exists)
        let unexpectedSuccess = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "服务器可以访问"),
            object: app.descendants(matching: .any)["connectionFeedback"].firstMatch
        )
        unexpectedSuccess.isInverted = true
        wait(for: [unexpectedSuccess], timeout: 4)
    }

    func testAccessibilityLayout() {
        let app = XCUIApplication()
        app.launchArguments = serverList([]) + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["primaryAction"].waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if app.buttons["primaryAction"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["primaryAction"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["primaryAction"].frame.height, 44)
        capture("06-accessibility-type", app: app)
    }

    /// Two spellings of the local test server are two servers, each with its
    /// own identity: both list their devices together, a duplicate is
    /// refused, and removing one leaves the other.
    func testSeveralServersAreUsedTogether() {
        let app = XCUIApplication()
        app.launchArguments = serverList(["http://localhost:8080", "http://127.0.0.1:8080"])
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["refreshRemoteSessions"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["localhost:8080"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["127.0.0.1:8080"].exists)
        let empty = app.descendants(matching: .any).matching(identifier: "remoteDevicesEmpty")
        let bothListed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: empty)
        wait(for: [bothListed], timeout: 20)
        capture("10-several-servers", app: app)

        // Settings is a lazily built form: rows exist only once scrolled to.
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["localhost:8080"].waitForExistence(timeout: 5))
        let add = app.buttons["settingsAddServer"]
        for _ in 0..<8 where !(add.exists && add.isHittable) { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["127.0.0.1:8080"].exists || app.buttons["settingsAddServer"].exists)
        capture("11-several-servers-settings", app: app)
        add.tap()
        let field = app.textFields["serverAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("http://LOCALHOST:8080/")
        app.buttons["saveServerAddress"].tap()
        XCTAssertTrue(app.staticTexts["This server is already in your list."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        // The remove button just above Add belongs to the second server.
        let removes = app.buttons.matching(identifier: "settingsRemoveServer")
        XCTAssertTrue(removes.firstMatch.waitForExistence(timeout: 5))
        removes.element(boundBy: removes.count - 1).tap()
        app.alerts.buttons["Remove"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.staticTexts["127.0.0.1:8080"])
        wait(for: [gone], timeout: 5)
        for _ in 0..<8 where !app.staticTexts["localhost:8080"].exists && !app.buttons["settingsCheckConnection"].isHittable { app.swipeDown() }
        // One server left: its section is no longer titled by host.
        XCTAssertFalse(app.staticTexts["localhost:8080"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "settingsRemoveServer").count, 1)
    }

    func testPairingRequiresVerifiedServer() {
        let app = launch(address: "http://localhost:1")
        openSettings(app)
        let entry = app.buttons["settingsDevicePairing"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        let failed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "无法连接服务器"),
            object: app.descendants(matching: .any)["settingsConnectionFeedback"].firstMatch)
        wait(for: [failed], timeout: 15)
        XCTAssertFalse(entry.isEnabled)
    }

    private func openPairing() -> XCUIApplication {
        let app = launchApp(address: "http://localhost:8080")
        openSettings(app)
        let entry = app.buttons["settingsDevicePairing"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: entry)
        wait(for: [enabled], timeout: 15)
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pairingInvitationField"].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    func testPairingCapabilityAndEmptyGrants() {
        let app = openPairing()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["还没有已授权的设备。"].waitForExistence(timeout: 5))
        capture("08-pairing-empty", app: app)
        app.buttons["closePairing"].tap()
        XCTAssertTrue(app.buttons["settingsDevicePairing"].waitForExistence(timeout: 5))
    }

    func testMalformedInvitationCannotJoin() {
        let app = openPairing()
        let field = app.descendants(matching: .any)["pairingInvitationField"].firstMatch
        field.tap()
        field.typeText("not-a-pairing-invitation")
        app.buttons["preparePairing"].tap()
        XCTAssertTrue(app.staticTexts["邀请格式不正确"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["joinPairing"].exists)
        XCTAssertTrue(field.exists)
        capture("09-pairing-invalid", app: app)
    }

    func testInvitationCannotSwitchServer() {
        let app = openPairing()
        var parts = URLComponents()
        parts.scheme = "witerm"
        parts.host = "pair"
        parts.queryItems = [
            URLQueryItem(name: "server", value: "https://other-server.example.com"),
            URLQueryItem(name: "id", value: "00000000-0000-4000-8000-000000000001"),
            URLQueryItem(name: "secret", value: String(repeating: "A", count: 43)),
            URLQueryItem(name: "host_key", value: Data(repeating: 1, count: 32).base64EncodedString())
        ]
        let field = app.descendants(matching: .any)["pairingInvitationField"].firstMatch
        field.tap()
        field.typeText(parts.string!)
        app.buttons["preparePairing"].tap()
        XCTAssertTrue(app.staticTexts["邀请来自其他服务器"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["joinPairing"].exists)
        XCTAssertTrue(field.exists)
    }
}
