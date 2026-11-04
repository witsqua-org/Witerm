import XCTest

/// Round 18: a paired device's Online / Offline changes on Terminals as soon
/// as the phone can know. The DEBUG fixture's Studio drops off the relay
/// server `WITERM_OFFLINE_AFTER` seconds (default 12) after the app starts
/// (`-witerm.debug.fixtureOfflineAfter`); the header's probe value says when,
/// so the test prints how long the list took to say Offline. `PROBE` lines.
@MainActor final class DeviceStatusTests: XCTestCase {
    private var app: XCUIApplication!
    private let noPresence = ProcessInfo.processInfo.environment["WITERM_NO_PRESENCE"] == "1"
    private let after = Double(ProcessInfo.processInfo.environment["WITERM_OFFLINE_AFTER"] ?? "") ?? 12

    private func launch() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1",
                               "-witerm.serverAddresses", "(\"https://relay.fixture.invalid\")",
                               "-witerm.debug.remoteFixture", "1", "-witerm.debug.fixtureOfflineAfter", String(after),
                               "--witerm-ui-test-layout-probe", "--witerm-ui-test-steady-terminal-cursor",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // `WITERM_NO_PRESENCE=1`: as against a relay server without the presence stream.
        if ProcessInfo.processInfo.environment["WITERM_NO_PRESENCE"] == "1" {
            app.launchArguments += ["-witerm.debug.fixtureNoPresence", "YES"]
        }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { [app] in await MainActor.run { app?.terminate() } }
    }

    private var studio: XCUIElement { app.descendants(matching: .any)["deviceSection-fixture-studio"].firstMatch }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    /// Waits for Studio's header to say Offline; returns the seconds from
    /// the fixture Mac dropping off to the list saying so, or nil.
    private func secondsUntilOffline(timeout: TimeInterval) -> Double? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if studio.exists, studio.label.contains("Offline") {
                let seen = Date().timeIntervalSince1970
                let value = studio.value as? String ?? ""
                guard let range = value.range(of: "offlineAt="), let at = Double(value[range.upperBound...]) else { return nil }
                return seen - at
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    /// Nothing open: the list is on screen when Studio drops off.
    func testOfflineShowsOnTheListAtOnce() {
        launch()
        XCTAssertTrue(studio.waitForExistence(timeout: 15))
        XCTAssertTrue(studio.label.contains("Online"), studio.label)
        shot("r18-status-1-online")
        let seconds = secondsUntilOffline(timeout: after + 40)
        print("PROBE r18 offline list-visible seconds=\(seconds.map { String(format: "%.2f", $0) } ?? "never (>40 s)")")
        shot("r18-status-2-offline")
        XCTAssertNotNil(seconds, "The list never said Offline")
        // Polled every 15 s without the presence stream.
        XCTAssertLessThan(seconds ?? 99, noPresence ? 16 : 3, "Offline took too long to show")
        // Its terminals are gone from the list, with one line saying why.
        XCTAssertFalse(app.buttons["remoteSession-fixture-s1"].exists)
    }

    /// A terminal kept connected after Back: its link drops with the Mac, and
    /// the list says Offline and stops saying Connected.
    func testOfflineWithAKeptTerminal() {
        launch()
        let row = app.buttons["remoteSession-fixture-s1"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["remoteSessionList"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.buttons["remoteSessionList"].tap()
        let seconds = secondsUntilOffline(timeout: after + 40)
        print("PROBE r18 offline kept-terminal seconds=\(seconds.map { String(format: "%.2f", $0) } ?? "never (>40 s)")")
        shot("r18-status-3-offline-kept")
        XCTAssertNotNil(seconds, "The list never said Offline")
        XCTAssertLessThan(seconds ?? 99, 3, "Offline took too long to show")
        XCTAssertFalse(app.descendants(matching: .any)["remoteSessionConnected-fixture-s1"].exists, "Still Connected")
    }
}
