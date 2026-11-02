import Foundation
import XCTest

/// Opt-in acceptance against the fixed, signed development app and its
/// running service. Creates one fresh session with ⌘N, types into it without
/// a click, renames it, opens find in its terminal, and ends it. No other
/// session is touched.
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
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let suffix = String(UUID().uuidString.prefix(6))
        let renamed = "HCI renamed " + suffix
        func row(_ name: String) -> XCUIElement { Self.row(name, in: app) }
        let sessions = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "localSession-"))
        let before = Set(sessions.allElementsBoundByIndex.map(\.identifier))

        // ⌘N opens a new session at once, named for you, with the keyboard in it.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(app.textFields["localSessionName"].waitForExistence(timeout: 1), "⌘N should not ask for a name")
        let terminal = app.descendants(matching: .any)["localTerminalSurface"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, "The new terminal didn't take keyboard focus")
        let created = sessions.allElementsBoundByIndex.first { !before.contains($0.identifier) }
        let createdID = try XCTUnwrap(created?.identifier, "No new session row")
        let createdRow = app.descendants(matching: .any)[createdID].firstMatch
        addTeardownBlock {
            await MainActor.run {
                // End only this test's session, by its own row.
                guard createdRow.exists else { return }
                createdRow.rightClick()
                app.menuItems["endSessionMenu"].click()
                let confirm = app.buttons["action-button-1"]
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
            }
        }
        // Typing goes straight to the shell: no click first.
        app.typeText("echo HCI_TYPED_\(suffix)\r")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "HCI_TYPED_\(suffix)"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 10), .completed, "Typing after ⌘N didn't reach the shell")

        // Terminal → Rename Session… (⇧⌘R) keeps the session; the sidebar shows the new name.
        app.typeKey("r", modifierFlags: [.command, .shift])
        let renameField = app.textFields["localSessionName"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText(renamed)
        app.buttons["renameLocalSession"].click()
        XCTAssertTrue(row(renamed).waitForExistence(timeout: 10))
        XCTAssertEqual(row(renamed).identifier, createdID)

        // Find opens SwiftTerm's find bar over the focused terminal.
        if (terminal.value(forKey: "hasKeyboardFocus") as? Bool) != true { terminal.click() }
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "Find did not open the terminal's find bar")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Cleanup after an interrupted run: ends sessions this suite created, by
    /// exact name, through the same End Session a person uses. Only names
    /// with a test prefix are accepted. Opt-in: WITERM_HCI_END_SESSIONS,
    /// names separated by "|".
    func testEndLeftoverTestSessions() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WITERM_HCI_FIXED_APP"], let list = environment["WITERM_HCI_END_SESSIONS"] else {
            throw XCTSkip("Set WITERM_HCI_FIXED_APP and WITERM_HCI_END_SESSIONS")
        }
        let names = list.split(separator: "|").map(String.init)
        let prefixes = ["HCI ", "Round 7 ", "Phone E2E "]
        guard names.allSatisfy({ name in prefixes.contains { name.hasPrefix($0) } }) else {
            throw XCTSkip("Only sessions with a test prefix may be ended here")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        for name in names {
            let row = Self.row(name, in: app)
            guard row.waitForExistence(timeout: 10) else { continue }
            row.rightClick()
            app.menuItems["endSessionMenu"].click()
            let confirm = app.buttons["action-button-1"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.click()
            XCTAssertTrue(row.waitForNonExistence(timeout: 10), "\(name) is still listed")
        }
    }
}
