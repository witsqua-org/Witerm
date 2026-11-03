import XCTest

/// Round 16 terminal chrome: the keyboard button sits at the terminal's
/// bottom right while the keyboard is hidden, and the key row ends with
/// Hide Keyboard while it's up; text size and colors are inline in the actions menu.
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

    /// Round 17: text size and colors are inline in the actions menu, never
    /// a submenu, so with the menu open there's nothing more to open. Checks
    /// that the size controls are right there.
    func openTextAndColors() {
        let item = buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                "terminalLargerText", "Increase Text Size")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No text size in the actions menu itself")
        XCTAssertFalse(buttons["terminalTextAndColors"].exists, "Text and Colors must not be a submenu")
    }
}
