import XCTest
import XCUIAutomation

@MainActor
@available(iOS 27.0, *)
final class TerminalVoiceOverKeyboardTests: XCTestCase {
    func testSoftwareKeyboardWritesWhileVoiceOverRemainsEnabled() throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let app = XCUIApplication()
        let previous = XCUIDevice.shared.voiceOverService.isEnabled
        addTeardownBlock {
            await MainActor.run {
                app.terminate()
                let service = XCUIDevice.shared.voiceOverService
                do {
                    if service.isEnabled != previous {
                        if previous { try service.enable() } else { try service.disable() }
                    }
                } catch { XCTFail("Could not restore the previous VoiceOver state") }
            }
        }
        app.launchArguments = ["--witerm-terminal-accessibility-harness"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["harnessReady"].waitForExistence(timeout: 10))
        let service = XCUIDevice.shared.voiceOverService
        if !service.isEnabled { try service.enable() }
        XCTAssertTrue(service.isEnabled)

        let keyboardButton = app.buttons["harnessKeyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 5))
        // VoiceOver activation uses a real double tap, without suspending the
        // screen reader or addressing the hidden terminal keyboard responder.
        keyboardButton.tap()
        keyboardButton.doubleTap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let key = keyboard.keys["v"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.doubleTap()

        let counter = app.descendants(matching: .any)["harnessInputCount"].firstMatch
        let wrote = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value MATCHES %@", "[1-9][0-9]*:[1-9][0-9]*"), object: counter)
        wait(for: [wrote], timeout: 5)
        XCTAssertNotNil((counter.value as? String)?.range(of: "^[1-9][0-9]*:[1-9][0-9]*$", options: .regularExpression))
        XCTAssertTrue(service.isEnabled, "Keyboard testing must keep VoiceOver running")
    }
}
