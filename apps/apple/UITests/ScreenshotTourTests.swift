import XCTest

/// Opt-in screenshots of the screens a wording review looks at, in English,
/// written to WITERM_SHOTS_DIR. Needs no server, no SSH host, and no paired
/// device: invitations are generated locally and never submitted, and the
/// one host it saves (to show its actions) is deleted again.
@MainActor final class ScreenshotTourTests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func launch(tour: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", tour ? "0" : "1",
                               // Unreachable on purpose: nothing is ever sent there.
                               "-witerm.serverAddresses", "(\"http://localhost:37429\")",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func tab(_ index: Int) {
        let button = app.tabBars.buttons.element(boundBy: index)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func link(_ host: String, _ items: [(String, String)]) -> String {
        var parts = URLComponents()
        parts.scheme = "witerm"
        parts.host = host
        parts.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.string!
    }

    private func typeInvitation(_ invitation: String) {
        tab(1)
        let start = app.buttons["continueFromDevice"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        app.buttons["typeInvitation"].tap()
        let field = app.descendants(matching: .any)["sessionInvitationField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(invitation)
        app.buttons["preparePairing"].tap()
        XCTAssertTrue(app.buttons["joinPairing"].waitForExistence(timeout: 5))
    }

    func testWordingScreens() throws {
        continueAfterFailure = false
        guard let directory = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] else {
            throw XCTSkip("Set WITERM_SHOTS_DIR")
        }
        folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        launch(tour: true)
        XCTAssertTrue(app.buttons["welcomeTourNext"].waitForExistence(timeout: 10))
        app.buttons["welcomeTourNext"].tap()
        shot("01-tour-continue")
        app.buttons["welcomeTourSkip"].tap()
        app.terminate()

        launch()
        tab(0)
        shot("02-terminals")
        tab(1)
        XCTAssertTrue(app.buttons["continueFromDevice"].waitForExistence(timeout: 10))
        shot("03-devices")
        tab(2)
        XCTAssertTrue(app.buttons["settingsServers"].waitForExistence(timeout: 10))
        shot("04-settings")
        app.buttons["settingsServers"].tap()
        XCTAssertTrue(app.buttons["settingsAddServer"].waitForExistence(timeout: 5))
        shot("05-relay-servers")
        app.buttons["settingsAddServer"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("06-add-server")
        app.terminate()

        // A one-terminal invitation that can type, then a pairing code.
        launch()
        let share = link("share", [("server", "http://localhost:37429"), ("id", "00000000-0000-4000-8000-000000000081"),
                                   ("secret", String(repeating: "A", count: 43)),
                                   ("host_key", Data(repeating: 1, count: 32).base64EncodedString()),
                                   ("access", "control"), ("until", String(Int(Date().timeIntervalSince1970) + 3600)),
                                   ("key", String(repeating: "A", count: 42) + "E")])
        typeInvitation(share)
        shot("07-check-shared-terminal")
        app.terminate()
        launch()
        let pairing = link("pair", [("server", "https://other-server.example.com"), ("id", "00000000-0000-4000-8000-000000000082"),
                                    ("secret", String(repeating: "A", count: 43)),
                                    ("host_key", Data(repeating: 1, count: 32).base64EncodedString())])
        typeInvitation(pairing)
        shot("08-check-pairing")
        app.terminate()

        // A saved host's actions, without connecting or saving a credential.
        launch()
        tab(0)
        let name = "Shot host " + String(UUID().uuidString.prefix(4))
        app.buttons["newSSHProfile"].tap()
        let host = app.textFields["sshHostAddress"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap(); host.typeText("fixture@example.invalid")
        app.buttons["sshMoreOptions"].tap()
        let field = app.textFields["sshProfileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let middle = app.windows.firstMatch.frame.midY
        for _ in 0..<4 where !field.isHittable || field.frame.maxY > middle { app.swipeUp() }
        field.tap(); field.typeText(name)
        let saveOnly = app.buttons["sshSaveOnly"]
        for _ in 0..<6 where !saveOnly.isHittable { app.swipeUp() }
        saveOnly.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let menu = app.buttons["sshProfileActions-" + String(row.identifier.dropFirst("sshProfileRow-".count))]
        menu.tap()
        shot("09-host-actions")
        let delete = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete Host", "Delete Connection"])).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.buttons["sshUndoRemove"].waitForExistence(timeout: 5))
        app.terminate()
    }
}
