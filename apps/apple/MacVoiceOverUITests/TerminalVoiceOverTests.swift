import XCTest
import XCUIAutomation

@MainActor
@available(iOS 27.0, macOS 27.0, *)
final class TerminalVoiceOverTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    private enum SpeechAction { case current, forward, backward, inside, outside }
    private enum SpeechResult: String {
        case output, noSpeech, flatGroupUnavailable, notRunning, failure
    }
    private var groupNavigationUnavailable = false
    private var enteredGroup = false
    private weak var harnessApplication: XCUIApplication?

    private func traceSpeech(_ action: SpeechAction, result: SpeechResult, utterance: String = "") {
        // Fixed-fixture classifications only. Never log raw speech, which may
        // belong to another app if the system's VoiceOver focus has moved.
        let lower = utterance.lowercased()
        let hasScrollArea =
            utterance.contains("终端视区") || utterance.contains("滚动区域")
            || lower.contains("scroll area")
        let hasScrollbar =
            utterance.contains("滚动条") || lower.contains("scroll bar") || lower.contains("scrollbar")
        let hasGroup =
            utterance.contains("群组") || utterance.contains("组") || lower.contains("group")
        let hasWindow = utterance.contains("窗口") || lower.contains("window")
        let hasAppTitle = lower.contains("witerm")
        let hasFontButton = utterance.contains("放大字号") || utterance.contains("标准字号")
        let hasNarrowButton = utterance.contains("窄视口") || utterance.contains("标准视口")
        let hasContrastButton = utterance.contains("增强对比") || utterance.contains("标准对比")
        let scalarCount = utterance.unicodeScalars.count
        let wordCount = utterance.split(whereSeparator: { $0.isWhitespace }).count
        let singleCharacter = utterance.count == 1
        let hasTutorialOrModifier = [
            "quick start", "tutorial", "control", "option", "command", "shift", "modifier", "快速入门",
            "教程", "修饰键", "控制键", "选项键",
        ].contains(where: { lower.contains($0) })
        let hasEndCue =
            lower == "end"
            || ["end of", "no more", "末尾", "结尾", "结束", "到头"].contains(where: { lower.contains($0) })
        print(
            "VO_FIXED_FIXTURE action=\(action) result=\(result.rawValue) empty=\(utterance.isEmpty) before=\(utterance.contains("朗读前锚点")) after=\(utterance.contains("朗读后锚点")) terminal=\(utterance.contains("终端")) chinese=\(utterance.contains("中文终端验证")) alternate=\(utterance.contains("备用屏幕验证")) baselineOne=\(utterance.contains("导航基准一")) baselineTwo=\(utterance.contains("导航基准二")) groupEntered=\(enteredGroup) groupUnavailable=\(groupNavigationUnavailable) hasScrollArea=\(hasScrollArea) hasScrollbar=\(hasScrollbar) hasGroup=\(hasGroup) hasWindow=\(hasWindow) hasAppTitle=\(hasAppTitle) hasFontButton=\(hasFontButton) hasNarrowButton=\(hasNarrowButton) hasContrastButton=\(hasContrastButton) scalarCount=\(scalarCount) wordCount=\(wordCount) singleCharacter=\(singleCharacter) hasTutorialOrModifier=\(hasTutorialOrModifier) hasEndCue=\(hasEndCue)"
        )
    }

    private func speech(_ action: SpeechAction) throws -> String {
        let service = XCUIDevice.shared.voiceOverService
        do {
            // Xcode 27 SDK symbol metadata confirms these public Swift APIs.
            // Inspect Output.utterance only for fixed-fixture boolean assertions.
            let output: XCUIVoiceOverService.Output?
            switch action {
            case .current: output = try service.currentSpeech()
            case .forward: output = try service.moveForward()
            case .backward: output = try service.moveBackward()
            case .inside: output = try service.moveIn()
            case .outside: output = try service.moveOut()
            }
            if action == .inside { enteredGroup = true }
            if action == .outside { enteredGroup = false }
            let utterance = output?.utterance ?? ""
            traceSpeech(action, result: .output, utterance: utterance)
            return utterance
        } catch {
            let failure = error as NSError
            if action == .inside || action == .outside,
                failure.domain == "AXVoiceOverAutomationErrorDomain", failure.code == 3
            {
                // Flat navigation does not support group entry/exit. Keep the
                // user's navigation style and continue with forward/backward.
                groupNavigationUnavailable = true
                enteredGroup = false
                traceSpeech(action, result: .flatGroupUnavailable)
                return ""
            }
            if failure.domain == XCUIVoiceOverService.Error.errorDomain,
                failure.code == XCUIVoiceOverService.Error.Code.noSpeech.rawValue
            {
                traceSpeech(action, result: .noSpeech)
                return ""
            }
            if failure.domain == XCUIVoiceOverService.Error.errorDomain,
                failure.code == XCUIVoiceOverService.Error.Code.notRunning.rawValue
            {
                traceSpeech(action, result: .notRunning)
            } else {
                traceSpeech(action, result: .failure)
            }
            throw error
        }
    }

    private func seek(_ marker: String, backward: Bool = false) throws -> Bool {
        let deadline = Date().addingTimeInterval(30)
        let terminalContent = ["中文终端验证", "备用屏幕验证", "横向右端验证"].contains(marker)
        let target =
            marker == "中文终端验证"
            ? "chinese"
            : (marker == "朗读后锚点" ? "after" : (marker == "备用屏幕验证" ? "alternate" : "other"))
        print(
            "VO_FIXED_FIXTURE seek=begin target=\(target) backward=\(backward) appForeground=\(harnessApplication?.state == .runningForeground)"
        )
        if try speech(.current).contains(marker) { return true }
        for _ in 0..<18 {
            guard Date() < deadline else { return false }
            let next = try speech(backward ? .backward : .forward)
            if next.contains(marker) { return true }
            if terminalContent, !groupNavigationUnavailable, next.contains("终端"),
                try speech(.inside).contains(marker)
            {
                return true
            }
        }
        return false
    }

    private func value(_ app: XCUIApplication, _ id: String) -> String {
        let element = app.descendants(matching: .any)[id].firstMatch
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func traceAppearance(_ app: XCUIApplication) {
        let element = app.descendants(matching: .any)["harnessAppearanceStatus"].firstMatch
        let value = element.value as? String ?? ""
        let label = element.label
        print(
            "VO_FIXED_FIXTURE appearance valueEmpty=\(value.isEmpty) value24=\(value.contains("24")) label24=\(label.contains("24")) valueNarrow=\(value.contains("窄视口")) labelNarrow=\(label.contains("窄视口")) valueContrast=\(value.contains("增强对比")) labelContrast=\(label.contains("增强对比"))"
        )
    }

    private func focusBefore(_ app: XCUIApplication) {
        focusAnchor(app, button: "harnessBefore", expected: "before")
    }

    private func focusAnchor(_ app: XCUIApplication, button: String, expected: String) {
        let state = app.descendants(matching: .any)["harnessAnchorState"].firstMatch
        let activation = app.descendants(matching: .any)["harnessAnchorActivation"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(activation.waitForExistence(timeout: 5))
        let previous = Int(value(app, "harnessAnchorActivation")) ?? 0
        app.buttons[button].click()
        let triggered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label == %@", expected, expected),
            object: state)
        let invoked = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@ OR label == %@", String(previous + 1), String(previous + 1)),
            object: activation)
        wait(for: [triggered, invoked], timeout: 5)
        XCTAssertEqual(value(app, "harnessAnchorState"), expected)
        XCTAssertEqual(value(app, "harnessAnchorActivation"), String(previous + 1))
    }

    private func launch(readOnly: Bool = false, plainBaseline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        harnessApplication = app
        let originalVoiceOver = XCUIDevice.shared.voiceOverService.isEnabled
        XCTContext.runActivity(
            named: originalVoiceOver
                ? "Mac VoiceOver precondition: already enabled through the system"
                : "Mac VoiceOver precondition: XCTest enable is required"
        ) { _ in }
        // Register before launch/ready assertions so XCTest always restores the
        // global service and terminates the app, including setup failures.
        addTeardownBlock {
            await Self.restore(originalVoiceOver, app: app)
        }
        app.launchArguments = ["--witerm-terminal-accessibility-harness"]
        if readOnly { app.launchArguments.append("--witerm-terminal-read-only") }
        if plainBaseline { app.launchArguments.append("--witerm-voiceover-plain-baseline") }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["harnessReady"].waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label == %@", "已就绪", "已就绪"),
            object: app.staticTexts["harnessReady"])
        wait(for: [ready], timeout: 5)
        return app
    }

    private static func restore(_ previous: Bool, app: XCUIApplication) {
        app.terminate()
        let service = XCUIDevice.shared.voiceOverService
        do {
            if service.isEnabled != previous {
                if previous { try service.enable() } else { try service.disable() }
            }
        } catch { XCTFail("Could not restore the previous VoiceOver state") }
    }

    private func ensureVoiceOver(_ enabled: Bool) throws {
        let service = XCUIDevice.shared.voiceOverService
        if service.isEnabled != enabled {
            if enabled { try service.enable() } else { try service.disable() }
        }
    }

    private func captureFixture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVoiceOverOrdinarySwiftUIBaseline() throws {
        let originalVoiceOver = XCUIDevice.shared.voiceOverService.isEnabled
        // Isolate service initialization from any App launch or AX session.
        // Register cleanup first, including the initialization-failure path.
        addTeardownBlock {
            await MainActor.run {
                let service = XCUIDevice.shared.voiceOverService
                do {
                    if service.isEnabled != originalVoiceOver {
                        if originalVoiceOver { try service.enable() } else { try service.disable() }
                    }
                } catch { XCTFail("Could not restore the previous VoiceOver state") }
            }
        }
        print(
            "VO_FIXED_FIXTURE initialization=beforeAppLaunch initiallyEnabled=\(originalVoiceOver)")
        try XCUIDevice.shared.voiceOverService.enable()
        let app = launch(plainBaseline: true)
        XCTAssertFalse(app.buttons["harnessKeyboard"].exists)
        focusAnchor(app, button: "harnessBaselineOne", expected: "baselineOne")
        XCTAssertTrue(
            try speech(.current).contains("导航基准一"),
            "VoiceOver did not speak the focused ordinary baseline button")
        let moved = try speech(.forward)
        let current = try speech(.current)
        XCTAssertTrue(
            moved.contains("导航基准二") || current.contains("导航基准二"),
            "VoiceOver did not navigate between adjacent ordinary buttons")
    }

    func testNativeVoiceOverContentAndReadingDoNotWriteThenKeyboardDoes() throws {
        let app = launch()
        try ensureVoiceOver(true)
        focusBefore(app)
        XCTAssertTrue(try seek("中文终端验证"), "VoiceOver did not speak the native terminal fixture")
        // VoiceOver may auto-interact with the native text area without our
        // helper having explicitly entered it. Flat mode's exact error stays handled.
        _ = try speech(.outside)
        XCTAssertTrue(try seek("朗读后锚点"), "Forward VoiceOver focus did not leave the terminal")
        XCTAssertTrue(
            try seek("中文终端验证", backward: true),
            "Backward VoiceOver focus did not return to terminal text"
        )
        XCTAssertEqual(value(app, "harnessInputCount"), "0:0")
        app.buttons["harnessReadingProbe"].click()
        XCTAssertEqual(value(app, "harnessInputCount"), "0:0")
        app.buttons["harnessKeyboard"].click()
        app.typeText("v")
        let input = app.descendants(matching: .any)["harnessInputCount"].firstMatch
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "0:0"), object: input)
        wait(for: [written], timeout: 5)
        XCTAssertNotEqual(value(app, "harnessInputCount"), "0:0")
    }

    func testReadOnlyNativeTextAlternateAndLargeNarrowHighContrast() throws {
        let app = launch(readOnly: true)
        try ensureVoiceOver(true)
        focusBefore(app)
        XCTAssertTrue(try seek("中文终端验证"), "VoiceOver did not read the readonly terminal fixture")
        app.buttons["harnessReadingProbe"].click()
        app.buttons["harnessInputProbe"].click()
        XCTAssertEqual(value(app, "harnessProbeCount"), "1:1")
        XCTAssertEqual(value(app, "harnessInputCount"), "0:0")
        #if os(iOS)
            let surface = app.descendants(matching: .any)["remoteTerminalSurface"].firstMatch
            // Real one-finger drag with VO off; then read the changed visible page.
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            let changedPage = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "横向右端验证"), object: surface)
            wait(for: [changedPage], timeout: 5)
            XCTAssertTrue(
                (surface.value as? String ?? "").contains("横向右端验证"),
                "Dragged native surface did not expose the right-edge fixture marker")
            try ensureVoiceOver(true)
            focusBefore(app)
            XCTAssertTrue(
                try seek("横向右端验证"), "VoiceOver kept a stale page after native horizontal scrolling")
            end.press(forDuration: 0.05, thenDragTo: start)
        #endif
        app.buttons["harnessFont"].click()
        app.buttons["harnessNarrow"].click()
        app.buttons["harnessContrast"].click()
        traceAppearance(app)
        XCTAssertTrue(value(app, "harnessAppearanceStatus").contains("24"))
        XCTAssertTrue(value(app, "harnessAppearanceStatus").contains("窄视口"))
        XCTAssertTrue(value(app, "harnessAppearanceStatus").contains("增强对比"))
        captureFixture(app, name: "fixed-terminal-large-narrow-high-contrast")
        try ensureVoiceOver(true)
        focusBefore(app)
        XCTAssertTrue(try seek("中文终端验证"), "Large narrow terminal content was not spoken")
        app.buttons["harnessAlternate"].click()
        try ensureVoiceOver(true)
        focusBefore(app)
        XCTAssertTrue(try seek("备用屏幕验证"), "VoiceOver did not read the actual alternate screen")
        XCTAssertEqual(value(app, "harnessInputCount"), "0:0")
    }
}
