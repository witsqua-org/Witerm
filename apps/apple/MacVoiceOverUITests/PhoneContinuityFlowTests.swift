import AppKit
import Foundation
import XCTest

/// Opt-in acceptance with an iPhone (or simulator) through a real server,
/// run together with `MacContinuityFlowTests` on the phone. The two runs
/// exchange signals through `scripts/e2e-signal-server.py` when
/// WITERM_E2E_SIGNALS names it (the simulator may not be allowed to read this
/// runner's container), otherwise through files in WITERM_E2E_DIR. Creates one fresh session, continues
/// it on the phone (pairing it for that session only, with typing), types
/// alongside it, then ends the session and revokes that pairing. Nothing
/// else is touched; remote access through the server must already be on. The
/// sandboxed runner reads the phone's files from WITERM_E2E_DIR and writes
/// its own to `witerm-e2e` in its temporary folder. With WITERM_E2E_BURST=1
/// (set for both runs) it prints a million lines while the phone is attached.
@MainActor
final class PhoneContinuityFlowTests: XCTestCase {
    private var folder: URL?
    private var signals: E2ESignals?
    private let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-e2e", isDirectory: true)
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        try? app.screenshot().pngRepresentation.write(to: outbox.appendingPathComponent("mac-\(name).png"))
    }

    private func signal(_ name: String, _ text: String = "") {
        signals?.put(name, text)
        try? Data(text.utf8).write(to: outbox.appendingPathComponent(name), options: .atomic)
    }

    private func awaitSignal(_ name: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let signals {
                if let text = signals.get(name) { return text }
            } else if let folder, let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
                return String(decoding: data, as: UTF8.self)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    /// Chooses the server in the continue sheet's picker, when it shows one.
    private func chooseServer(_ host: String) {
        let picker = app.sheets.popUpButtons["continuationServerPicker"].firstMatch
        guard picker.waitForExistence(timeout: 3) else { return }
        guard !(picker.value as? String ?? "").contains(host) else { return }
        picker.click()
        let item = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", host)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    func testPairAndTypeAlongsidePhone() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], let server = environment["WITERM_E2E_SERVER"],
              let host = URL(string: server)?.host,
              environment["WITERM_E2E_SIGNALS"] != nil || environment["WITERM_E2E_DIR"] != nil else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP, WITERM_E2E_SERVER, and WITERM_E2E_SIGNALS or WITERM_E2E_DIR")
        }
        folder = environment["WITERM_E2E_DIR"].map { URL(fileURLWithPath: $0) }
        signals = environment["WITERM_E2E_SIGNALS"].flatMap(URL.init(string:)).map(E2ESignals.init)
        try? FileManager.default.removeItem(at: outbox)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let enable = app.buttons["enableLocalTerminal"]
        if enable.waitForExistence(timeout: 3) { enable.click() }

        // A fresh session, the only one this test shares or ends: ⌘N opens
        // it at once, and Rename Session… (⇧⌘R) gives it this run's name.
        let name = "Phone E2E " + String(UUID().uuidString.prefix(6))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["localTerminalSurface"].firstMatch.waitForExistence(timeout: 15))
        app.typeKey("r", modifierFlags: [.command, .shift])
        let nameField = app.textFields["localSessionName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        app.buttons["renameLocalSession"].click()
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "localSession-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        addTeardownBlock { [app] in
            await MainActor.run {
                guard let app else { return }
                // A sheet left open by a failure would block the menu.
                for button in ["continueCancel", "continueDone"] where app.buttons[button].exists { app.buttons[button].click() }
                // Settings, left open by the revoke step, covers the session list.
                let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
                for _ in 0..<3 where settings.exists {
                    settings.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
                app.activate()
                guard row.waitForExistence(timeout: 3) else { return }
                if row.isHittable {
                    row.rightClick()
                    app.menuItems["endSessionMenu"].click()
                } else if app.windows.matching(NSPredicate(format: "title == %@", name)).firstMatch.exists {
                    // The row can be out of reach; Terminal → End Session acts
                    // on the selected session, which the title shows is this one.
                    app.menuBars.menuBarItems["Terminal"].click()
                    app.menuBars.menuItems.matching(NSPredicate(
                        format: "title == 'End Terminal…' OR title == 'End Session'")).firstMatch.click()
                } else { return }
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
            }
        }
        signal("session.txt", name)
        row.click()
        shot("01-session")

        // File ▸ Open On ▸ Choose a Device… (⌥⌘P): Server, Device, Approve, Open.
        app.typeKey("p", modifierFlags: [.command, .option])
        let title = app.staticTexts["continueStepTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        if title.label == "Connect This Mac" {
            chooseServer(host)
            let primary = app.buttons["continuePrimary"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Continue"), object: primary)
            if XCTWaiter.wait(for: [ready], timeout: 30) != .completed, title.label == "Connect This Mac" {
                XCTFail("Turn on remote access through \(host) before this run: \(primary.label)")
            }
            if title.label == "Connect This Mac" { primary.click() }
        }
        // With nothing paired, the sheet goes straight to the code;
        // otherwise choose Pair a New Device.
        let newDevice = app.descendants(matching: .any)["continueNewDevice"].firstMatch
        let copy = app.buttons["copyPairingInvitation"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !copy.exists, !newDevice.exists { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        if !copy.exists, newDevice.exists {
            newDevice.click()
            app.buttons["continuePrimary"].click()
        }
        XCTAssertTrue(copy.waitForExistence(timeout: 30), "The sheet didn't show a code")
        // The code step keeps its layout while the code is made; Copy turns
        // on once there's an invitation to copy.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, "The code was never made")
        // The server line combines its name and Change… into one element.
        XCTAssertTrue(app.sheets.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch.exists,
                      "The code step didn't name its server")
        shot("02-code")
        NSPasteboard.general.clearContents()
        copy.click()
        let invitation = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(invitation.hasPrefix("witerm://pair") && invitation.contains(host))
        signal("invitation.txt", invitation)

        // Approve with the defaults: this session only, and typing.
        let approve = app.buttons["continueApprove"]
        XCTAssertTrue(approve.waitForExistence(timeout: 240), "No pairing request arrived")
        // A phone that was already paired asks again; approving replaces its access.
        let replaces = app.descendants(matching: .any)["pairingReplacesGrant"].firstMatch.exists
        print("WITERM_E2E_REPAIR=\(replaces)")
        if environment["WITERM_E2E_EXPECT_REPAIR"] == "1" {
            XCTAssertTrue(replaces, "A re-pairing request should say it replaces the current access")
        }
        shot("03-request")
        approve.click()
        let done = app.buttons["continueDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 30))
        shot("04-approved")
        signal("approved")
        let connected = app.descendants(matching: .any)["continueConnected"].firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 300), "The sheet never saw the phone connect")
        shot("04b-connected")
        done.click()

        // Type alongside the phone in the same session.
        let phone = try XCTUnwrap(awaitSignal("phone-attached", timeout: 300), "The phone never attached")
        row.click()
        let terminal = app.descendants(matching: .any)["localTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        if (terminal.value(forKey: "hasKeyboardFocus") as? Bool) != true { terminal.click() }
        // A phone that can type brings Pause Remote Typing into the toolbar;
        // the window subtitle names it.
        let pause = app.descendants(matching: .any)["toggleRemoteTyping"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "The toolbar didn't show the attached phone")
        // Take turns, as people do: the grid stays with whoever is typing.
        XCTAssertNotNil(awaitSignal("phone-typed", timeout: 120), "The phone never typed")
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        app.typeText("echo MAC_TYPED\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Typing in turn moves the grid between the two, and its geometry
        // carries the name the test gave the terminal after opening it; the
        // window used to reject that and drop the terminal.
        XCTAssertTrue(terminal.exists, "The Mac window lost the terminal while typing together")
        XCTAssertFalse(app.staticTexts["Terminals on This Mac Need an Update"].exists, "The Mac rejected the renamed terminal's geometry")
        shot("05-together")
        signal("mac-typed")

        // Opt-in: a million lines while the phone is attached; the phone
        // checks it stays attached and shows the marker echoed afterwards.
        if environment["WITERM_E2E_BURST"] == "1" {
            XCTAssertNotNil(awaitSignal("phone-ready-for-burst", timeout: 240), "The phone never got ready for the burst")
            if (terminal.value(forKey: "hasKeyboardFocus") as? Bool) != true { terminal.click() }
            // The marker is computed, so the typed command never contains it.
            app.typeText("seq -f '%.0f' 1 1000000; echo BURST_$((6*7))_DONE\n")
            signal("mac-burst-started")
            XCTAssertNotNil(awaitSignal("phone-burst-ok", timeout: 360), "The phone didn't stay attached through the burst")
            XCTAssertTrue(terminal.exists, "The Mac window lost the terminal during the burst")
            XCTAssertTrue(pause.exists, "The Mac no longer shows the phone attached")
            shot("05b-burst")
        }
        XCTAssertNotNil(awaitSignal("phone-done", timeout: 300), "The phone didn't finish")
        shot("06-after")

        // Opt-in: the phone unpairs itself, and Settings → Devices drops it
        // without anything done here (the Mac rechecks every 10 seconds).
        if environment["WITERM_E2E_PHONE_UNPAIRS"] == "1" {
            app.typeKey(",", modifierFlags: .command)
            let devicesTab = app.toolbars.buttons["Devices"].firstMatch
            XCTAssertTrue(devicesTab.waitForExistence(timeout: 10))
            devicesTab.click()
            let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "editDevice-", phone)).firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 20))
            shot("07-paired")
            signal("mac-ready-for-unpair")
            XCTAssertNotNil(awaitSignal("phone-unpaired", timeout: 240), "The phone never unpaired")
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: edit)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 30), .completed, "The Mac kept listing a phone that unpaired itself")
            shot("08-phone-unpaired")
            return
        }

        // Revoke only this test's pairing, in Settings → Devices, unless the
        // next run should start paired to check re-pairing.
        if environment["WITERM_E2E_KEEP_PAIRING"] == "1" { return }
        app.typeKey(",", modifierFlags: .command)
        let devicesTab = app.toolbars.buttons["Devices"].firstMatch
        XCTAssertTrue(devicesTab.waitForExistence(timeout: 10))
        devicesTab.click()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "editDevice-", phone)).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        edit.click()
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "revokeGrant-")).firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 10))
        revoke.click()
        let confirm = app.buttons["action-button-1"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }
}

/// Signals exchanged with the phone's runner through the loopback server in
/// `scripts/e2e-signal-server.py`: PUT stores one, GET returns it or 404.
struct E2ESignals {
    let base: URL

    private final class Box: @unchecked Sendable { var text: String? }

    func put(_ name: String, _ text: String) {
        var request = URLRequest(url: base.appendingPathComponent("signal/\(name)"))
        request.httpMethod = "PUT"
        request.httpBody = Data(text.utf8)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
    }

    func get(_ name: String) -> String? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: base.appendingPathComponent("signal/\(name)")) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data { box.text = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return box.text
    }
}
