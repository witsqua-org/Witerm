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

    /// Round 24: the scrollback holds a long conversation with a Codex-like
    /// tool, such as the 5,000 earlier lines the Mac sends on attach.
    func testScrollbackKeepsALongConversation() {
        let reader = input(mode: .view)
        let lines = (1...4_800).map { "conversation line \($0)\r\n" }.joined()
        reader.feed(text: lines + "LATEST")
        let text = String(data: reader.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("conversation line 1\n"), "The start of the conversation left the scrollback")
        XCTAssertTrue(text.contains("LATEST"))
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

    /// Round 20: letters a keyboard composes (Pinyin) show at the cursor,
    /// and nothing is sent until the keyboard commits them. The keyboard
    /// reaches the terminal through Objective-C, as here.
    func testComposedLettersShowAtTheCursorAndSendNothingUntilCommitted() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let writer = input()
        writer.frame = writer.getOptimalFrameSize()
        let sent = InputSpy()
        writer.terminalDelegate = sent
        window.rootViewController?.view.addSubview(writer)
        XCTAssertTrue(writer.becomeFirstResponder())
        writer.feed(text: "~$ ")
        let setMarked = NSSelectorFromString("setMarkedText:selectedRange:"), unmark = NSSelectorFromString("unmarkText")
        typealias SetMarked = @convention(c) (AnyObject, Selector, NSString?, NSRange) -> Void
        typealias Unmark = @convention(c) (AnyObject, Selector) -> Void
        let mark = unsafeBitCast(class_getMethodImplementation(type(of: writer), setMarked), to: SetMarked.self)
        let commit = unsafeBitCast(class_getMethodImplementation(type(of: writer), unmark), to: Unmark.self)
        mark(writer, setMarked, "l", NSRange(location: 1, length: 0))
        mark(writer, setMarked, "ls", NSRange(location: 2, length: 0))
        XCTAssertEqual(writer.composingText, "ls")
        XCTAssertTrue(writer.composingShown, "Composed letters show")
        XCTAssertTrue(sent.bytes.isEmpty, "Nothing is sent while composing")
        // The underlined letters sit at the cursor, after the prompt.
        let label = try XCTUnwrap(writer.subviews.compactMap { $0 as? UILabel }.first { !$0.isHidden })
        let cell = writer.getOptimalFrameSize().width / 80
        XCTAssertEqual(label.frame.minX, cell * 3, accuracy: 0.5)
        XCTAssertEqual(label.attributedText?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        // Confirm (Return while composing) commits the letters as typed.
        commit(writer, unmark)
        XCTAssertNil(writer.composingText)
        XCTAssertFalse(writer.composingShown)
        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), "ls")
        // A composition the keyboard clears sends nothing and hides.
        mark(writer, setMarked, "ni", NSRange(location: 2, length: 0))
        XCTAssertTrue(writer.composingShown)
        mark(writer, setMarked, nil, NSRange(location: 0, length: 0))
        XCTAssertFalse(writer.composingShown)
        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), "ls")
        // Leaving the keyboard hides it.
        mark(writer, setMarked, "a", NSRange(location: 1, length: 0))
        _ = writer.resignFirstResponder()
        XCTAssertFalse(writer.composingShown)
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
        // The bar's keys are hidden until the bar is.
        func buttons(_ view: UIView) -> [UIButton] { visibleButtons(view) }
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
        // The bar's keys are hidden until the bar is.
        func buttons(_ view: UIView) -> [UIButton] { visibleButtons(view) }
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
            // Hide Keyboard is pinned after the saved keys, not one of them.
            visibleButtons(accessory).compactMap(\.accessibilityIdentifier).filter { $0 != "terminalKey-hideKeyboard" }
        }
        XCTAssertEqual(identifiers(), ["terminalInterrupt", "terminalKey-escape"])
        // The Snippets key waits for a snippet, then takes its saved place.
        defaults.set(MobileKey.encode([.control, .snippets, .home]), forKey: MobileKey.key)
        XCTAssertEqual(identifiers(), ["terminalControlModifier", "terminalKey-home"])
        defaults.set(CommandSnippets.encode([CommandSnippet(name: "List", text: "ls")]), forKey: CommandSnippets.key)
        XCTAssertEqual(identifiers(), ["terminalControlModifier", "terminalKey-snippets", "terminalKey-home"])
    }

    /// Esc, Ctrl, Tab and the four arrows fit a 6.3-inch iPhone's width
    /// (402 pt) beside the pinned Hide Keyboard key without scrolling the
    /// row, each still a 44 pt target.
    func testFirstSevenKeysFitAnIPhoneWidth() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: MobileKey.key)
        defer { defaults.set(previous, forKey: MobileKey.key) }
        defaults.removeObject(forKey: MobileKey.key)
        let accessory = try XCTUnwrap(input().inputAccessoryView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        window.addSubview(accessory)
        accessory.frame = CGRect(x: 0, y: 600, width: 402, height: accessory.intrinsicContentSize.height)
        accessory.setNeedsLayout()
        accessory.layoutIfNeeded()
        let keys = visibleButtons(accessory)
        let right = try XCTUnwrap(keys.first { $0.accessibilityIdentifier == "terminalKey-right" })
        let edge = right.convert(right.bounds, to: accessory).maxX
        let hide = try XCTUnwrap(keys.first { $0.accessibilityIdentifier == "terminalKey-hideKeyboard" })
        XCTAssertLessThanOrEqual(edge, hide.convert(hide.bounds, to: accessory).minX,
                                 "Widths: \(keys.prefix(7).map { Int($0.bounds.width) })")
        for key in keys { XCTAssertGreaterThanOrEqual(key.bounds.width, 44); XCTAssertGreaterThanOrEqual(key.bounds.height, 44) }
    }

    /// Round 22: Hide Keyboard ends the row on the floating buttons' column
    /// (`FloatingTerminalButton.trailing` from the edge), with the bar's
    /// actions before it, so Jump to Latest and the keyboard button line up
    /// with it; before, it sat 6 pt from the edge (10 pt right of them) and
    /// the actions came after it.
    func testHideKeyboardEndsTheRowOnTheFloatingButtonsColumn() throws {
        let terminal = input()
        let accessory = try XCTUnwrap(terminal.inputAccessoryView as? MobileTerminalAccessory)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.addSubview(accessory)
        func hideFrame(width: CGFloat) throws -> CGRect {
            accessory.frame = CGRect(x: 0, y: 300, width: width, height: accessory.intrinsicContentSize.height)
            accessory.setNeedsLayout()
            accessory.layoutIfNeeded()
            let hide = try XCTUnwrap(visibleButtons(accessory).first { $0.accessibilityIdentifier == "terminalKey-hideKeyboard" })
            return hide.convert(hide.bounds, to: accessory)
        }
        XCTAssertEqual(try hideFrame(width: 402).maxX, 402 - FloatingTerminalButton.trailing, accuracy: 0.5)
        XCTAssertEqual(try hideFrame(width: 402).width, FloatingTerminalButton.side, accuracy: 0.5)
        terminal.setBarActions(AnyView(TerminalKeyRowActions { Button("Item") {} }))
        let hide = try hideFrame(width: 750)
        // With the actions key there too, Hide Keyboard still ends the row.
        XCTAssertEqual(hide.maxX, 750 - FloatingTerminalButton.trailing, accuracy: 0.5, "Hide Keyboard ends the row")
        terminal.setBarActions(nil)
    }

    private func visibleButtons(_ view: UIView) -> [UIButton] {
        guard !view.isHidden else { return [] }
        return (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(visibleButtons)
    }

    /// The key row always ends with Hide Keyboard, pinned outside the
    /// scrolling keys (Round 16: the keyboard button shows only while the
    /// keyboard is hidden); the bar's actions join it only while the bar is
    /// hidden for typing.
    func testHideKeyboardAlwaysEndsTheRowAndActionsJoinWhileTheBarIsHidden() throws {
        let terminal = input()
        let accessory = try XCTUnwrap(terminal.inputAccessoryView as? MobileTerminalAccessory)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.addSubview(accessory)
        func layOut() {
            accessory.frame = CGRect(x: 0, y: 350, width: 874, height: accessory.intrinsicContentSize.height)
            accessory.setNeedsLayout()
            accessory.layoutIfNeeded()
        }
        layOut()
        XCTAssertTrue(visibleButtons(accessory).contains { $0.accessibilityIdentifier == "terminalKey-hideKeyboard" })
        let actionsCount = visibleButtons(accessory).count
        terminal.setBarActions(AnyView(TerminalKeyRowActions { Button("Item") {} }))
        layOut()
        let hide = try XCTUnwrap(visibleButtons(accessory).first { $0.accessibilityIdentifier == "terminalKey-hideKeyboard" })
        XCTAssertEqual(hide.accessibilityLabel, String(localized: "Hide Keyboard", bundle: .main))
        XCTAssertGreaterThanOrEqual(hide.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(hide.bounds.height, 44)
        let frame = hide.convert(hide.bounds, to: accessory)
        XCTAssertLessThanOrEqual(frame.maxX, 874)
        XCTAssertGreaterThan(frame.minX, 874 - 160, "Pinned at the row's end, not scrolled with the keys")
        terminal.setBarActions(nil)
        layOut()
        XCTAssertTrue(visibleButtons(accessory).contains { $0.accessibilityIdentifier == "terminalKey-hideKeyboard" })
        XCTAssertEqual(visibleButtons(accessory).count, actionsCount, "The actions key leaves with the bar's return")
    }

    /// The bar steps aside only in a compact terminal on iPhone in landscape,
    /// while it has the keyboard, and never while VoiceOver runs.
    func testBarHidesOnlyWhileTypingInCompactLandscape() {
        func hides(_ enabled: Bool = true, _ horizontal: UserInterfaceSizeClass? = .compact, _ vertical: UserInterfaceSizeClass? = .compact,
                   voiceOver: Bool = false, focused: Bool = true) -> Bool {
            TerminalTypingBar.hidesBar(enabled: enabled, horizontal: horizontal, vertical: vertical, voiceOver: voiceOver, focused: focused)
        }
        XCTAssertTrue(hides())
        XCTAssertFalse(hides(focused: false), "Not without the keyboard")
        XCTAssertFalse(hides(true, .compact, .regular), "Not in portrait")
        XCTAssertFalse(hides(true, .regular, .compact), "Not on a regular width (iPad, a large iPhone in landscape)")
        XCTAssertFalse(hides(true, .regular, .regular), "Not on iPad")
        XCTAssertFalse(hides(voiceOver: true), "Not while VoiceOver runs")
        XCTAssertFalse(hides(false), "Not without a terminal that types")
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
