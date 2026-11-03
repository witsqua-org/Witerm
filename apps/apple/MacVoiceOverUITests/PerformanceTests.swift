import Foundation
import XCTest

/// Opt-in responsiveness measurements against a signed app at
/// WITERM_HCI_FIXED_APP, with WITERM_PERF=1, so the same runner can measure
/// the installed build and a new one. Each step attaches "perf" lines, also
/// printed with a "PERF" prefix for the log, and wall-clock times include
/// XCTest's own polling (about 0.05–0.1 s).
///
/// It creates only terminals named "Perf …" and ends them, and with
/// WITERM_PERF_SSH_PORT and WITERM_PERF_SSH_FINGERPRINT (a disposable OpenSSH
/// fixture with ~1,000 files in `many/`) one host named "Perf Host …", whose
/// trust and profile it removes. The sidebar test fills the service's 16
/// terminals with "Perf NN" ones beside the person's own, then ends them.
@MainActor
final class PerformanceTests: XCTestCase {
    private var app: XCUIApplication!
    private var lines: [String] = []

    override func tearDown() {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "perf-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    private func path() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], environment["WITERM_PERF"] == "1" else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_PERF=1")
        }
        return path
    }

    private func record(_ label: String, _ seconds: TimeInterval) {
        let line = "\(label): \(String(format: "%.3f", seconds)) s"
        lines.append(line)
        print("PERF \(Date().timeIntervalSince1970) \(line)")
    }

    private func mark(_ label: String) { print("PERF \(Date().timeIntervalSince1970) mark \(label)") }

    private func launch(_ path: String) {
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15))
    }

    private var mainWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "NOT (identifier CONTAINS[c] 'settings')")).firstMatch
    }

    private func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    /// Seconds until `condition` holds, polling every 20 ms; nil on timeout.
    private func time(timeout: TimeInterval = 15, _ condition: () -> Bool) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return Date().timeIntervalSince(start) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    private var sessionRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "localSession-"))
    }

    private func perfRows() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                             "localSession-", "Perf "))
    }

    /// Ends every "Perf …" terminal shown, and no other.
    private func endPerfTerminals() {
        for _ in 0..<20 {
            let row = perfRows().firstMatch
            guard row.exists else { return }
            // By position: a row under a banner or half scrolled still opens its menu.
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            guard app.menuItems["endSessionMenu"].waitForExistence(timeout: 3) else { app.typeKey(.escape, modifierFlags: []); return }
            app.menuItems["endSessionMenu"].click()
            let confirm = app.buttons["action-button-1"]
            if confirm.waitForExistence(timeout: 5) { confirm.click() }
            _ = row.waitForNonExistence(timeout: 10)
        }
    }

    /// ⌘N, then renames it to `name`; returns its row.
    private func newTerminal(_ name: String) -> XCUIElement? {
        let before = Set(sessionRows.allElementsBoundByIndex.map(\.identifier))
        app.typeKey("n", modifierFlags: .command)
        var created: String?
        _ = time { created = sessionRows.allElementsBoundByIndex.first { !before.contains($0.identifier) }?.identifier; return created != nil }
        guard let created else { return nil }
        app.typeKey("r", modifierFlags: [.command, .shift])
        let field = app.textFields["localSessionName"]
        guard field.waitForExistence(timeout: 5) else { return nil }
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name + "\r")
        _ = field.waitForNonExistence(timeout: 5)
        return any(created)
    }

    // MARK: Launch

    func testLaunchToFirstFrame() throws {
        let path = try path()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = XCUIApplication(url: URL(fileURLWithPath: path))
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
            app.launch()
            self.app = app
        }
        // Wall clock, for a number outside Xcode's report: launch to the
        // window, then to the sidebar's first terminal row.
        for run in 1...3 {
            app.terminate()
            let started = Date()
            launch(path)
            record("launch \(run) to window", Date().timeIntervalSince(started))
            if let rows = time({ sessionRows.firstMatch.exists }) { record("launch \(run) to first row (after window)", rows) }
        }
        app.terminate()
    }

    // MARK: ⌘N

    func testNewTerminalToTypeable() throws {
        launch(try path())
        defer { endPerfTerminals(); app.terminate() }
        let terminal = any("localTerminalSurface")
        for run in 1...5 {
            let before = Set(sessionRows.allElementsBoundByIndex.map(\.identifier))
            mark("cmd-n \(run)")
            let started = Date()
            app.typeKey("n", modifierFlags: .command)
            guard let focused = time({ terminal.exists && (terminal.value(forKey: "hasKeyboardFocus") as? Bool) == true }) else {
                XCTFail("No focused terminal after ⌘N"); return
            }
            record("⌘N \(run) to focused terminal", focused)
            app.typeText("echo PERF_$((40+\(run)))_READY\r")
            if let typed = time({ (terminal.value as? String ?? "").contains("PERF_\(40 + run)_READY") }) {
                record("⌘N \(run) to first command's output", Date().timeIntervalSince(started))
                _ = typed
            }
            // Name it so cleanup ends only this one.
            if let id = sessionRows.allElementsBoundByIndex.first(where: { !before.contains($0.identifier) })?.identifier {
                app.typeKey("r", modifierFlags: [.command, .shift])
                let field = app.textFields["localSessionName"]
                if field.waitForExistence(timeout: 5) {
                    field.typeKey("a", modifierFlags: .command)
                    field.typeText("Perf New \(run)\r")
                    _ = field.waitForNonExistence(timeout: 5)
                }
                XCTAssertTrue(any(id).exists)
            }
            endPerfTerminals()
        }
    }

    // MARK: 16 terminals

    func testSidebarWithSixteenTerminals() throws {
        let path = try path()
        executionTimeAllowance = 900
        // Up to the service's 16: "Perf NN" terminals beside the person's own.
        launch(path)
        for index in 1...15 where sessionRows.count < 16 {
            guard newTerminal(String(format: "Perf %02d", index)) != nil else { break }
        }
        record("terminals listed before relaunch", TimeInterval(sessionRows.count))
        app.terminate()
        defer { endPerfTerminals(); app.terminate() }
        let started = Date()
        launch(path)
        // The sidebar lists rows lazily: those in view are enough.
        guard let listed = time({ perfRows().count >= 8 }) else { XCTFail("The Perf terminals aren't listed"); return }
        record("launch to 16 rows", Date().timeIntervalSince(started))
        _ = listed
        let rows = perfRows().allElementsBoundByIndex
        record("rows listed", TimeInterval(sessionRows.count))

        // Hover across every row, top to bottom and back: the tracking areas' cost.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        mark("hover sweep")
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            for row in rows + rows.reversed() { row.hover() }
        }
        // Selecting each terminal in turn until its surface is on screen.
        mark("select sweep")
        let terminal = any("localTerminalSurface")
        var total: TimeInterval = 0
        var focusTotal: TimeInterval = 0
        for row in rows {
            let started = Date()
            row.click()
            if time({ terminal.exists && (terminal.value(forKey: "hasKeyboardFocus") as? Bool) == true }) != nil {
                focusTotal += Date().timeIntervalSince(started)
            }
            _ = time { (row.value as? String ?? "").hasPrefix("Typing") }
            total += Date().timeIntervalSince(started)
        }
        record("select each of \(rows.count) terminals, mean to a focused terminal", focusTotal / Double(max(rows.count, 1)))
        record("select each of \(rows.count) terminals, mean to the row saying Typing", total / Double(max(rows.count, 1)))
    }

    // MARK: Sheets

    func testSheetOpening() throws {
        launch(try path())
        defer { endPerfTerminals(); app.terminate() }
        guard newTerminal("Perf Sheets") != nil else { XCTFail("No terminal"); return }

        func measureOpen(_ label: String, _ open: () -> Void, until element: XCUIElement, close: () -> Void) {
            // Polled every 20 ms: XCTest's own wait also waits for the app to
            // go idle, which adds 1–4 s that aren't the app's.
            let started = Date()
            open()
            if let seconds = time({ element.exists }) { record("open \(label)", seconds) }
            else {
                record("open \(label) TIMEOUT", Date().timeIntervalSince(started))
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "perf-timeout-\(label)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            close()
            _ = element.waitForNonExistence(timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let escape = { self.app.typeKey(.escape, modifierFlags: []) }
        for _ in 1...3 {
            measureOpen("Rename", { app.typeKey("r", modifierFlags: [.command, .shift]) }, until: app.textFields["localSessionName"], close: escape)
            measureOpen("Open On (toolbar)", { self.any("shareLocalSession").click() },
                        until: app.sheets.firstMatch, close: {
                            // Cancel rejects any QR code the sheet made.
                            if self.any("continueCancel").waitForExistence(timeout: 5) { self.any("continueCancel").click() } else { escape() }
                        })
            measureOpen("Add SSH Host", { app.typeKey("n", modifierFlags: [.command, .shift]) },
                        until: app.textFields["sshHostAddress"], close: escape)
            measureOpen("Import SSH Hosts", {
                app.menuBars.menuBarItems["File"].click()
                app.menuItems["Import SSH Hosts…"].click()
            }, until: any("sshImportChooseFile"), close: escape)
            measureOpen("Welcome Tour", {
                app.menuBars.menuBarItems["Help"].click()
                app.menuItems["Welcome Tour"].click()
            }, until: app.sheets.firstMatch, close: {
                if self.app.buttons["welcomeTourSkip"].exists { self.app.buttons["welcomeTourSkip"].click() } else { escape() }
            })
            measureOpen("Settings", { app.typeKey(",", modifierFlags: .command) },
                        until: app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch,
                        close: { self.app.typeKey("w", modifierFlags: .command) })
        }
    }

    // MARK: SFTP and SSH sheets

    func testSFTPThousandFiles() throws {
        let path = try path()
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_PERF_SSH_PORT"], let fingerprint = environment["WITERM_PERF_SSH_FINGERPRINT"],
              fingerprint.hasPrefix("SHA256:") else { throw XCTSkip("Set WITERM_PERF_SSH_PORT and WITERM_PERF_SSH_FINGERPRINT") }
        launch(path)
        defer { app.terminate() }
        let hostName = "Perf Host " + String(UUID().uuidString.prefix(4))
        app.typeKey("n", modifierFlags: [.command, .shift])
        let address = app.textFields["sshHostAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click(); address.typeText("fixture@127.0.0.1:" + port)
        app.buttons["sshMoreOptions"].click()
        let nameField = app.textFields["sshProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText(hostName)
        let password = app.secureTextFields.matching(identifier: "sshHostPassword").firstMatch
        password.click(); password.typeText("witerm-fixture-only")
        app.buttons["sshConnect"].click()
        // The audit run may already trust this fixture's key; then there's no trust sheet.
        let identity = app.staticTexts["sshHostFingerprint"]
        let surface = any("sshTerminalSurface")
        _ = time(timeout: 20) { identity.exists || surface.exists }
        if identity.exists {
            guard (identity.label + " " + (identity.value as? String ?? "")).contains(fingerprint) else {
                XCTFail("Unexpected fixture fingerprint; not trusting it"); app.typeKey(.escape, modifierFlags: []); return
            }
            app.buttons["sshTrustHost"].click()
        }
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        let hostRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", hostName)).firstMatch
        let hostID = String(hostRow.identifier.dropFirst("sshProfileRow-".count))

        // SFTP: the sheet, the home listing, then the folder of ~1,000 files.
        for run in 1...3 {
            var started = Date()
            any("sshFiles").click()
            let sheet = app.sheets.firstMatch
            let folder = sheet.staticTexts["many"]
            if let seconds = time({ folder.exists }) { record("SFTP \(run) open to home listed", seconds) }
            started = Date()
            folder.doubleClick()
            let first = sheet.staticTexts["file-0001.txt"]
            if time({ first.exists }) != nil { record("SFTP \(run) 1,000 files listed", Date().timeIntervalSince(started)) }
            // To the end of the list and back.
            started = Date()
            first.click()
            app.typeKey(.end, modifierFlags: [])
            if time({ sheet.staticTexts["file-1000.txt"].exists && sheet.staticTexts["file-1000.txt"].isHittable }) != nil {
                record("SFTP \(run) End to the last file", Date().timeIntervalSince(started))
            }
            app.typeKey(.escape, modifierFlags: [])
            _ = sheet.waitForNonExistence(timeout: 5)
        }
        for run in 1...3 {
            let started = Date()
            any("sshForwarding").click()
            if time({ self.any("sshForwardListenPort").exists }) != nil { record("open Port Forwarding \(run)", Date().timeIntervalSince(started)) }
            app.typeKey(.escape, modifierFlags: [])
            _ = any("sshForwardListenPort").waitForNonExistence(timeout: 5)
        }

        // Disconnect, then remove this run's trust and host.
        any("sshDisconnect").click()
        if app.buttons["sshConfirmDisconnect"].waitForExistence(timeout: 1) { app.buttons["sshConfirmDisconnect"].click() }
        XCTAssertTrue(any("sshConnectProfile").waitForExistence(timeout: 10))
        let menu = any("sshProfileActions-\(hostID)")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let started = Date()
        app.menuItems["Host Keys"].click()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch
        if time({ remove.exists }) != nil { record("open Host Keys", Date().timeIntervalSince(started)) }
        remove.click()
        app.buttons["sshConfirmForgetHostKey"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No Saved Host Key"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        menu.click()
        app.menuItems["sshDeleteHostMenu"].click()
        XCTAssertTrue(hostRow.waitForNonExistence(timeout: 10))
    }

    /// After an interrupted run: removes the trust and profile of "Perf Host …"
    /// hosts only, and ends "Perf …" terminals. Opt-in: WITERM_PERF_CLEANUP=1.
    func testDeleteLeftoverPerfHostsAndTerminals() throws {
        let path = try path()
        guard ProcessInfo.processInfo.environment["WITERM_PERF_CLEANUP"] == "1" else { throw XCTSkip("Set WITERM_PERF_CLEANUP=1") }
        launch(path)
        defer { app.terminate() }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        endPerfTerminals()
        let hosts = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "sshProfileRow-", "Perf Host "))
        for _ in 0..<4 {
            let row = hosts.firstMatch
            guard row.exists else { break }
            row.click()
            let id = String(row.identifier.dropFirst("sshProfileRow-".count))
            if any("sshDisconnect").exists {
                any("sshDisconnect").click()
                if app.buttons["sshConfirmDisconnect"].waitForExistence(timeout: 1) { app.buttons["sshConfirmDisconnect"].click() }
            }
            let menu = any("sshProfileActions-\(id)")
            guard menu.waitForExistence(timeout: 10) else { break }
            menu.click()
            app.menuItems["Host Keys"].click()
            let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch
            if remove.waitForExistence(timeout: 5) {
                remove.click()
                app.buttons["sshConfirmForgetHostKey"].firstMatch.click()
                _ = app.staticTexts["No Saved Host Key"].waitForExistence(timeout: 5)
            }
            app.typeKey(.escape, modifierFlags: [])
            menu.click()
            app.menuItems["sshDeleteHostMenu"].click()
            _ = row.waitForNonExistence(timeout: 10)
        }
        XCTAssertFalse(hosts.firstMatch.exists)
    }

    // MARK: Memory

    /// An hour of a busy log, sped up: 360,000 lines (100 a second for an
    /// hour), 100 lines every 50 ms, through one terminal, with the app's
    /// footprint sampled outside the runner (the "PERF … mark" lines time
    /// it). Then bursts of 1,000, 3,600 and 50,000 lines at once, to see
    /// which the window keeps up with.
    func testMemoryAfterLongOutput() throws {
        launch(try path())
        executionTimeAllowance = 1500
        defer { endPerfTerminals(); app.terminate() }
        guard let row = newTerminal("Perf Output") else { XCTFail("No terminal"); return }
        let terminal = any("localTerminalSurface")
        let interrupted = app.staticTexts["Terminal Interrupted"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        terminal.click()
        func shows(_ token: String) -> Bool { terminal.exists && (terminal.value as? String ?? "").contains(token) }
        app.typeText("echo PERF_$((1+1))_GO\r")
        guard time({ shows("PERF_2_GO") }) != nil else { XCTFail("Typing didn't reach the new terminal"); return }
        /// Seconds until `token` shows, or nil if the terminal was interrupted or it timed out.
        func run(_ command: String, done token: String, timeout: TimeInterval) -> TimeInterval? {
            let started = Date()
            app.typeText(command + "\r")
            _ = time(timeout: timeout) {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                return interrupted.exists || shows(token)
            }
            return interrupted.exists || !shows(token) ? nil : Date().timeIntervalSince(started)
        }
        mark("paced start")
        let paced = run("clear; seq 1 360000 | awk '{print; if (NR % 100 == 0) system(\"sleep 0.05\")}'; echo PERF_$((6*7))_DONE",
                        done: "PERF_42_DONE", timeout: 900)
        mark("paced done")
        record("360,000 lines paced (100 every 50 ms)", paced ?? -1)
        record("interrupted during paced output", interrupted.exists ? 1 : 0)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        mark("settled")
        for (lines, token) in [(1000, 11), (3600, 12), (50000, 13)] {
            guard !interrupted.exists else { break }
            mark("burst \(lines)")
            let burst = run("seq 1 \(lines); echo PERF_$((\(token)*2))_BURST", done: "PERF_\(token * 2)_BURST", timeout: 120)
            record("burst of \(lines) lines", burst ?? -1)
            record("interrupted by \(lines) lines", interrupted.exists ? 1 : 0)
        }
        mark("bursts done")
        XCTAssertTrue(row.exists)
    }
}
