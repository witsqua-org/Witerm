import WitermCore
import XCTest
@testable import WitermMac

/// The Mac production pass's pure rules: who else is typing, new terminal
/// names in either language, and when Disconnect asks first.
@MainActor final class MacProductionPassTests: XCTestCase {
    private func session(_ attachments: [LocalAttachmentInfo]) -> LocalSessionInfo {
        LocalSessionInfo(id: UUID().uuidString, name: "Audit", createdAt: .now, columns: 80, rows: 24,
                         sharing: LocalSessionSharing(shared: false, attachments: attachments))
    }

    /// M-38: right after Stop Typing the listing can still show this window's
    /// earlier typing attachment; it's never "another window".
    func testOwnEarlierAttachmentIsNotAnotherWindow() {
        let stale = session([LocalAttachmentInfo(mode: .control, device: nil)])
        XCTAssertEqual(stale.elsewhere(here: .view, switchedFrom: .control), [])
        // Without the switch it's a real second typist.
        XCTAssertEqual(stale.elsewhere(here: .view).count, 1)
        // Typing here and in a second window still says so.
        let two = session([LocalAttachmentInfo(mode: .control, device: nil), LocalAttachmentInfo(mode: .control, device: nil)])
        XCTAssertEqual(two.elsewhere(here: .control).count, 1)
        // Switching to typing never hides anything.
        let watching = session([LocalAttachmentInfo(mode: .view, device: nil)])
        XCTAssertEqual(watching.elsewhere(here: .control, switchedFrom: .view), [])
    }

    /// M-40: a number is taken in either language.
    func testNewTerminalNamesSkipNumbersTakenInEitherLanguage() {
        let chinese: (Int) -> String = { "终端 \($0)" }
        XCTAssertEqual(LocalTerminalModel.nextName(taken: ["Terminal 1"], localized: chinese), "终端 2")
        XCTAssertEqual(LocalTerminalModel.nextName(taken: ["终端 1", "Terminal 2"], localized: { "Terminal \($0)" }), "Terminal 3")
        XCTAssertEqual(LocalTerminalModel.nextName(taken: [], localized: chinese), "终端 1")
    }

    /// M-21: at a prompt Disconnect is immediate; with a program running it asks.
    func testDisconnectAsksOnlyAwayFromAPrompt() {
        XCTAssertTrue(SSHHostDetail.atPrompt("fixture@host:~$ "))
        XCTAssertTrue(SSHHostDetail.atPrompt("root@host:/# "))
        XCTAssertTrue(SSHHostDetail.atPrompt("ada@mac ~ % "))
        XCTAssertTrue(SSHHostDetail.atPrompt(nil))
        XCTAssertFalse(SSHHostDetail.atPrompt("  PID USER      PR  NI    VIRT    RES"))
        XCTAssertFalse(SSHHostDetail.atPrompt("-- INSERT --"))
    }
}
