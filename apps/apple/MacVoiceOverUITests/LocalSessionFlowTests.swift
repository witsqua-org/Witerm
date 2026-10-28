import Foundation
import XCTest

/// Opt-in acceptance against the fixed, signed development app and its
/// running service. Creates one fresh session, renames it, opens find in its
/// terminal, and ends it. No other session is touched.
@MainActor
final class LocalSessionFlowTests: XCTestCase {
    private static func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "localSession-", name)).firstMatch
    }

    func testRenameAndFindInFreshSession() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["WITERM_HCI_FIXED_APP"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP to the signed development app")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let suffix = String(UUID().uuidString.prefix(6))
        let original = "HCI session " + suffix
        let renamed = "HCI renamed " + suffix
        func row(_ name: String) -> XCUIElement { Self.row(name, in: app) }

        // Create a fresh session through the menu.
        app.typeKey("n", modifierFlags: .command)
        let nameField = app.textFields["localSessionName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(original)
        app.buttons["createLocalSession"].click()
        let created = row(original)
        XCTAssertTrue(created.waitForExistence(timeout: 15))
        addTeardownBlock {
            await MainActor.run {
                // End only this test's session, under whichever name it has.
                let current = Self.row(renamed, in: app).exists ? Self.row(renamed, in: app) : Self.row(original, in: app)
                guard current.exists else { return }
                current.rightClick()
                app.menuItems["End Session"].click()
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
            }
        }

        // Rename keeps the session; the sidebar shows the new name.
        created.rightClick()
        app.menuItems["Rename…"].click()
        let renameField = app.textFields["localSessionName"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        XCTAssertEqual(renameField.value as? String, original)
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText(renamed)
        app.buttons["renameLocalSession"].click()
        XCTAssertTrue(row(renamed).waitForExistence(timeout: 10))
        XCTAssertFalse(row(original).exists)

        // Find opens SwiftTerm's find bar over the focused terminal.
        row(renamed).click()
        let terminal = app.descendants(matching: .any)["localTerminalSurface"].firstMatch
        if terminal.waitForExistence(timeout: 10) { terminal.click() }
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "Find did not open the terminal's find bar")
        app.typeKey(.escape, modifierFlags: [])
    }
}
