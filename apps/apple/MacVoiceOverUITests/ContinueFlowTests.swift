import Foundation
import XCTest

/// Opt-in acceptance against the fixed, signed development app. Only the
/// freshly created session is ended; nothing is shared and remote access is
/// never enabled.
@MainActor
@available(macOS 27.0, *)
final class ContinueFlowTests: XCTestCase {
    func testContinueSheetStartsAtTheFirstUnfinishedStep() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"],
              let id = ProcessInfo.processInfo.environment["WITERM_HCI_SESSION_ID"],
              UUID(uuidString: id) != nil else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and a freshly created WITERM_HCI_SESSION_ID")
        }
        // An acceptance run may have started VoiceOver to diagnose its system
        // precondition. Restore the caller's explicitly recorded off state.
        if ProcessInfo.processInfo.environment["WITERM_HCI_RESTORE_VOICEOVER_OFF"] == "1",
           XCUIDevice.shared.voiceOverService.isEnabled {
            try XCUIDevice.shared.voiceOverService.disable()
        }
        let url = URL(fileURLWithPath: path)
        let app = XCUIApplication(url: url)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }

        let enable = app.buttons["enableLocalTerminal"]
        if enable.waitForExistence(timeout: 3) { enable.click() }
        let row = app.descendants(matching: .any)["localSession-" + id].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.hasPrefix("HCI acceptance"))
        addTeardownBlock {
            await MainActor.run {
                if app.buttons["continueCancel"].exists { app.buttons["continueCancel"].click() }
                guard row.exists else { return }
                row.rightClick()
                app.menuItems["endSessionMenu"].click()
                let confirm = app.buttons["action-button-1"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                confirm.click()
                let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
                XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
            }
        }

        row.rightClick()
        app.menuItems["Continue on Another Device…"].click()
        let title = app.staticTexts["continueStepTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // The sheet stops at the server step unless this Mac already allows
        // remote access. Past it, with nothing paired, it goes straight to
        // the code for a new device, and Back offers the other choices.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertTrue(["Connect This Mac", "Choose a Device", "Scan with the Other Device"].contains(title.label), title.label)
        if title.label == "Scan with the Other Device" {
            app.buttons["continueBack"].click()
            let device = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Choose a Device"), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [device], timeout: 5), .completed, title.label)
        }
        if title.label == "Choose a Device" {
            XCTAssertTrue(app.descendants(matching: .any)["continueNewDevice"].firstMatch.exists)
            XCTAssertTrue(app.descendants(matching: .any)["continueGuest"].firstMatch.exists)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "continue-on-another-device"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["continueCancel"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        wait(for: [closed], timeout: 5)
        // Cancelling shares nothing.
        XCTAssertFalse(app.descendants(matching: .any)["localSession-" + id].firstMatch.value as? String ?? "" == "Shared")

        // Keeping the session private shows on its row, and undoing it clears that.
        row.rightClick()
        app.menuItems["Keep Private"].click()
        let kept = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'Kept private'"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [kept], timeout: 10), .completed, row.value as? String ?? "")
        row.rightClick()
        app.menuItems["Keep Private"].click()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS 'Kept private')"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed, row.value as? String ?? "")
    }

    /// Release QA for replacing the installed bundle: turns the background
    /// service off (before quitting the old app) or on (in the new one)
    /// through Settings → General, the same control a person uses. Shells
    /// keep running while it's off. Opt-in: WITERM_HCI_SERVICE_ACTION=off|on.
    func testServiceSwitch() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"],
              let action = ProcessInfo.processInfo.environment["WITERM_HCI_SERVICE_ACTION"],
              ["off", "on"].contains(action) else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_HCI_SERVICE_ACTION=off|on")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        // Settings opens on General, so only the service control is clicked.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.settingsTab", "general", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["General"].firstMatch.waitForExistence(timeout: 10))
        app.activate()
        // Identifiers, with the labels before Round 8 as a fallback, so the
        // same runner can turn off an older installed app.
        let disable = app.buttons.matching(NSPredicate(
            format: "identifier == 'turnOffTerminals' OR label == 'Disable Local Terminal…'")).firstMatch
        let enable = app.buttons.matching(NSPredicate(
            format: "identifier == 'turnOnTerminals' OR label == 'Enable Local Terminal'")).firstMatch
        if action == "off" {
            XCTAssertTrue(disable.waitForExistence(timeout: 10), "the service should be on before turning it off")
            disable.click()
            let confirm = app.buttons.matching(NSPredicate(format: "label == 'Turn Off' OR label == 'Disable'")).firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.click()
            XCTAssertTrue(enable.waitForExistence(timeout: 15), "the service did not turn off")
            // The old app quits so the bundle can be replaced.
            addTeardownBlock { await MainActor.run { app.terminate() } }
        } else {
            if !disable.exists {
                XCTAssertTrue(enable.waitForExistence(timeout: 10))
                enable.click()
            }
            XCTAssertTrue(disable.waitForExistence(timeout: 30), "the service did not turn on")
            app.typeKey("w", modifierFlags: .command)
        }
    }

    /// Release QA, with the person's approval: turns Allow Remote Access on
    /// or off through Settings → Devices, adding the continuation server
    /// first when none is set up, and waits for this Mac's live state.
    /// Opt-in: WITERM_HCI_REMOTE_ACCESS=on|off and
    /// WITERM_HCI_REMOTE_ACCESS_SERVER (an https address).
    func testRemoteAccessSwitch() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], let action = environment["WITERM_HCI_REMOTE_ACCESS"],
              ["on", "off"].contains(action), let server = environment["WITERM_HCI_REMOTE_ACCESS_SERVER"],
              let host = URL(string: server)?.host else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP, WITERM_HCI_REMOTE_ACCESS=on|off and WITERM_HCI_REMOTE_ACCESS_SERVER")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.settingsTab", "devices",
                               "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Devices"].firstMatch.waitForExistence(timeout: 10))
        app.activate()

        func enterAddress() {
            let field = app.textFields["serverAddressField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.click()
            field.typeText(server)
            app.buttons["saveServerAddress"].click()
            XCTAssertTrue(field.waitForNonExistence(timeout: 10), "The server address wasn't accepted")
        }
        let devices = app.windows["Devices"].firstMatch
        let named = devices.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", host, host)).firstMatch
        let addServer = app.buttons["serverSettings"]
        if addServer.waitForExistence(timeout: 3) {
            // No server yet.
            addServer.click()
            enterAddress()
        } else if !named.waitForExistence(timeout: 3) {
            // Another server is set up; add this one beside it.
            app.buttons["manageServers"].click()
            let addAnother = app.buttons["addServer"]
            XCTAssertTrue(addAnother.waitForExistence(timeout: 5))
            addAnother.click()
            enterAddress()
            app.sheets.buttons["Done"].firstMatch.click()
        }
        // The server answers before remote access can be switched.
        let status = app.descendants(matching: .any)["connectionFeedback"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let picker = app.popUpButtons["continuationServerPicker"].firstMatch
        if picker.exists, !(picker.value as? String ?? "").contains(host) {
            picker.click()
            app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", host)).firstMatch.click()
        }
        let toggle = app.descendants(matching: .any)["allowRemoteConnections"].firstMatch
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed, "Allow Remote Access stayed unavailable")
        let isOn = { (toggle.value as? Int ?? (toggle.value as? NSNumber)?.intValue ?? 0) == 1 }
        if isOn() != (action == "on") { toggle.click() }
        let state = app.descendants(matching: .any)["remoteAccessState"].firstMatch
        if action == "on" {
            // This Mac's row reads what the service reports, as VoiceOver hears it.
            XCTAssertTrue(state.waitForExistence(timeout: 30), "No live remote-access row")
            let online = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'Online' OR label CONTAINS 'Online'"), object: state)
            let result = XCTWaiter.wait(for: [online], timeout: 60)
            if result != .completed { print("WITERM_TREE_BEGIN\n\(devices.debugDescription)\nWITERM_TREE_END") }
            XCTAssertEqual(result, .completed, "This Mac never came online through \(host): \(state.label)")
        } else {
            XCTAssertTrue(state.waitForNonExistence(timeout: 15))
        }
        let shot = XCTAttachment(screenshot: app.windows["Devices"].firstMatch.screenshot())
        shot.name = "settings-devices-remote-access-\(action)"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeKey("w", modifierFlags: .command)
    }

    /// Every Settings tab keeps one window size, so switching never resizes it.
    func testSettingsTabsKeepOneWindowSize() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let general = app.toolbars.buttons["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        var sizes: [String: CGSize] = [:]
        for tab in ["General", "Terminal", "Snippets", "Devices", "Command Line"] {
            app.toolbars.buttons[tab].firstMatch.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let window = app.windows.matching(NSPredicate(format: "title == %@", tab)).firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5), tab)
            sizes[tab] = window.frame.size
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "settings-\(tab)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertEqual(Set(sizes.values.map { "\($0.width)x\($0.height)" }).count, 1, "\(sizes)")
        app.typeKey("w", modifierFlags: .command)
    }
}
