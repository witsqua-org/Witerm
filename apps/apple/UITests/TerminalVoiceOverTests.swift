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
    private var groupNavigationUnavailable = false
    private var enteredGroup = false

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
            return output?.utterance ?? ""
        } catch {
            let failure = error as NSError
            if action == .inside || action == .outside,
                failure.domain == "AXVoiceOverAutomationErrorDomain", failure.code == 3
            {
                // Flat navigation does not support group entry/exit. Keep the
                // user's navigation style and continue with forward/backward.
                groupNavigationUnavailable = true
                enteredGroup = false
                return ""
            }
            if failure.domain == XCUIVoiceOverService.Error.errorDomain,
                failure.code == XCUIVoiceOverService.Error.Code.noSpeech.rawValue
            {
                return ""
            }
            throw error
        }
    }

    private func seek(_ marker: String, backward: Bool = false) throws -> Bool {
        let deadline = Date().addingTimeInterval(15)
        if try speech(.current).contains(marker) { return true }
        for _ in 0..<18 {
            guard Date() < deadline else { return false }
            let next = try speech(backward ? .backward : .forward)
            if next.contains(marker) { return true }
            if !groupNavigationUnavailable, next.contains("终端"),
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

    private func launch(readOnly: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let originalVoiceOver = XCUIDevice.shared.voiceOverService.isEnabled
        // Register before launch/ready assertions so XCTest always restores the
        // global service and terminates the app, including setup failures.
        addTeardownBlock {
            await Self.restore(originalVoiceOver, app: app)
        }
        app.launchArguments = ["--witerm-terminal-accessibility-harness"]
        if readOnly { app.launchArguments.append("--witerm-terminal-read-only") }
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

    func testNativeVoiceOverContentAndReadingDoNotWriteThenKeyboardDoes() throws {
        let app = launch()
        try ensureVoiceOver(true)
        app.buttons["harnessBefore"].tap()
        XCTAssertTrue(try seek("中文终端验证"), "VoiceOver did not speak the native terminal fixture")
        if enteredGroup { _ = try speech(.outside) }
        XCTAssertTrue(try seek("朗读后锚点"), "Forward VoiceOver focus did not leave the terminal")
        XCTAssertTrue(
            try seek("中文终端验证", backward: true),
            "Backward VoiceOver focus did not return to terminal text"
        )
        XCTAssertEqual(value(app, "harnessInputCount"), "0:0")
        try ensureVoiceOver(false)
        app.buttons["harnessReadingProbe"].tap()
        XCTAssertEqual(value(app, "harnessInputCount"), "0:0")
        app.buttons["harnessKeyboard"].tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let key = keyboard.keys["v"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        let input = app.descendants(matching: .any)["harnessInputCount"].firstMatch
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "0:0"), object: input)
        wait(for: [written], timeout: 5)
        XCTAssertNotEqual(value(app, "harnessInputCount"), "0:0")
    }

    func testReadOnlyNativeTextAlternateAndLargeNarrowHighContrast() throws {
        let app = launch(readOnly: true)
        try ensureVoiceOver(true)
        app.buttons["harnessBefore"].tap()
        XCTAssertTrue(try seek("中文终端验证"), "VoiceOver did not read the readonly terminal fixture")
        try ensureVoiceOver(false)
        app.buttons["harnessReadingProbe"].tap()
        app.buttons["harnessInputProbe"].tap()
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
            app.buttons["harnessBefore"].tap()
            XCTAssertTrue(
                try seek("横向右端验证"), "VoiceOver kept a stale page after native horizontal scrolling")
            try ensureVoiceOver(false)
            end.press(forDuration: 0.05, thenDragTo: start)
        #endif
        app.buttons["harnessFont"].tap()
        app.buttons["harnessNarrow"].tap()
        app.buttons["harnessContrast"].tap()
        traceAppearance(app)
        XCTAssertTrue(value(app, "harnessAppearanceStatus").contains("24"))
        XCTAssertTrue(value(app, "harnessAppearanceStatus").contains("窄视口"))
        XCTAssertTrue(value(app, "harnessAppearanceStatus").contains("增强对比"))
        captureFixture(app, name: "fixed-terminal-large-narrow-high-contrast")
        try ensureVoiceOver(true)
        app.buttons["harnessBefore"].tap()
        XCTAssertTrue(try seek("中文终端验证"), "Large narrow terminal content was not spoken")
        try ensureVoiceOver(false)
        app.buttons["harnessAlternate"].tap()
        try ensureVoiceOver(true)
        app.buttons["harnessBefore"].tap()
        XCTAssertTrue(try seek("备用屏幕验证"), "VoiceOver did not read the actual alternate screen")
        XCTAssertEqual(value(app, "harnessInputCount"), "0:0")
    }
}
