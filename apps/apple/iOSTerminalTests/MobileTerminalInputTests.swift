import SwiftUI
import SwiftTerm
import UIKit
import WitermCore
import XCTest
@testable import WitermiOS

@MainActor final class MobileTerminalInputTests: XCTestCase {
    private func input(mode: LocalAttachmentMode = .control) -> RemoteNativeTerminalView.TerminalInputView {
        RemoteNativeTerminalView.TerminalInputView(mode: mode,
            session: LocalSessionInfo(id: UUID().uuidString, name: "Input fixture", createdAt: .now, columns: 80, rows: 24),
            fontSize: 14, isInteractive: true)
    }

    /// A long press selects the word under the finger and dragging extends
    /// it, in a read-only terminal too; Paste is offered only where typing is.
    func testLongPressSelectsAndOffersEditActions() {
        let reader = input(mode: .view)
        reader.frame = reader.getOptimalFrameSize()
        reader.feed(text: "alpha beta gamma")
        let cell = CGSize(width: reader.frame.width / 80, height: reader.frame.height / 24)
        func point(_ column: Int) -> CGPoint { CGPoint(x: (CGFloat(column) + 0.5) * cell.width, y: cell.height / 2) }
        reader.beginSelection(at: point(7))
        XCTAssertEqual(reader.selection.getSelectedText(), "beta")
        reader.extendSelection(to: point(13))
        XCTAssertEqual(reader.selection.getSelectedText(), "beta gam")
        UIPasteboard.general.string = "pasted"
        let paste = String(localized: "Paste", bundle: .main)
        let copy = String(localized: "Copy", bundle: .main)
        XCTAssertTrue(reader.editActions().contains { $0.title == copy })
        XCTAssertFalse(reader.editActions().contains { $0.title == paste })
        XCTAssertFalse(reader.allowMouseReporting)
        let writer = input()
        XCTAssertTrue(writer.allowMouseReporting)
        XCTAssertTrue(writer.editActions().contains { $0.title == paste })
        XCTAssertFalse(writer.editActions().contains { $0.title == copy })
    }

