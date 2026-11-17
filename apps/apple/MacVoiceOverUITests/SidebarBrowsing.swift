import XCTest

extension XCUIApplication {
    /// Selects a sidebar row with the arrow keys, from Home, as a person
    /// browsing would. Since Round 28 a click on an SSH host connects it;
    /// browsing only shows its page, with Connect, Edit… and More.
    @MainActor func browse(to row: XCUIElement, limit: Int = 40) {
        let home = descendants(matching: .any)["homeSidebarRow"].firstMatch
        guard home.waitForExistence(timeout: 5) else { return }
        home.click()
        for _ in 0..<limit where !row.isSelected {
            typeKey(.downArrow, modifierFlags: [])
        }
    }
}
