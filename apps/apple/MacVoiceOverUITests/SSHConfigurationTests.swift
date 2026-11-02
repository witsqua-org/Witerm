import XCTest

@MainActor final class SSHConfigurationTests: XCTestCase {
    func testSaveEditFavoriteAndSearchWithoutConnecting() {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let app = XCUIApplication()
        let name = "UI config Mac " + String(UUID().uuidString.prefix(6))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Add SSH Host…"].click()
        let host = app.textFields["sshHostAddress"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.click(); host.typeText("fixture@example.invalid")
        app.buttons["sshMoreOptions"].click()
        let nameField = app.textFields["sshProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText(name)
        let formAttachment = XCTAttachment(screenshot: app.screenshot())
        formAttachment.name = "mac-ssh-save-form"
        formAttachment.lifetime = .keepAlways
        add(formAttachment)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -500)
        app.buttons["sshSaveOnly"].click()
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        addTeardownBlock {
            await MainActor.run {
                if app.buttons["Cancel"].exists { app.buttons["Cancel"].click() }
                guard row.exists else { return }
                row.rightClick()
                app.menuItems["sshDeleteHostMenu"].click()
                // Deleting runs in the background; don't quit before it's done.
                XCTAssertTrue(row.waitForNonExistence(timeout: 10), "The test host is still listed")
            }
        }
        XCTAssertFalse(app.buttons["sshTrustHost"].exists)
        row.rightClick()
        app.menuItems["sshEditHostMenu"].click()
        XCTAssertTrue(app.buttons["sshSaveProfile"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sshConnect"].exists)
        app.buttons["sshSaveProfile"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        app.menuItems["Add to Favorites"].click()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText(name)
        XCTAssertTrue(row.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "mac-host-search"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Cleanup after interrupted runs: deletes hosts this test made, by their
    /// "UI config Mac " prefix only. Opt-in: WITERM_HCI_DELETE_CONFIG_HOSTS=1.
    func testDeleteLeftoverConfigHosts() throws {
        guard ProcessInfo.processInfo.environment["WITERM_HCI_DELETE_CONFIG_HOSTS"] == "1" else {
            throw XCTSkip("Set WITERM_HCI_DELETE_CONFIG_HOSTS=1")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let leftovers = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "sshProfileRow-", "UI config Mac "))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        for _ in 0..<10 {
            let row = leftovers.firstMatch
            guard row.exists else { break }
            // Through the host page's More menu, as a person would.
            row.click()
            let suffix = String(row.identifier.dropFirst("sshProfileRow-".count))
            let more = app.descendants(matching: .any)["sshProfileActions-\(suffix)"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.click()
            app.menuItems["sshDeleteHostMenu"].click()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        }
        XCTAssertFalse(leftovers.firstMatch.exists)
    }
}
