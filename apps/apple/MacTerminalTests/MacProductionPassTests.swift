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

/// The `witerm` link in a temporary folder, never the real ~/.local/bin.
@MainActor final class CommandLineToolLinkTests: XCTestCase {
    private var root: URL!
    private var link: URL { root.appendingPathComponent("bin/witerm") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A Witerm copy's command at `<name>.app/Contents/Helpers/witerm`.
    private func copy(_ name: String, present: Bool = true) throws -> URL {
        let command = root.appendingPathComponent("\(name).app/Contents/Helpers/witerm")
        if present {
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: command.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        return command
    }

    private func target() throws -> String { try FileManager.default.destinationOfSymbolicLink(atPath: link.path) }

    /// The owner moved the project: the link named a copy that's gone, so
    /// `witerm` failed with "no such file or directory". It now follows
    /// this copy without being asked.
    func testALinkToAMovedCopyFollowsThisCopy() throws {
        let gone = try copy("Old", present: false)
        let this = try copy("Witerm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gone)
        let model = CommandLineToolModel(linkURL: link, bundledURL: this)
        model.refresh()
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(try target(), this.path)
        XCTAssertEqual(model.command, "witerm")
    }

    /// Another copy that's still there stays the person's to switch.
    func testALinkToAnotherCopyThatStillExistsIsKept() throws {
        let other = try copy("Other")
        let this = try copy("Witerm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        let model = CommandLineToolModel(linkURL: link, bundledURL: this)
        model.refresh()
        XCTAssertEqual(model.state, .otherCopy(other.standardizedFileURL.path))
        XCTAssertEqual(try target(), other.path)
    }

    /// Without its own command, this copy doesn't take over a broken link.
    func testACopyWithoutTheCommandLeavesTheLink() throws {
        let gone = try copy("Old", present: false)
        let this = try copy("Witerm", present: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gone)
        let model = CommandLineToolModel(linkURL: link, bundledURL: this)
        model.refresh()
        XCTAssertEqual(model.state, .otherCopy(gone.standardizedFileURL.path))
        XCTAssertEqual(try target(), gone.path)
    }

    /// A broken link that isn't Witerm's is never replaced.
    func testABrokenLinkThatIsntWitermsIsNeverReplaced() throws {
        let elsewhere = root.appendingPathComponent("tools/witerm")
        let this = try copy("Witerm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let model = CommandLineToolModel(linkURL: link, bundledURL: this)
        model.refresh()
        XCTAssertEqual(model.state, .blocked)
        XCTAssertEqual(try target(), elsewhere.path)
    }
}
