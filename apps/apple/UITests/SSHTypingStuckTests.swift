import XCTest

/// Round 20, against the disposable OpenSSH fixture only: the owner's
/// "after entering `ls`, it got stuck, and I couldn't scroll" on the iPhone.
/// `ls` is typed on the system's software keyboard, key by key (falling back
/// to XCUITest's typing when the simulator shows no software keyboard), in a
/// folder with a few entries and one with more than a screenful, in color,
/// with the keyboard down (text under the floating keyboard button) and in
/// landscape. After each, the output must arrive, typing must still reach
/// the host, and a swipe must scroll. Prints `PROBE r20` lines. The host and
/// the fixture's pin are removed at the end; nothing else is touched.
@MainActor final class SSHTypingStuckTests: XCTestCase {
    fileprivate var app: XCUIApplication!

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    fileprivate var terminal: XCUIElement { app.descendants(matching: .any)["sshTerminalSurface"].firstMatch }
    fileprivate var keyboard: XCUIElement { app.keyboards.firstMatch }
    fileprivate func text() -> String { terminal.exists ? (terminal.value as? String ?? "") : "" }
    fileprivate func lines() -> [String] {
        text().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    fileprivate func lastLine() -> String { lines().last { !$0.isEmpty } ?? "" }
    fileprivate func probe(_ key: String) -> Double? {
        guard terminal.exists else { return nil }
        let label = terminal.label
        guard let range = label.range(of: " " + key + "=") else { return nil }
        return Double(label[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" })
    }
    private func keyboardDiagnostics() -> String {
        guard terminal.exists, let range = terminal.label.range(of: "kbdiag=[") else { return "" }
        return String(terminal.label[range.upperBound...].prefix { $0 != "]" })
    }
    fileprivate func now() -> Double { Date().timeIntervalSinceReferenceDate }

    fileprivate func until(_ timeout: TimeInterval, poll: TimeInterval = 0.1, _ condition: () -> Bool) -> Double? {
        let start = now()
        while now() - start < timeout {
            if condition() { return now() - start }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        return condition() ? now() - start : nil
    }

    fileprivate func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["WITERM_SHOTS_DIR"] {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    fileprivate func launch(snippets: [(String, String)], chinese: Bool? = nil) {
        let app = XCUIApplication()
        self.app = app
        let list: [[String: Any]] = snippets.enumerated().map {
            ["id": "7C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5\($0.offset)", "name": $0.element.0, "text": $0.element.1, "runsImmediately": true]
        }
        let json = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let environment = ProcessInfo.processInfo.environment
        // `WITERM_R20_CHINESE=1`: the owner's language.
        let language = chinese ?? (environment["WITERM_R20_CHINESE"] == "1") ? ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = ["-witerm.onboarding.completedVersion", "1", "--witerm-ui-test-steady-terminal-cursor",
                               "--witerm-ui-test-layout-probe", "-witerm.commandSnippets", "<\(hex)>"] + language
        // `WITERM_SHOW_TIP=1` keeps the first-use background tip above the
        // terminal, as on a phone's first SSH connection.
        if environment["WITERM_SHOW_TIP"] != "1" { app.launchArguments += ["-witerm.sshBackgroundTipSeen", "YES"] }
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let tab = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.buttons["newSSHProfile"].waitForExistence(timeout: 10))
    }

    fileprivate func fixture() throws -> (port: String, fingerprint: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["WITERM_SSH_UI_PORT"], Int(port) != nil,
              let fingerprint = environment["WITERM_SSH_UI_FINGERPRINT"], fingerprint.hasPrefix("SHA256:") else {
            throw XCTSkip("Configure a disposable SSH UI fixture explicitly")
        }
        return (port, fingerprint)
    }

    fileprivate func connect(port: String, fingerprint: String, name: String) {
        app.buttons["newSSHProfile"].tap()
        let address = app.textFields["sshHostAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("fixture@127.0.0.1:" + port)
        app.buttons["sshMoreOptions"].tap()
        let nameField = app.textFields["sshProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        for _ in 0..<4 where !nameField.isHittable { app.swipeUp() }
        nameField.tap(); nameField.typeText(name)
        let password = app.secureTextFields["sshHostPassword"]
        for _ in 0..<4 where !password.isHittable { app.swipeDown() }
        password.tap(); password.typeText("witerm-fixture-only")
        let connect = app.buttons["sshConnect"]
        for _ in 0..<4 where !connect.isHittable { app.swipeUp() }
        connect.tap()
        let identity = app.staticTexts["sshHostFingerprint"]
        XCTAssertNotNil(until(20) { identity.exists }, "The fixture's key must be reviewed first")
        XCTAssertTrue(identity.label.contains(fingerprint), "Unexpected fixture host fingerprint")
        let trust = app.buttons["sshTrustHost"]
        XCTAssertNotNil(until(10) { trust.isHittable })
        trust.tap()
        XCTAssertNotNil(until(20) { lastLine().hasSuffix("~$") }, "The connection never showed a prompt")
    }

    fileprivate func removeHost(named name: String, fingerprint: String) {
        if !app.buttons["sshSessionActions"].isHittable, app.buttons["terminalKey-hideKeyboard"].exists {
            app.buttons["terminalKey-hideKeyboard"].tap()
        }
        if app.buttons["sshSessionActions"].waitForExistence(timeout: 5) {
            app.buttons["sshSessionActions"].tap()
            app.buttons["Disconnect"].tap()
            _ = app.buttons["sshReconnect"].waitForExistence(timeout: 5)
        }
        app.buttons["sshShowHosts"].tap()
        removeListedHost(named: name, fingerprint: fingerprint)
    }

    /// Removes a host this test made from the list, with its pin only when it's the fixture's.
    fileprivate func removeListedHost(named name: String, fingerprint: String) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "sshProfileRow-", name)).firstMatch
        guard row.waitForExistence(timeout: 5) else { return XCTFail("The test's host row is missing") }
        let id = String(row.identifier.dropFirst("sshProfileRow-".count))
        let actions = app.buttons["sshProfileActions-" + id]
        actions.tap()
        app.buttons["Host Keys"].tap()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch
        if remove.waitForExistence(timeout: 5),
           app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fingerprint)).firstMatch.exists {
            remove.tap()
            let confirm = app.buttons["sshConfirmForgetHostKey"].firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        app.buttons["Done"].tap()
        actions.tap()
        app.buttons["Delete Host"].tap()
        let dismiss = app.buttons["sshUndoDismiss"]
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
    }

    // MARK: Typing

    /// Whether the system's software keyboard (not only the key row) is up.
    private var softwareKeyboardUp: Bool { keyboard.exists && keyboard.keys.count > 10 }
    private(set) var typedBySoftwareKeys = 0
    private(set) var typedByHardwareEvents = 0
    private var echoes = 0

    private func showKeyboard() {
        guard !app.buttons["terminalKey-hideKeyboard"].exists else { return }
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { app.buttons["terminalKey-hideKeyboard"].exists }, "The keyboard didn't come up")
    }

    /// Types `command` and Return on the software keyboard's own keys, the
    /// way a person does; with no software keyboard, XCUITest's typing.
    private func type(_ command: String) {
        showKeyboard()
        _ = until(2) { softwareKeyboardUp }
        guard softwareKeyboardUp else {
            typedByHardwareEvents += 1
            terminal.typeText(command + "\n")
            return
        }
        typedBySoftwareKeys += 1
        for character in command {
            let key = character == " " ? keyboard.keys["space"] : keyboard.keys[String(character)]
            if !key.exists, keyboard.buttons["shift"].exists, character.isUppercase { keyboard.buttons["shift"].tap() }
            guard key.exists else { return XCTFail("No \(character) key on the software keyboard") }
            key.tap()
        }
        let candidates = [keyboard.buttons["Return"], keyboard.buttons["return"], keyboard.keys["Return"], keyboard.keys["return"]]
        guard let enter = candidates.first(where: { $0.exists }) else { return XCTFail("No Return key on the software keyboard") }
        enter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: Checks

    /// After a command: its output arrives and the prompt returns; typing
    /// still reaches the host; a swipe moves the view when there's
    /// scrollback. Returns a one-line report.
    @discardableResult
    private func check(_ step: String, expect marker: String, scrollable: Bool) -> String {
        let started = now()
        let output = until(8) { text().contains(marker) && lastLine().hasSuffix("$") }
        let outputSeconds = output.map { String(format: "%.2f", $0) } ?? "never"
        shot("r20-\(step)-1-output")
        // The layout as the output landed: the grid, the rows that fit the
        // text area, and the rows past it (under the keyboard).
        print("PROBE r20 layout step=\(step) grid=\(Int(probe("cols") ?? -1))x\(Int(probe("rows") ?? -1)) fitRows=\(Int(probe("fitRows") ?? -1)) "
              + "gap=\(probe("gap") ?? -1) overflow=\(probe("overflow") ?? -1) focused=\(Int(probe("focused") ?? -1)) kbdiag=\(keyboardDiagnostics())")
        // Typing still reaches the host: an echo the host prints back.
        echoes += 1
        let token = "okay" + String(UnicodeScalar(UInt8(96 + echoes % 26 + 1)))
        let typeStart = now()
        type("echo " + token)
        let echoed = until(8) { lines().contains(token) && lastLine().hasSuffix("$") }
        let typing = now() - typeStart
        var scrolled = "n/a"
        if scrollable {
            let before = probe("yDisp") ?? -1
            let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)), withVelocity: .default, thenHoldForDuration: 0.05)
            let moved = until(4) { (probe("yDisp") ?? before) < before }
            let after = probe("yDisp") ?? -1
            scrolled = moved != nil ? "yes(\(Int(before))->\(Int(after)))" : "NO(\(Int(before))->\(Int(after)))"
            shot("r20-\(step)-2-scrolled")
            // Back to the newest output.
            let latest = app.buttons["terminalJumpToLatest"]
            if latest.exists, latest.isHittable { latest.tap() }
            _ = until(3) { (probe("pos") ?? 0) >= 0.999 }
        }
        let report = "PROBE r20 step=\(step) output=\(outputSeconds) echoed=\(echoed.map { String(format: "%.2f", $0) } ?? "never") "
            + String(format: "typing=%.2f ", typing) + "scrolled=\(scrolled) softKeys=\(typedBySoftwareKeys) hwEvents=\(typedByHardwareEvents) "
            + "grid=\(Int(probe("cols") ?? -1))x\(Int(probe("rows") ?? -1)) pos=\(probe("pos") ?? -1) focused=\(Int(probe("focused") ?? -1)) "
            + "covers=\(Int(probe("covers") ?? -1)) " + String(format: "total=%.2f", now() - started)
        print(report)
        XCTAssertNotNil(output, "\(step): the output of the command never arrived\n\(text())")
        XCTAssertNotNil(echoed, "\(step): typing after the command never reached the host\n\(text())")
        XCTAssertLessThan(typing, 20, "\(step): typing took \(typing) s (the app never idles?)")
        if scrollable { XCTAssertTrue(scrolled.hasPrefix("yes"), "\(step): a swipe didn't scroll back (\(scrolled))") }
        return report
    }

    func testLsThenTypingAndScrollingStillWork() throws {
        continueAfterFailure = true
        executionTimeAllowance = 900
        let (port, fingerprint) = try fixture()
        // Folders with a few and with many entries, in the fixture's home.
        launch(snippets: [("Setup", "mkdir -p few many; touch few/a few/b; cd many; for i in $(seq 1 240); do touch file-$i; done; cd"),
                          ("Color", "ls --color=always /etc"), ("Long", "seq 1 400"),
                          ("Prompt", #"alias ls='ls --color=auto'; PS1="$(printf '\033]0;fixture@r20: ~\007\033]7;file://r20/home/fixture\007')\u@\h:\w\$ ""#)])
        let name = "R20 Ls " + String(UUID().uuidString.prefix(4))
        connect(port: port, fingerprint: fingerprint, name: name)
        _ = until(2) { false }
        print("PROBE r20 keyboard software=\(softwareKeyboardUp) keys=\(keyboard.exists ? keyboard.keys.count : -1)")
        shot("r20-0-connected")

        // `WITERM_R20_PROMPT=1`: a prompt like a Linux distribution's bash,
        // which sets the window title and folder each time (OSC 0 and 7),
        // with ls in color, as on the owner's server (unknown, so guessed).
        if ProcessInfo.processInfo.environment["WITERM_R20_PROMPT"] == "1" {
            app.runTerminalSnippet("Prompt")
            _ = until(5) { lastLine().hasSuffix("$") }
        }
        // The owner's case: the first thing typed is ls.
        type("ls")
        check("ls-home", expect: "$ ls", scrollable: false)
        // Few entries.
        type("cd few")
        type("ls")
        check("ls-few", expect: "a", scrollable: false)
        type("cd")
        // Set up a folder with more than a screenful, then ls there.
        app.runTerminalSnippet("Setup")
        _ = until(10) { lastLine().hasSuffix("~$") }
        type("cd many")
        type("ls")
        check("ls-many", expect: "file-99", scrollable: true)
        // Colored output.
        app.runTerminalSnippet("Color")
        check("ls-color", expect: "hosts", scrollable: true)
        // With the keyboard down: output lands under the floating button.
        app.toggleTerminalKeyboard()
        XCTAssertNotNil(until(5) { app.buttons["sshKeyboard"].exists })
        shot("r20-keyboard-down-before")
        type("ls")
        app.toggleTerminalKeyboard()
        _ = until(5) { app.buttons["sshKeyboard"].exists }
        check("ls-keyboard-down", expect: "file-99", scrollable: true)
        // Landscape.
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = until(2) { false }
        type("ls")
        check("ls-landscape", expect: "file-99", scrollable: true)
        XCUIDevice.shared.orientation = .portrait
        _ = until(2) { false }
        type("cd")
        removeHost(named: name, fingerprint: fingerprint)
    }
}

extension SSHTypingStuckTests {
    /// The keyboard's Return, whatever it's called while composing.
    fileprivate func returnKey() -> XCUIElement? {
        let names = ["Return", "return", "换行", "确认", "Confirm", "confirm", "前往", "Go"]
        for name in names {
            for element in [keyboard.buttons[name], keyboard.keys[name]] where element.exists { return element }
        }
        return nil
    }

    /// Round 20: the owner's language is Chinese, and in a Chinese app the
    /// iPhone's keyboard is Pinyin. Letters typed there are composed (marked
    /// text) until a candidate or Confirm (the Return key, renamed while
    /// composing) commits them; Confirm only puts the letters on the line,
    /// as in every iOS text field and in the Mac's Terminal. Before the fix
    /// the terminal drew nothing while composing, so typing `ls` and
    /// pressing Return showed nothing, then only `ls`, and nothing ran: a
    /// terminal that looked stuck, with nothing to scroll. Now the letters
    /// show at the cursor, underlined, while they're composed; Confirm puts
    /// them on the line; Return runs them.
    func testLsOnAComposingKeyboardRuns() throws {
        continueAfterFailure = true
        executionTimeAllowance = 600
        let (port, fingerprint) = try fixture()
        launch(snippets: [], chinese: true)
        let name = "R20 Pinyin " + String(UUID().uuidString.prefix(4))
        connect(port: port, fingerprint: fingerprint, name: name)
        _ = until(2) { false }
        let keys = keyboard.exists ? keyboard.keys.count : -1
        let space = keyboard.keys["space"].exists ? keyboard.keys["space"].label : "-"
        print("PROBE r20 pinyin keyboard keys=\(keys) space=\(space)")
        shot("r20-pinyin-0-connected")
        let prompts = { [self] in lines().filter { $0.hasSuffix("~$") || $0.contains("~$ ") }.count }
        let before = prompts()
        for letter in ["l", "s"] {
            let key = keyboard.keys[letter]
            XCTAssertTrue(key.exists, "No \(letter) key")
            key.tap()
        }
        _ = until(1) { false }
        shot("r20-pinyin-1-composing")
        let composing = until(3) { probe("composingShown") == 1 }
        print("PROBE r20 pinyin composing marked=\(probe("marked") ?? -1) shown=\(probe("composingShown") ?? -1) lastLine=\(lastLine().hasSuffix("ls") ? "ends-with-ls" : "no-ls")")
        XCTAssertNotNil(composing, "The letters being composed must show at the cursor")
        XCTAssertFalse(lastLine().hasSuffix("ls"), "Composed letters aren't sent before they're committed")
        guard let confirm = returnKey() else { return XCTFail("No Return key") }
        print("PROBE r20 pinyin return-key label=\(confirm.label)")
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let committed = until(5) { lastLine().hasSuffix("$ ls") && probe("composingShown") == 0 }
        shot("r20-pinyin-2-after-confirm")
        print("PROBE r20 pinyin confirm committed=\(committed.map { String(format: "%.2f", $0) } ?? "no") ran=\(prompts() > before) "
              + "shown=\(probe("composingShown") ?? -1)")
        XCTAssertNotNil(committed, "Confirm puts the composed letters on the line (\(lastLine()))")
        guard let enter = returnKey() else { return XCTFail("No Return key") }
        print("PROBE r20 pinyin return-key label=\(enter.label)")
        enter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let ran = until(5) { prompts() > before && lastLine().hasSuffix("$") }
        shot("r20-pinyin-3-after-return")
        print("PROBE r20 pinyin return ran=\(ran.map { String(format: "%.2f", $0) } ?? "no")")
        XCTAssertNotNil(ran, "Return then runs ls")
        // A candidate still types Chinese, which the shell echoes back.
        for letter in ["n", "i"] where keyboard.keys[letter].exists { keyboard.keys[letter].tap() }
        _ = until(1) { false }
        let candidate = app.keyboards.buttons.matching(NSPredicate(format: "label == %@", "你")).firstMatch
        let candidateShown = until(3) { candidate.exists } != nil
        if candidateShown { candidate.tap() }
        _ = until(2) { false }
        shot("r20-pinyin-4-candidate")
        print("PROBE r20 pinyin candidate shown=\(candidateShown) typed=\(lastLine().hasSuffix("你"))")
        if candidateShown { XCTAssertTrue(lastLine().hasSuffix("你"), "A chosen candidate types it (\(lastLine()))") }
        // Clean up in English, where the test knows the menus' names.
        app.terminate()
        launch(snippets: [], chinese: false)
        removeListedHost(named: name, fingerprint: fingerprint)
    }

    /// Removes hosts these tests left after an interrupted run (their names
    /// start "R20 "), each with the fixture's pin. Opt-in:
    /// `WITERM_SSH_UI_CLEANUP=1`.
    func testRemoveLeftoverR20Hosts() throws {
        guard ProcessInfo.processInfo.environment["WITERM_SSH_UI_CLEANUP"] == "1" else {
            throw XCTSkip("Explicit leftover fixture cleanup only")
        }
        let (_, fingerprint) = try fixture()
        launch(snippets: [], chinese: false)
        let leftovers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "sshProfileRow-", "R20 "))
        for _ in 0..<8 where leftovers.firstMatch.waitForExistence(timeout: 3) {
            removeListedHost(named: leftovers.firstMatch.label, fingerprint: fingerprint)
            _ = until(2) { false }
        }
        XCTAssertFalse(leftovers.firstMatch.exists, "Leftover R20 hosts remain")
    }
}

extension XCUIApplication {
    /// Runs a saved snippet from the key row's Snippets key.
    func runTerminalSnippet(_ name: String) {
        if !buttons["terminalKey-hideKeyboard"].exists { toggleTerminalKeyboard() }
        let key = buttons["terminalKey-snippets"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        for _ in 0..<6 where !key.isHittable {
            let escape = buttons["terminalKey-escape"]
            let start = escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
        }
        key.tap()
        let item = buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }
}