    /// A new connection that accepts typing brings up the keyboard once it is
    /// on screen; a view-only one, or one shown again later, does not.
    func testNewTypingTerminalFocusesOnceWhenShown() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let writer = input(), reader = input(mode: .view)
        writer.focusesWhenShown = true
        reader.focusesWhenShown = true
        let focus = FocusLog()
        let observer = NotificationCenter.default.addObserver(forName: .witermTerminalFocusChanged, object: writer, queue: nil) { note in
            let focused = note.userInfo?["focused"] as? Bool ?? false
            MainActor.assumeIsolated { focus.values.append(focused) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.rootViewController?.view.addSubview(reader)
        window.rootViewController?.view.addSubview(writer)
        for _ in 0..<20 where !writer.isFirstResponder { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(writer.isFirstResponder)
        XCTAssertFalse(reader.isFirstResponder)
        XCTAssertFalse(writer.focusesWhenShown, "Focus is requested once per connection")
        _ = writer.resignFirstResponder()
        writer.removeFromSuperview()
        window.rootViewController?.view.addSubview(writer)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(writer.isFirstResponder, "Showing the terminal again keeps the person's choice")
        XCTAssertEqual(focus.values.first, true)
        XCTAssertEqual(focus.values.last, false)
    }

    func testControlKeyResetsAndReadOnlyRejectsAccessoryAndPaste() {
        let terminal = input(), spy = InputSpy()
        terminal.terminalDelegate = spy
        terminal.controlModifier = true
        terminal.insertText("c")
        XCTAssertEqual(spy.bytes, Data([3]))
        XCTAssertFalse(terminal.controlModifier)
        terminal.sendAccessory([9])
        XCTAssertEqual(spy.bytes, Data([3, 9]))
        terminal.disableInput()
        terminal.sendAccessory([3])
        terminal.reviewOrPaste("old input")
        XCTAssertEqual(spy.bytes, Data([3, 9]))
        let reader = input(mode: .view)
        reader.terminalDelegate = spy
        reader.sendAccessory([3])
        reader.reviewOrPaste("read only")
        XCTAssertEqual(spy.bytes, Data([3, 9]))
    }

    func testAccessoryControlStateAndInterruptHaveAccessibleTouchTargets() throws {
        let terminal = input(), spy = InputSpy()
        terminal.terminalDelegate = spy
        let accessory = try XCTUnwrap(terminal.inputAccessoryView)
        accessory.layoutIfNeeded()
        func buttons(_ view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let keys = buttons(accessory)
        let control = try XCTUnwrap(keys.first { $0.accessibilityIdentifier == "terminalControlModifier" })
        let interrupt = try XCTUnwrap(keys.first { $0.accessibilityIdentifier == "terminalInterrupt" })
        for key in keys {
            XCTAssertGreaterThanOrEqual(key.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(key.bounds.height, 44)
            XCTAssertFalse(key.accessibilityLabel?.isEmpty ?? true)
        }
        control.sendActions(for: .touchUpInside)
        XCTAssertTrue(control.isSelected)
        XCTAssertTrue(control.accessibilityTraits.contains(.selected))
        terminal.insertText("c")
        XCTAssertFalse(control.isSelected)
        XCTAssertEqual(spy.bytes, Data([3]))
        interrupt.sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.bytes, Data([3, 3]))
    }

    func testNavigationAndSymbolKeysFollowCursorMode() throws {
        let terminal = input(), spy = InputSpy()
        terminal.terminalDelegate = spy
        let accessory = try XCTUnwrap(terminal.inputAccessoryView)
        func buttons(_ view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        func press(_ id: String) throws -> String {
            spy.bytes = Data()
            try XCTUnwrap(buttons(accessory).first { $0.accessibilityIdentifier == "terminalKey-\(id)" })
                .sendActions(for: .touchUpInside)
            return String(decoding: spy.bytes, as: UTF8.self)
        }
        XCTAssertEqual(try press("|"), "|")
        XCTAssertEqual(try press("~"), "~")
        XCTAssertEqual(try press("home"), "\u{1b}[H")
        XCTAssertEqual(try press("end"), "\u{1b}[F")
        XCTAssertEqual(try press("pageUp"), "\u{1b}[5~")
        terminal.feed(text: "\u{1b}[?1h")
        XCTAssertEqual(try press("home"), "\u{1b}OH")
        XCTAssertEqual(try press("pageDown"), "\u{1b}[6~")
        terminal.controlModifier = true
        _ = try press("/")
        XCTAssertFalse(terminal.controlModifier)
    }

    func testKeyRowFollowsSavedOrderAndSelection() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: MobileKey.key)
        let previousSnippets = defaults.data(forKey: CommandSnippets.key)
        defer {
            defaults.set(previous, forKey: MobileKey.key)
            defaults.set(previousSnippets, forKey: CommandSnippets.key)
        }
        defaults.removeObject(forKey: CommandSnippets.key)
        XCTAssertEqual(MobileKey.decode(""), MobileKey.allCases)
        // An untouched row from before arrows moved forward follows the new default.
        XCTAssertEqual(MobileKey.decode(MobileKey.previousDefault), MobileKey.allCases)
        XCTAssertEqual(Array(MobileKey.allCases.prefix(7)), [.escape, .control, .tab, .left, .up, .down, .right])
        XCTAssertEqual(MobileKey.decode("tab,bogus,escape,tab"), [.tab, .escape])
        defaults.set(MobileKey.encode([.interrupt, .escape]), forKey: MobileKey.key)
        let terminal = input()
        let accessory = try XCTUnwrap(terminal.inputAccessoryView)
        func identifiers() -> [String] {
            func buttons(_ view: UIView) -> [UIButton] { (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            return buttons(accessory).compactMap(\.accessibilityIdentifier)
        }
        XCTAssertEqual(identifiers(), ["terminalInterrupt", "terminalKey-escape"])
        // The Snippets key waits for a snippet, then takes its saved place.
        defaults.set(MobileKey.encode([.control, .snippets, .home]), forKey: MobileKey.key)
        XCTAssertEqual(identifiers(), ["terminalControlModifier", "terminalKey-home"])
        defaults.set(CommandSnippets.encode([CommandSnippet(name: "List", text: "ls")]), forKey: CommandSnippets.key)
        XCTAssertEqual(identifiers(), ["terminalControlModifier", "terminalKey-snippets", "terminalKey-home"])
    }

    /// Esc, Ctrl, Tab and the four arrows fit an iPhone's width without
    /// scrolling the row, each still a 44 pt target.
    func testFirstSevenKeysFitAnIPhoneWidth() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: MobileKey.key)
        defer { defaults.set(previous, forKey: MobileKey.key) }
        defaults.removeObject(forKey: MobileKey.key)
        let accessory = try XCTUnwrap(input().inputAccessoryView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.addSubview(accessory)
        accessory.frame = CGRect(x: 0, y: 600, width: 390, height: accessory.intrinsicContentSize.height)
        accessory.setNeedsLayout()
        accessory.layoutIfNeeded()
        func buttons(_ view: UIView) -> [UIButton] { (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let keys = buttons(accessory)
        let right = try XCTUnwrap(keys.first { $0.accessibilityIdentifier == "terminalKey-right" })
        let edge = right.convert(right.bounds, to: accessory).maxX
        XCTAssertLessThanOrEqual(edge, 390, "Widths: \(keys.prefix(7).map { Int($0.bounds.width) })")
        for key in keys { XCTAssertGreaterThanOrEqual(key.bounds.width, 44); XCTAssertGreaterThanOrEqual(key.bounds.height, 44) }
    }

    func testSnippetsTypeOnlyWhenInputIsAllowed() {
        let terminal = input(), spy = InputSpy()
        terminal.terminalDelegate = spy
        terminal.controlModifier = true
        terminal.sendSnippet(CommandSnippet(name: "List", text: "ls", runsImmediately: true))
        XCTAssertEqual(String(decoding: spy.bytes, as: UTF8.self), "ls\r")
        XCTAssertFalse(terminal.controlModifier)
        let reader = input(mode: .view)
        reader.terminalDelegate = spy
        reader.sendSnippet(CommandSnippet(name: "List", text: "ls", runsImmediately: true))
        XCTAssertEqual(String(decoding: spy.bytes, as: UTF8.self), "ls\r")
    }

    func testMultilineSnippetIsReviewedBeforeSending() async throws {
        let terminal = input(), spy = InputSpy()
        terminal.terminalDelegate = spy
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.addSubview(terminal)
        terminal.sendSnippet(CommandSnippet(name: "Two", text: "first\nsecond", runsImmediately: true))
        await Task.yield()
        XCTAssertNotNil(controller.presentedViewController as? UIHostingController<TerminalPasteReview>)
        XCTAssertTrue(spy.bytes.isEmpty)
    }

    func testMultilinePasteWaitsForConfirmationAndNeverReplaysAfterDisconnect() async throws {
        let terminal = input(), spy = InputSpy()
        terminal.terminalDelegate = spy
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.addSubview(terminal)
        terminal.frame = controller.view.bounds
        terminal.reviewOrPaste("first\nsecond\n")
        await Task.yield()
        let review = try XCTUnwrap(controller.presentedViewController as? UIHostingController<TerminalPasteReview>)
        XCTAssertTrue(spy.bytes.isEmpty)
        terminal.disableInput()
        review.rootView.confirm()
        XCTAssertTrue(spy.bytes.isEmpty)
    }

    func testConfirmedPastePreservesBracketedPasteAndDoesNotAddReturn() async throws {
        let terminal = input(), spy = InputSpy()
        terminal.terminalDelegate = spy
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.addSubview(terminal)
        terminal.frame = controller.view.bounds
        terminal.feed(text: "\u{1b}[?2004h")
        terminal.reviewOrPaste("first\nsecond")
        await Task.yield()
        let review = try XCTUnwrap(controller.presentedViewController as? UIHostingController<TerminalPasteReview>)
        XCTAssertTrue(spy.bytes.isEmpty)
        review.rootView.confirm()
        XCTAssertEqual(String(decoding: spy.bytes, as: UTF8.self), "\u{1b}[200~first\nsecond\u{1b}[201~")
    }
}

@MainActor private final class InputSpy: NSObject, @preconcurrency TerminalViewDelegate {
    var bytes = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor private final class FocusLog {
    var values: [Bool] = []
}
