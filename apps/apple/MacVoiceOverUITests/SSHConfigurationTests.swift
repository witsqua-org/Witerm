import XCTest

@MainActor final class SSHConfigurationTests: XCTestCase {
    func testSaveEditFavoriteAndSearchWithoutConnecting() {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let app = XCUIApplication()
        let name = "UI config Mac " + String(UUID().uuidString.prefix(6))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New SSH Connection"].click()
        let nameField = app.textFields["sshProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText(name)
        let host = app.textFields["sshHostAddress"]
        // Use the form's normal keyboard traversal; XCTest's automatic scroll
        // for the grouped LabeledContent field cannot locate a scroll hit point.
        nameField.typeKey(.tab, modifierFlags: [])
        host.typeText("example.invalid")
        let user = app.textFields["sshHostUsername"]
        host.typeKey(.tab, modifierFlags: [])
        user.typeText("fixture")
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
                app.menuItems["Delete Connection"].click()
                let confirm = app.buttons["action-button-1"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                confirm.click()
            }
        }
        XCTAssertFalse(app.buttons["sshTrustHost"].exists)
        row.rightClick()
        app.menuItems["Edit Connection"].click()
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
}
