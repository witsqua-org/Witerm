import XCTest

/// Orbit's page in the signed app (Round 30). Nothing here sends anything to
/// Orbit, so no request reaches OpenAI and no quota is spent: the composer is
/// never typed in, and threads are only selected and read. The test makes one
/// terminal ("Orbit UI …") for Ask Orbit About This Terminal, and ends only
/// that one. Set WITERM_HCI_FIXED_APP.
@MainActor
final class OrbitPageTests: XCTestCase {
    private var app: XCUIApplication!

    private func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func launch() throws {
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP")
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The sidebar row opens the page: without a key it asks for one (Add API
    /// Key… opens Settings ▸ Orbit); with one it offers a new conversation,
    /// Ask or Delegate a Task, and Send stays off until there's a message.
    func testTheSidebarRowOpensOrbitsPage() throws {
        continueAfterFailure = false
        try launch()
        let row = any("orbitSidebarRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let addKey = any("orbitAddKey")
        let message = any("orbitMessage")
        XCTAssertTrue(addKey.waitForExistence(timeout: 10) || message.waitForExistence(timeout: 5), "Orbit's page didn't open")
        attach("orbit-page")

        if addKey.exists {
            addKey.click()
            let field = app.secureTextFields["orbitKeyField"]
            XCTAssertTrue(field.waitForExistence(timeout: 10), "Add API Key… didn't open Settings ▸ Orbit")
            XCTAssertTrue(app.windows["Orbit"].exists)
            app.typeKey("w", modifierFlags: .command)
            return
        }

        any("orbitNewThread").click()
        XCTAssertTrue(app.staticTexts["What should Orbit do?"].waitForExistence(timeout: 5))
        XCTAssertTrue(any("orbitAbout").exists)
        let send = app.buttons["orbitSend"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Send is on with an empty message")
        let kind = any("orbitKind")
        XCTAssertTrue(kind.exists)
        kind.radioButtons["Delegate a Task"].click()
        XCTAssertEqual(message.placeholderValue, "Describe the task…")
        attach("orbit-new-task")
        kind.radioButtons["Ask"].click()
        XCTAssertEqual(message.placeholderValue, "Ask about your terminals…")

        // A thread is read without sending anything.
        let threads = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "orbitThread-"))
        if threads.firstMatch.waitForExistence(timeout: 5) {
            threads.firstMatch.click()
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            XCTAssertFalse(any("orbitKind").exists, "A shown thread still offers Ask or Delegate")
            XCTAssertFalse(send.isEnabled)
            attach("orbit-thread")
        }
        any("homeSidebarRow").click()
    }

    /// A terminal's context menu starts a conversation about that terminal.
    func testAskOrbitAboutThisTerminal() throws {
        continueAfterFailure = false
        try launch()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "localSession-"))
        let before = Set(rows.allElementsBoundByIndex.map(\.identifier))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(any("localTerminalSurface").waitForExistence(timeout: 15))
        var created: String?
        for _ in 0..<50 where created == nil {
            created = rows.allElementsBoundByIndex.first { !before.contains($0.identifier) }?.identifier
            if created == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        let id = try XCTUnwrap(created)
        // The row itself, not its context menu, which shares the identifier.
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND elementType != %d", id, XCUIElement.ElementType.menu.rawValue)).firstMatch
        addTeardownBlock { [app] in
            await MainActor.run {
                guard let app, row.exists else { return }
                app.typeKey(.escape, modifierFlags: [])
                row.rightClick()
                guard app.menuItems["endSessionMenu"].waitForExistence(timeout: 3) else { return }
                app.menuItems["endSessionMenu"].click()
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
                _ = row.waitForNonExistence(timeout: 10)
            }
        }
        let name = "Orbit UI " + String(UUID().uuidString.prefix(4))
        app.typeKey("r", modifierFlags: [.command, .shift])
        let field = app.textFields["localSessionName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name + "\r")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        row.rightClick()
        let ask = app.menuItems["askOrbitMenu"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.click()
        let about = any("orbitAbout")
        guard about.waitForExistence(timeout: 10) else {
            // No key: the page asks for one instead of a composer.
            XCTAssertTrue(any("orbitAddKey").exists, "Ask Orbit didn't open Orbit's page")
            return
        }
        let chosen = (about.value as? String) ?? about.label
        XCTAssertTrue(chosen.contains(name), "The conversation isn't about the terminal: \(chosen)")
        XCTAssertFalse(app.buttons["orbitSend"].isEnabled)
        attach("orbit-ask-about-terminal")
        any("homeSidebarRow").click()
    }
}
