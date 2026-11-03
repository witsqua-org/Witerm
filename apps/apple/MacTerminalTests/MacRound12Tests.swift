import AppKit
import WitermCore
import XCTest
@testable import WitermMac

/// Round 12's pure rules: paths dropped on a terminal, the terminal's context
/// menu while typing and watching, and telling same-named pairings apart.
@MainActor final class MacRound12Tests: XCTestCase {
    /// A dropped file types one shell word, never a command.
    func testDroppedPathsAreOneShellWordEach() {
        XCTAssertEqual(MacTerminalTextView.shellQuoted("/Users/me/notes.txt"), "/Users/me/notes.txt")
        XCTAssertEqual(MacTerminalTextView.shellQuoted("/Users/me/My Notes.txt"), "'/Users/me/My Notes.txt'")
        XCTAssertEqual(MacTerminalTextView.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
        XCTAssertEqual(MacTerminalTextView.shellQuoted("/tmp/$(rm -rf ~);x"), "'/tmp/$(rm -rf ~);x'")
        XCTAssertEqual(MacTerminalTextView.shellQuoted("/tmp/line\nbreak"), "'/tmp/line\nbreak'")
        XCTAssertEqual(MacTerminalTextView.shellQuoted("/tmp/文件"), "'/tmp/文件'")
    }

    /// Right-click offers Copy, Paste, Select All and Find…; Paste only
    /// while typing, Copy only with a selection.
    func testTerminalContextMenuFollowsTypingAndWatching() throws {
        for mode in [LocalAttachmentMode.control, .view] {
            let view = MacTerminalTextView(mode: mode)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try XCTUnwrap(view.menu(for: event))
            let actions = menu.items.filter { !$0.isSeparatorItem }.map(\.action)
            XCTAssertEqual(actions, [#selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSResponder.selectAll(_:)),
                                     #selector(NSResponder.performTextFinderAction(_:))])
            let paste = try XCTUnwrap(menu.items.first { $0.action == #selector(NSText.paste(_:)) })
            XCTAssertEqual(view.validateUserInterfaceItem(paste), mode == .control)
            let copy = try XCTUnwrap(menu.items.first { $0.action == #selector(NSText.copy(_:)) })
            XCTAssertFalse(view.validateUserInterfaceItem(copy), "Nothing is selected")
        }
    }

    /// The Open On sheet's last step reads as a word, never a catalog key.
    func testOpenStepTitleIsAWord() {
        let title = ContinueOnDeviceSheet.openStepTitle
        XCTAssertFalse(title.contains("."), title)
        XCTAssertTrue(["Open", "打开"].contains(title), title)
    }

    /// M-08: two pairings with one name say when each was paired.
    func testPairedDateNamesTheDay() {
        let me = PairedDevice(id: "mac", name: "Mac", platform: .macos, publicKey: "")
        let phone = PairedDevice(id: "phone", name: "Phone", platform: .ios, publicKey: "")
        let grant = DeviceGrant(id: "g", pairingID: "p", host: me, client: phone, permission: .control,
                                approvalSignature: "", createdAt: Date(timeIntervalSince1970: 1_793_664_000))
        let text = MacDevicesView.pairedDate(grant)
        XCTAssertTrue(text.hasPrefix("Paired "), text)
        XCTAssertTrue(text.contains("2026"), text)
    }
}
