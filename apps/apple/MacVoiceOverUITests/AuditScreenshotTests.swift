import AppKit
import Foundation
import XCTest

/// Opt-in: walks the signed app through every Mac surface the UI/UX audit
/// (`docs/design/audit-mac.md`) reviews, in English light, English dark, and
/// Simplified Chinese, and attaches a cropped picture of each, plus the
/// accessibility tree of a few. Hover pictures rest the pointer first, so the
/// fill (never the pointer itself) is visible. Nothing here changes a paired
/// device, remote access, or the background service: the Continue sheet is
/// only opened and cancelled (a code it makes is rejected on close), Settings
/// is only looked at, and Return is never pressed in a sheet that could approve
/// or allow anything. It creates two terminals named "Audit A" and "Audit B"
/// and ends only those, and with a disposable OpenSSH fixture it creates,
/// connects, and deletes one host on 127.0.0.1. Set WITERM_HCI_FIXED_APP and
/// WITERM_AUDIT_SHOTS=1; WITERM_AUDIT_SSH_PORT and WITERM_AUDIT_SSH_FINGERPRINT
/// name the fixture, and WITERM_AUDIT_VARIANTS (default "en-light,en-dark,zh-light")
/// picks the passes.
@MainActor
final class AuditScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var variant = "en-light"
    private var metrics: [String] = []

    private struct Fixture { let port: String; let fingerprint: String }

    // MARK: Pictures

    /// The main window (or `base`), any open menu and sheet, from a full-screen picture.
    private func shot(_ name: String, base: XCUIElement? = nil, settle: TimeInterval = 0.8) {
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let screen = XCUIScreen.main.screenshot()
        var area = (base ?? mainWindow).frame
        for menu in app.menus.allElementsBoundByIndex where menu.exists && !menu.frame.isEmpty { area = area.union(menu.frame) }
        for sheet in app.sheets.allElementsBoundByIndex where sheet.exists && !sheet.frame.isEmpty { area = area.union(sheet.frame) }
        let image = screen.image
        let attachment: XCTAttachment
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let points = NSScreen.screens.first?.frame.size ?? image.size
            let scale = CGFloat(cg.width) / points.width
            let crop = area.insetBy(dx: -12, dy: -12).intersection(CGRect(origin: .zero, size: points))
            let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            if let cropped = cg.cropping(to: pixels) {
                attachment = XCTAttachment(image: NSImage(cgImage: cropped, size: crop.size))
            } else {
                attachment = XCTAttachment(screenshot: screen)
            }
        } else {
            attachment = XCTAttachment(screenshot: screen)
        }
        attachment.name = "\(variant)--\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The accessibility tree as XCTest sees it, for label and order review.
    private func tree(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "\(variant)--tree-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func hoverShot(_ element: XCUIElement, _ name: String, wait: TimeInterval = 0.8, base: XCUIElement? = nil) {
        guard element.exists, element.isHittable else { metrics.append("\(variant) \(name): not hittable"); return }
        element.hover()
        shot(name, base: base, settle: wait)
    }

    private var mainWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "NOT (identifier CONTAINS[c] 'settings')")).firstMatch
    }

    private var settingsWindow: XCUIElement {
        let match = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        return match.exists ? match : app.windows.firstMatch
    }

    private func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// The first element of `query` whose label is one of `labels`.
    private func labeled(_ query: XCUIElementQuery, _ labels: [String]) -> XCUIElement? {
        for label in labels {
            let element = query[label].firstMatch
            if element.exists { return element }
        }
        return nil
    }

    private func menuBar(_ titles: [String]) -> XCUIElement? { labeled(app.menuBars.menuBarItems, titles) }

    // MARK: Test

    func testCaptureAuditScreens() throws {
        continueAfterFailure = true
        executionTimeAllowance = 1800
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], environment["WITERM_AUDIT_SHOTS"] == "1" else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_AUDIT_SHOTS=1")
        }
        var fixture: Fixture?
        if let port = environment["WITERM_AUDIT_SSH_PORT"], let number = Int(port), (1...65535).contains(number),
           let fingerprint = environment["WITERM_AUDIT_SSH_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") {
            fixture = Fixture(port: port, fingerprint: fingerprint)
        }
        let variants = (environment["WITERM_AUDIT_VARIANTS"] ?? "en-light,en-dark,zh-light")
            .split(separator: ",").map(String.init)
        for name in variants {
            variant = name
            walk(path: path, fixture: name == variants.first ? fixture : nil, full: name != "en-dark")
        }
        let summary = XCTAttachment(string: metrics.joined(separator: "\n"))
        summary.name = "metrics"
        summary.lifetime = .keepAlways
        add(summary)
    }

    private func launchArguments() -> [String] {
        var arguments = ["-witerm.onboarding.completedVersion", "1"]
        arguments += variant.hasPrefix("zh") ? ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
                                             : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        arguments += ["-AppleInterfaceStyle", variant.hasSuffix("dark") ? "Dark" : "Light"]
        return arguments
    }

    // MARK: One pass

    private func walk(path: String, fixture: Fixture?, full: Bool) {
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = launchArguments()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15))
        pause(2)
        endTerminals(named: "Audit ")

        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "localSession-"))
        let terminal = any("localTerminalSurface")
        guard let first = newTerminal(rows: rows, terminal: terminal, name: "Audit A", captureRename: true),
              let second = newTerminal(rows: rows, terminal: terminal, name: "Audit B", captureRename: false) else {
            XCTFail("Couldn't create the audit terminals"); return
        }
        let rowA = any(first), rowB = any(second)

        // An open terminal, typing.
        shot("01-main-typing")
        if variant == "en-light" { tree("main-typing") }
        hoverShot(rowA, "02-hover-sidebar-row")
        hoverShot(rowB, "03-hover-sidebar-selected-row")
        hoverShot(any("newMenu"), "04-hover-toolbar-new", wait: 2.5)
        hoverShot(any("shareLocalSession"), "05-hover-toolbar-open-on-tooltip", wait: 2.5)

        // The row's context menu and its submenus.
        rowB.rightClick()
        shot("06-menu-context-typing")
        if let openOn = [app.menuItems["openOnMenu"], app.menuItems["Open On"], app.menuItems["打开于"]].first(where: \.exists) {
            openOn.hover(); shot("07-menu-context-open-on")
        }
        if let sharing = [app.menuItems["sharingMenu"], app.menuItems["Sharing"], app.menuItems["共享"]].first(where: \.exists) {
            sharing.hover(); shot("08-menu-context-sharing")
        }
        app.typeKey(.escape, modifierFlags: []); app.typeKey(.escape, modifierFlags: [])
        let more = any("localTerminalMore")
        if more.waitForExistence(timeout: 5) {
            more.click(); shot("09-menu-toolbar-more")
            app.typeKey(.escape, modifierFlags: [])
        }

        // Watching, then left.
        rowB.rightClick()
        if app.menuItems["watchLocalSession"].waitForExistence(timeout: 3) { app.menuItems["watchLocalSession"].click() }
        _ = any("startTypingLocal").waitForExistence(timeout: 10)
        shot("10-main-watching")
        hoverShot(any("startTypingLocal"), "11-hover-toolbar-start-typing", wait: 2.5)
        if more.exists {
            more.click()
            if app.menuItems["detachLocalTerminal"].waitForExistence(timeout: 3) { app.menuItems["detachLocalTerminal"].click() }
        }
        let open = any("reconnectLocalTerminal")
        if open.waitForExistence(timeout: 10) {
            shot("12-main-still-running")
            hoverShot(open, "13-hover-primary-open")
            hoverShot(any("viewLocalTerminal"), "14-hover-bordered-watch")
            open.click()
            _ = terminal.waitForExistence(timeout: 10)
        }

        continueSheet(row: rowB)
        if full || variant == "en-dark" { settings() }
        sshForm(fixture: fixture)
        if full { menus() }
        tour()

        // Ending a terminal: the confirmation, then the overview.
        rowA.rightClick()
        if app.menuItems["endSessionMenu"].waitForExistence(timeout: 3) {
            app.menuItems["endSessionMenu"].click()
            let confirm = app.buttons["action-button-1"]
            if confirm.waitForExistence(timeout: 5) { shot("60-alert-end-terminal"); confirm.click() }
        }
        endTerminals(named: "Audit ")
        pause(1)
        shot("61-main-after-ending")
    }

    /// ⌘N, then Rename Terminal… (⇧⌘R). Returns the new row's identifier.
    private func newTerminal(rows: XCUIElementQuery, terminal: XCUIElement, name: String, captureRename: Bool) -> String? {
        let before = Set(rows.allElementsBoundByIndex.map(\.identifier))
        let started = Date()
        app.typeKey("n", modifierFlags: .command)
        var created: String?
        let deadline = Date().addingTimeInterval(15)
        while created == nil, Date() < deadline {
            created = rows.allElementsBoundByIndex.first { !before.contains($0.identifier) }?.identifier
            if created == nil { pause(0.1) }
        }
        _ = terminal.waitForExistence(timeout: 15)
        metrics.append("\(variant) ⌘N to terminal on screen: \(String(format: "%.2f", Date().timeIntervalSince(started))) s (XCTest polling included)")
        guard let created else { return nil }
        app.typeKey("r", modifierFlags: [.command, .shift])
        let field = app.textFields["localSessionName"]
        if field.waitForExistence(timeout: 5) {
            field.typeKey("a", modifierFlags: .command)
            if captureRename {
                field.typeText("\u{7F}")
                app.buttons["renameLocalSession"].click()
                shot("00-rename-sheet-empty-error")
                field.click()
            }
            field.typeText(name + "\r")
            _ = field.waitForNonExistence(timeout: 5)
        }
        return created
    }

    /// Ends every terminal whose name starts with `prefix`, and no other.
    private func endTerminals(named prefix: String) {
        let mine = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "localSession-", prefix))
        for _ in 0..<6 {
            let row = mine.firstMatch
            guard row.exists else { break }
            row.rightClick()
            guard app.menuItems["endSessionMenu"].waitForExistence(timeout: 3) else { app.typeKey(.escape, modifierFlags: []); break }
            app.menuItems["endSessionMenu"].click()
            let confirm = app.buttons["action-button-1"]
            if confirm.waitForExistence(timeout: 5) { confirm.click() }
            _ = row.waitForNonExistence(timeout: 10)
        }
    }

    // MARK: Open On ▸

    /// Each entry to the sheet, looked at and cancelled. Never Return here:
    /// the device step's default action would allow a real paired device.
    private func continueSheet(row: XCUIElement) {
        let title = app.staticTexts["continueStepTitle"]
        let cancel = app.buttons["continueCancel"]
        func close() {
            if cancel.exists { cancel.click() } else { app.typeKey(.escape, modifierFlags: []) }
            _ = title.waitForNonExistence(timeout: 5)
        }
        app.typeKey("p", modifierFlags: [.command, .option])
        if title.waitForExistence(timeout: 10) {
            pause(3)
            shot("20-continue-first-step")
            if variant == "en-light" { tree("continue-first-step") }
            hoverShot(any("continueGuest"), "21-hover-continue-choice-card")
            hoverShot(cancel, "22-hover-continue-cancel")
            close()
        }
        for (identifier, name) in [("openOnNewDevice", "23-continue-code"), ("openOnSomeoneElse", "24-continue-invite")] {
            row.rightClick()
            if let openOn = [app.menuItems["openOnMenu"], app.menuItems["Open On"], app.menuItems["打开于"]].first(where: \.exists) {
                openOn.hover()
                let item = app.menuItems[identifier]
                if item.waitForExistence(timeout: 3) {
                    item.click()
                    if title.waitForExistence(timeout: 10) {
                        pause(4)
                        shot(name)
                        close()
                    }
                } else { app.typeKey(.escape, modifierFlags: []); app.typeKey(.escape, modifierFlags: []) }
            } else { app.typeKey(.escape, modifierFlags: []) }
        }
    }

    // MARK: Settings

    private func settings() {
        app.typeKey(",", modifierFlags: .command)
        pause(1.5)
        let tabs: [(String, [String])] = [("general", ["General", "通用"]), ("terminal", ["Terminal", "终端"]),
                                          ("snippets", ["Snippets", "片段"]), ("devices", ["Devices", "设备"]),
                                          ("command-line", ["Command Line", "命令行"])]
        for (index, (name, labels)) in tabs.enumerated() {
            guard let tab = labeled(settingsWindow.toolbars.buttons, labels) ?? labeled(app.toolbars.buttons, labels) else {
                metrics.append("\(variant) settings tab \(name) not found"); continue
            }
            tab.click()
            pause(name == "devices" ? 3 : 1)
            shot("3\(index)-settings-\(name)", base: settingsWindow)
            switch name {
            case "snippets":
                let add = any("addSnippet")
                if add.exists {
                    add.click()
                    pause(1)
                    shot("35-settings-snippet-editor", base: settingsWindow)
                    app.typeKey(.escape, modifierFlags: [])
                    pause(0.5)
                }
            case "devices":
                if variant == "en-light" { tree("settings-devices") }
                hoverShot(any("primaryAction"), "36-hover-settings-check-now", base: settingsWindow)
                hoverShot(any("createPairingInvitation"), "37-hover-settings-pair-link", base: settingsWindow)
                let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editDevice-")).firstMatch
                if edit.exists {
                    edit.click()
                    pause(2)
                    shot("38-settings-device-edit", base: settingsWindow)
                    if let done = labeled(app.sheets.firstMatch.buttons, ["Done", "完成"]) { done.click() }
                    pause(1)
                }
                let manage = any("manageServers")
                if manage.exists {
                    manage.click()
                    pause(1.5)
                    shot("39-settings-manage-servers", base: settingsWindow)
                    if let done = labeled(app.sheets.firstMatch.buttons, ["Done", "完成"]) { done.click() }
                    pause(1)
                }
            default: break
            }
        }
        app.typeKey("w", modifierFlags: .command)
        pause(1)
    }

    // MARK: SSH

    private func sshForm(fixture: Fixture?) {
        app.typeKey("n", modifierFlags: [.command, .shift])
        let address = app.textFields["sshHostAddress"]
        guard address.waitForExistence(timeout: 5) else { return }
        shot("40-ssh-form-new")
        app.buttons["sshConnect"].click()
        shot("41-ssh-form-empty-errors")
        app.buttons["sshMoreOptions"].click()
        shot("42-ssh-form-more-options")
        app.typeKey(.escape, modifierFlags: [])
        _ = address.waitForNonExistence(timeout: 5)
        if !address.exists {
            // Cancel is a toolbar item; Escape may not reach it.
        } else if let cancel = labeled(app.sheets.firstMatch.buttons, ["Cancel", "取消"]) {
            cancel.click()
        }

        // A host made here only: the fixture (connected), or a placeholder (never connected).
        let suffix = String(UUID().uuidString.prefix(4))
        let hostName = "Audit Host " + suffix
        app.typeKey("n", modifierFlags: [.command, .shift])
        guard address.waitForExistence(timeout: 5) else { return }
        address.click()
        address.typeText(fixture.map { "fixture@127.0.0.1:" + $0.port } ?? "fixture@127.0.0.1:1")
        app.buttons["sshMoreOptions"].click()
        let nameField = app.textFields["sshProfileName"]
        if nameField.waitForExistence(timeout: 5) { nameField.click(); nameField.typeText(hostName) }
        let hostRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", hostName)).firstMatch
        if let fixture {
            let password = app.secureTextFields.matching(identifier: "sshHostPassword").firstMatch
            password.click(); password.typeText("witerm-fixture-only")
            let started = Date()
            app.buttons["sshConnect"].click()
            let identity = app.staticTexts["sshHostFingerprint"]
            if identity.waitForExistence(timeout: 20) {
                metrics.append("\(variant) Connect to trust sheet: \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                let label = identity.label + " " + (identity.value as? String ?? "")
                guard label.contains(fixture.fingerprint) else {
                    XCTFail("Unexpected fixture fingerprint; not trusting it")
                    app.typeKey(.escape, modifierFlags: [])
                    return
                }
                shot("43-ssh-trust-sheet")
                hoverShot(app.buttons["sshTrustHost"], "44-hover-ssh-trust")
                app.buttons["sshTrustHost"].click()
                let surface = any("sshTerminalSurface")
                if surface.waitForExistence(timeout: 20) {
                    pause(2)
                    shot("45-ssh-connected")
                    hoverShot(any("sshDisconnect"), "46-hover-ssh-disconnect-tooltip", wait: 2.5)
                    for (identifier, name) in [("sshFiles", "47-ssh-sftp"), ("sshForwarding", "48-ssh-forwarding")] {
                        let button = any(identifier)
                        guard button.exists else { continue }
                        button.click()
                        pause(2)
                        shot(name)
                        if let done = labeled(app.sheets.firstMatch.buttons, ["Done", "完成"]) { done.click() }
                        pause(1)
                    }
                    hostRow.rightClick()
                    shot("49-menu-ssh-connected")
                    app.typeKey(.escape, modifierFlags: [])
                    any("sshDisconnect").click()
                    _ = any("sshConnectProfile").waitForExistence(timeout: 10)
                }
            } else {
                shot("43-ssh-connect-no-trust-sheet")
                app.typeKey(.escape, modifierFlags: [])
                if let cancel = labeled(app.sheets.firstMatch.buttons, ["Cancel", "取消"]) { cancel.click() }
            }
        } else {
            app.buttons["sshSaveOnly"].click()
            if hostRow.waitForExistence(timeout: 10) { hostRow.click() }
        }
        guard hostRow.waitForExistence(timeout: 10) else { return }
        hostRow.click()
        pause(1)
        shot("50-ssh-host-page")
        hoverShot(any("sshConnectProfile"), "51-hover-ssh-connect-primary")
        hoverShot(any("sshEditProfile"), "52-hover-ssh-edit-bordered")
        let hostID = String(hostRow.identifier.dropFirst("sshProfileRow-".count))
        let actions = any("sshProfileActions-\(hostID)")
        if actions.exists {
            hoverShot(actions, "53-hover-ssh-more")
            actions.click()
            shot("54-menu-ssh-more")
            app.typeKey(.escape, modifierFlags: [])
        }
        hostRow.rightClick()
        shot("55-menu-ssh-context")
        let keys = [app.menuItems["Host Keys"], app.menuItems["主机密钥"]].first(where: \.exists)
        if let keys {
            keys.click()
            pause(1.5)
            shot("56-ssh-host-keys")
            if let done = labeled(app.sheets.firstMatch.buttons, ["Done", "完成"]) { done.click() }
            pause(1)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        hostRow.rightClick()
        if app.menuItems["sshDeleteHostMenu"].waitForExistence(timeout: 3) {
            app.menuItems["sshDeleteHostMenu"].click()
            XCTAssertTrue(hostRow.waitForNonExistence(timeout: 10), "The audit host is still listed")
            pause(0.6)
            shot("57-ssh-undo-bar")
        }
    }

    // MARK: Menus and tour

    private func menus() {
        let bars: [(String, [String])] = [("file", ["File", "文件"]), ("edit", ["Edit", "编辑"]), ("view", ["View", "显示"]),
                                          ("terminal", ["Terminal", "终端"]), ("help", ["Help", "帮助"])]
        for (name, titles) in bars {
            guard let item = menuBar(titles) else { metrics.append("\(variant) menu \(name) not found"); continue }
            item.click()
            shot("2\(5 + bars.firstIndex { $0.0 == name }!)-menubar-\(name)")
            app.typeKey(.escape, modifierFlags: [])
        }
        if let file = menuBar(["File", "文件"]) {
            file.click()
            if let importItem = [app.menuItems["Import SSH Hosts…"], app.menuItems["导入 SSH 主机…"]].first(where: \.exists) {
                importItem.click()
                pause(1)
                shot("58-ssh-import-sheet")
                if let cancel = labeled(app.sheets.firstMatch.buttons, ["Cancel", "取消"]) { cancel.click() } else { app.typeKey(.escape, modifierFlags: []) }
                pause(0.8)
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }
    }

    private func tour() {
        guard let help = menuBar(["Help", "帮助"]) else { return }
        help.click()
        guard let item = [app.menuItems["Welcome Tour"], app.menuItems["欢迎导览"]].first(where: \.exists) else {
            app.typeKey(.escape, modifierFlags: []); return
        }
        item.click()
        let tour = any("welcomeTour")
        guard tour.waitForExistence(timeout: 5) else { return }
        for page in 1...4 {
            shot("7\(page)-tour-page-\(page)")
            // Next, never Get Started on the last page (it would open a terminal).
            if page < 4 { app.buttons["welcomeTourPrimary"].click() }
        }
        app.buttons["welcomeTourSkip"].click()
        _ = tour.waitForNonExistence(timeout: 5)
    }
}
