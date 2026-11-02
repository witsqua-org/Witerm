import XCTest

/// Opt-in management regression for the exact disposable host created by the
/// native Mac acceptance flow. Other saved hosts and trust entries are excluded.
@MainActor final class SSHHostManagementTests: XCTestCase {
    func testInspectAndRemoveOnlyDisposableHostTrustAndProfile() throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        guard ProcessInfo.processInfo.environment["WITERM_SSH_MAC_FIXTURE_MANAGEMENT"] == "1",
              let path = ProcessInfo.processInfo.environment["WITERM_SSH_MAC_APP_PATH"],
              let fingerprint = ProcessInfo.processInfo.environment["WITERM_SSH_UI_FINGERPRINT"] else {
            throw XCTSkip("Explicit disposable Mac fixture management configuration required")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-witerm.onboarding.completedVersion", "1"]
        app.launch()
        app.activate()
        // Saved hosts are listed directly in the sidebar; selecting one shows
        // its detail page, which owns the host actions menu.
        // The fixture host name and port default to the original native run.
        let environment = ProcessInfo.processInfo.environment
        let profileName = environment["WITERM_SSH_MAC_PROFILE_NAME"] ?? "SSH 验收 Mac 1026"
        let port = environment["WITERM_SSH_UI_PORT"] ?? "57682"
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@ AND value == %@",
            "sshProfileRow-", profileName, "fixture@127.0.0.1:\(port)")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let rowID = row.identifier
        let suffix = String(rowID.dropFirst("sshProfileRow-".count))
        let menu = app.descendants(matching: .any)["sshProfileActions-\(suffix)"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        app.menuItems["主机密钥"].click()
        let identity = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", fingerprint, fingerprint)).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshRemoveHostTrust-")).firstMatch.click()
        app.buttons["sshConfirmForgetHostKey"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["未记住此主机密钥"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.click()
        menu.click()
        app.menuItems["删除连接"].click()
        app.buttons["删除"].firstMatch.click()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)[rowID].firstMatch)
        wait(for: [removed], timeout: 5)
    }
}
