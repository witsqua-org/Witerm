import XCTest

/// Round 16 terminal chrome: the keyboard button sits at the terminal's
/// bottom right while the keyboard is hidden, and the key row ends with
/// Hide Keyboard while it's up; text size and colors are one submenu.
extension XCUIApplication {
    /// Shows the keyboard with the bottom-right button, or hides it with the
    /// key row's Hide Keyboard, whichever is on screen.
    func toggleTerminalKeyboard() {
        let hide = buttons["terminalKey-hideKeyboard"]
        if hide.exists, hide.isHittable {
            hide.tap()
            return
        }
        let show = buttons.matching(NSPredicate(format: "identifier IN %@", ["sshKeyboard", "remoteKeyboard"])).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 5), "No keyboard button")
        show.tap()
    }

    /// Opens Text and Colors in a terminal's open actions menu.
    func openTextAndColors() {
        let item = buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                "terminalTextAndColors", "Text and Colors")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No Text and Colors in the actions menu")
        item.tap()
    }
}
