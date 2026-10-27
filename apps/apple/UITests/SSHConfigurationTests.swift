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
        let field = app.textFields["sshProfileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(name)
        let host = app.textFields["sshHostAddress"]
        host.tap(); host.typeText("example.invalid")
        let user = app.textFields["sshHostUsername"]
        user.tap(); user.typeText("fixture")
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
        app.switches["sshFavoritesOnly"].tap()
        XCTAssertTrue(row.exists)
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText(name)
        XCTAssertTrue(row.exists)
        search.typeText("-no-match")
        let clear = app.buttons["Show All Hosts"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
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
        let picker = app.buttons["sshAuthentication"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Private Key"].firstMatch.tap()
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
        XCTAssertTrue(app.staticTexts["Enter a valid host address without spaces."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sshTrustHost"].exists)
    }
}
