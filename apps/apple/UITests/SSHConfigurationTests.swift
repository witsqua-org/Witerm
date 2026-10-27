import XCTest

/// Configuration-only acceptance never connects to a host or saves a secret.
@MainActor final class SSHConfigurationTests: XCTestCase {
    private func setOrientation() {
        let previousOrientation = XCUIDevice.shared.orientation
        if ProcessInfo.processInfo.environment["WITERM_UI_LANDSCAPE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { await MainActor.run { XCUIDevice.shared.orientation = previousOrientation } }
        }
    }

    func testSaveEditSearchAndFavoriteWithoutConnecting() {
        continueAfterFailure = false
        let name = "UI saved only " + String(UUID().uuidString.prefix(6))
        setOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.startTask", "ssh", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        app.buttons["newSSHProfile"].tap()
        let host = app.textFields["sshHostAddress"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap(); host.typeText("fixture@example.invalid")
        XCTAssertTrue(app.staticTexts["sshAddressSummary"].waitForExistence(timeout: 5))
        app.buttons["sshMoreOptions"].tap()
        let field = app.textFields["sshProfileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The keyboard and the bottom actions cover the lower half; bring the field up.
        let middle = app.windows.firstMatch.frame.midY
        for _ in 0..<4 where !field.isHittable || field.frame.maxY > middle { app.swipeUp() }
        field.tap(); field.typeText(name)
        // Reveal the save-only action without entering any credentials.
        let saveOnly = app.buttons["sshSaveOnly"]
        for _ in 0..<6 where !saveOnly.isHittable { app.swipeUp() }
        XCTAssertTrue(saveOnly.isHittable)
        saveOnly.tap()
        let row = app.buttons[name]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sshTrustHost"].exists)
        let id = row.identifier.replacingOccurrences(of: "sshProfileRow-", with: "")
        // The public row label is the name; take the stable profile identifier.
        let profile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        let suffix = String(profile.identifier.dropFirst("sshProfileRow-".count))
        XCTAssertNotNil(UUID(uuidString: suffix), id)
        let menu = app.buttons["sshProfileActions-" + suffix]
        addTeardownBlock {
            await MainActor.run {
                if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
                let search = app.searchFields.firstMatch
                if search.exists, let text = search.value as? String, !text.isEmpty, text != "Search Hosts" {
                    search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
                }
                guard menu.exists else { return }
                menu.tap()
                app.buttons["Delete Connection"].tap()
                XCTAssertTrue(app.buttons["sshUndoRemove"].waitForExistence(timeout: 5))
            }
        }
        menu.tap()
        app.buttons["Edit Connection"].tap()
        XCTAssertTrue(app.buttons["sshSaveProfile"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sshConnect"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ssh-save-without-connect"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["sshSaveProfile"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["Add to Favorites"].tap()
        let favorite = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "favorite"), object: row)
        wait(for: [favorite], timeout: 5)
        // With only a few hosts, search and filters stay out of the way.
        app.swipeDown()
        XCTAssertFalse(app.switches["sshFavoritesOnly"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
    }

    /// Generating a key never saves or sends it; the form only shows the public half.
    func testGeneratedKeyShowsPublicKeyWithoutSaving() {
        setOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.startTask", "ssh", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        app.buttons["newSSHProfile"].tap()
        let keyChoice = app.buttons["Private Key"].firstMatch
        XCTAssertTrue(keyChoice.waitForExistence(timeout: 5))
        keyChoice.tap()
        let generate = app.buttons["sshGenerateKey"]
        // Bring the button clear of the bottom edge, where a tap reaches the home indicator.
        let bottom = app.windows.firstMatch.frame.maxY - 120
        for _ in 0..<4 where !generate.isHittable || generate.frame.maxY > bottom { app.swipeUp() }
        generate.tap()
        let publicKey = app.staticTexts["sshGeneratedPublicKey"]
        XCTAssertTrue(publicKey.waitForExistence(timeout: 5))
        XCTAssertTrue(publicKey.label.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        XCTAssertTrue(app.buttons["sshCopyPublicKey"].exists)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 5))
    }

    func testInvalidConfigurationShowsFieldErrorsBeforeConnecting() {
        setOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["-witerm.startTask", "ssh", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
        app.buttons["newSSHProfile"].tap()
        app.buttons["sshConnect"].tap()
        XCTAssertTrue(app.staticTexts["Enter an address, like deploy@server.example.com."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sshTrustHost"].exists)
    }
}
