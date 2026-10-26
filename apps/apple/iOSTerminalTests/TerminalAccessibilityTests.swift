import UIKit
import SwiftUI
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

@MainActor final class TerminalAccessibilityTests: XCTestCase {
    private func session(_ columns: Int = 80, _ rows: Int = 24) -> LocalSessionInfo {
        LocalSessionInfo(id: "00000000-0000-4000-8000-000000000001", name: "In-memory accessibility",
                         createdAt: Date(timeIntervalSince1970: 0), columns: columns, rows: rows)
    }
    private func surface(mode: LocalAttachmentMode = .view, columns: Int = 80, rows: Int = 24) -> RemoteNativeTerminalView.TerminalSurface {
        let value = RemoteNativeTerminalView.TerminalSurface(mode: mode, session: session(columns, rows), fontSize: 14, isInteractive: true)
        value.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        value.setNeedsLayout()
        value.layoutIfNeeded()
        return value
    }
    private func settle(_ surface: RemoteNativeTerminalView.TerminalSurface) async {
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        await Task.yield()
        surface.terminal.layoutIfNeeded()
        surface.refreshReadingDocument()
    }

    func testTextInputReadingRangesMatchVTUnicodeAndRects() async throws {
        let surface = surface()
        surface.terminal.feed(text: "A中🙂e\u{301} 👩🏽‍💻\r\nword two")
        await settle(surface)
        let reader = surface.readingView, document = reader.readingDocument
        let source = document.text as NSString
        XCTAssertFalse(surface.terminal.isAccessibilityElement)
        XCTAssertTrue(surface.terminal.accessibilityElementsHidden)
        XCTAssertTrue(reader.isAccessibilityElement)
        for value in ["中", "🙂", "e\u{301}", "👩🏽‍💻"] {
            let expected = source.range(of: value)
            XCTAssertNotEqual(expected.location, NSNotFound)
            let range = try XCTUnwrap(reader.readingTextRange(expected))
            XCTAssertEqual(reader.text(in: range), value)
            for index in expected.location..<NSMaxRange(expected) { XCTAssertEqual(document.characterRange(at: index), expected) }
            let rect = reader.firstRect(for: range)
            XCTAssertFalse(rect.isEmpty)
            XCTAssertTrue(reader.bounds.contains(rect))
            let selections = reader.selectionRects(for: range)
            XCTAssertTrue(try XCTUnwrap(selections.first).containsStart)
            XCTAssertTrue(try XCTUnwrap(selections.last).containsEnd)
        }
        let cjk = source.range(of: "中")
        let cjkRect = reader.firstRect(for: try XCTUnwrap(reader.readingTextRange(cjk)))
        XCTAssertEqual(cjkRect.width, reader.cellSize.width * 2, accuracy: 0.01)
        let center = CGPoint(x: cjkRect.midX, y: cjkRect.midY)
        let hit = try XCTUnwrap(reader.characterRange(at: center))
        XCTAssertEqual(reader.text(in: hit), "中")
        XCTAssertEqual(reader.accessibilityContent(forLineNumber: 1), "word two")
        XCTAssertTrue(reader.ranges(for: .word).contains(source.range(of: "word")))
        XCTAssertTrue(reader.ranges(for: .character).contains(source.range(of: "👩🏽‍💻")))
        XCTAssertEqual(reader.accessibilityCustomRotors?.count, 3)
    }

    func testReadonlyAndFrozenReadingSelectionNeverChangesIMEOrWrites() async throws {
        let surface = surface()
        let spy = TerminalDelegateSpy()
        surface.terminal.terminalDelegate = spy
        surface.terminal.feed(text: "A🙂中")
        await settle(surface)
        let reader = surface.readingView
        let emoji = (reader.readingDocument.text as NSString).range(of: "🙂")
        let originalIME = surface.terminal.selectedTextRange
        reader.setReadingSelection(NSRange(location: emoji.location + 1, length: 1))
        XCTAssertEqual(reader.selectedRange, emoji)
        XCTAssertTrue(surface.terminal.selectedTextRange === originalIME)
        XCTAssertFalse(surface.terminal.canBecomeFirstResponder)
        XCTAssertFalse(reader.canBecomeFirstResponder)
        let text = reader.text
        surface.terminal.insertText("DENIED")
        surface.terminal.deleteBackward()
        reader.insertText("DENIED")
        XCTAssertEqual(reader.text, text)
        XCTAssertTrue(spy.bytes.isEmpty)
        reader.setReadingSelection(NSRange(location: Int.max, length: 1))
        XCTAssertEqual(reader.selectedRange, emoji)
        let control = self.surface(mode: .control)
        control.terminal.terminalDelegate = spy
        control.setInteractive(false)
        control.terminal.insertText("FROZEN")
        XCTAssertFalse(control.terminal.canBecomeFirstResponder)
        XCTAssertTrue(spy.bytes.isEmpty)
    }

    func testAlternateGeometryAndFontsKeepAuthoritativeGridAndVTContents() async {
        let surface = surface(columns: 120, rows: 40)
        surface.terminal.feed(text: "NORMAL\u{1b}[?1049h\u{1b}[HALTERNATE\u{1b}[1;120HX\u{1b}[H")
        await settle(surface)
        XCTAssertTrue(surface.readingView.readingDocument.alternate)
        XCTAssertFalse(surface.readingView.readingDocument.text.contains("NORMAL"))
        for size: CGFloat in [11, 14, 32] {
            for scheme in [ColorScheme.light, .dark] {
                for contrast in [false, true] {
                    surface.updateFontSize(size)
                    surface.updateAppearance(highContrast: contrast, scheme: scheme)
                    await settle(surface)
                    XCTAssertEqual(surface.terminal.getTerminal().cols, 120)
                    XCTAssertEqual(surface.terminal.getTerminal().rows, 40)
                    XCTAssertTrue(surface.terminal.getTerminal().isCurrentBufferAlternate)
                    XCTAssertEqual(surface.terminal.getTerminal().getCharacter(col: 0, row: 0), "A")
                    XCTAssertEqual(surface.terminal.getTerminal().getCharacter(col: 119, row: 0), "X", "Font update lost the last authoritative column")
                }
            }
        }
        surface.readingView.setReadingSelection(NSRange(location: 0, length: 1))
        surface.terminal.applyGeometry(session(130, 42))
        await settle(surface)
        XCTAssertEqual(surface.terminal.getTerminal().cols, 130)
        XCTAssertEqual(surface.terminal.getTerminal().rows, 42)
        XCTAssertEqual(surface.readingView.selectedRange.length, 0)
        XCTAssertTrue(surface.terminal.getTerminal().isCurrentBufferAlternate)
        surface.terminal.feed(text: "\u{1b}[?1049l")
        await settle(surface)
        XCTAssertFalse(surface.readingView.readingDocument.alternate)
    }

    func testActualRendererANSI16HighContrastPalette() async {
        let surface = surface()
        let spy = TerminalDelegateSpy()
        surface.terminal.terminalDelegate = spy
        for scheme in [ColorScheme.light, .dark] {
            surface.updateAppearance(highContrast: true, scheme: scheme)
            await settle(surface)
            for (index, color) in TerminalPalette.colors(highContrast: true, dark: scheme == .dark).enumerated() {
                spy.bytes.removeAll()
                surface.terminal.feed(text: "\u{1b}]4;\(index);?\u{7}")
                XCTAssertTrue(String(decoding: spy.bytes, as: UTF8.self).contains(color.formatted()), "Renderer ANSI16 differs at index \(index), theme \(scheme)")
                XCTAssertGreaterThanOrEqual(contrastRatio(color, dark: scheme == .dark), 4.5)
            }
        }
    }

    func testInheritedSystemAppearanceUpdatesColorsWithoutChangingReadonlyGrid() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let controller = UIViewController()
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = .light
        let surface = surface(columns: 120, rows: 40)
        controller.view.addSubview(surface)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        surface.updateAppearance(highContrast: true, scheme: nil)
        surface.terminal.feed(text: "\u{1b}[?1049h\u{1b}[HKEEP\u{1b}[1;120HX")
        for (style, background) in [(UIUserInterfaceStyle.dark, UIColor.black), (.light, .white)] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            await settle(surface)
            XCTAssertEqual(surface.traitCollection.userInterfaceStyle, style)
            XCTAssertEqual(surface.overrideUserInterfaceStyle, .unspecified)
            XCTAssertEqual(surface.terminal.nativeBackgroundColor, background)
            XCTAssertEqual(surface.terminal.getTerminal().cols, 120)
            XCTAssertEqual(surface.terminal.getTerminal().rows, 40)
            XCTAssertTrue(surface.terminal.getTerminal().isCurrentBufferAlternate)
            XCTAssertEqual(surface.terminal.getTerminal().getCharacter(col: 119, row: 0), "X")
        }
    }

    func testPagingAndContentMutationClearStaleSelection() async {
        let surface = surface(columns: 40, rows: 5)
        for index in 0..<25 { surface.terminal.feed(text: "public row \(index)\r\n") }
        await settle(surface)
        let reader = surface.readingView
        let bottom = reader.readingDocument.topRow
        reader.setReadingSelection(NSRange(location: 0, length: min(3, reader.readingDocument.length)))
        XCTAssertTrue(reader.accessibilityScroll(.previous))
        XCTAssertLessThan(reader.readingDocument.topRow, bottom)
        XCTAssertEqual(reader.selectedRange.length, 0)
        XCTAssertTrue(reader.accessibilityScroll(.next))
        surface.terminal.feed(text: "\u{1b}[2J\u{1b}[HDIFFERENT")
        await settle(surface)
        XCTAssertFalse(reader.readingDocument.text.contains("public row"))
    }

    func testSmallControlViewportAndInvalidPublicRanges() async {
        let surface = surface(mode: .control)
        surface.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        await settle(surface)
        for size: CGFloat in [11, 14, 32] {
            surface.updateFontSize(size)
            await settle(surface)
            XCTAssertGreaterThanOrEqual(surface.terminal.getTerminal().cols, 20)
            XCTAssertGreaterThanOrEqual(surface.terminal.getTerminal().rows, 5)
        }
        XCTAssertGreaterThan(surface.terminal.frame.width, surface.bounds.width)
        let reader = surface.readingView
        XCTAssertNil(reader.readingTextRange(NSRange(location: Int.max, length: Int.max)))
        XCTAssertEqual(reader.accessibilityFrame(forLineNumber: Int.max), .zero)
        XCTAssertNil(reader.closestPosition(to: CGPoint(x: CGFloat.infinity, y: 0)))
        XCTAssertNil(reader.characterRange(at: CGPoint(x: -1, y: -1)))
        let page = TerminalAXViewport.cells(in: CGRect.infinite, origin: .zero,
            cellSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.infinity), columns: 500, rows: 200)
        XCTAssertTrue(page.columns.isEmpty)
        XCTAssertTrue(page.rows.isEmpty)
    }

    func testHorizontalReadingUsesOnlyVisibleCellsAndCanRevealRightEdge() async {
        let surface = surface(columns: 120, rows: 5)
        surface.terminal.feed(text: "LEFT\u{1b}[1;81HEDGE\u{1b}[H")
        await settle(surface)
        XCTAssertTrue(surface.readingView.readingDocument.text.contains("LEFT"))
        XCTAssertFalse(surface.readingView.readingDocument.text.contains("EDGE"))
        XCTAssertTrue(surface.readingView.accessibilityScroll(.left))
        XCTAssertTrue(surface.readingView.readingDocument.text.contains("EDGE"))
        XCTAssertFalse(surface.readingView.readingDocument.text.contains("LEFT"))
        XCTAssertTrue(surface.readingView.accessibilityScroll(.right))
        XCTAssertTrue(surface.readingView.readingDocument.text.contains("LEFT"))
    }

    func testOuterScrollImmediatelyUpdatesReadingPageWithoutExplicitRefresh() async throws {
        let surface = surface(columns: 120, rows: 5)
        surface.terminal.feed(text: "LEFT\u{1b}[1;81HEDGE\u{1b}[H")
        await settle(surface)
        let outer = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIScrollView }
            .first(where: { !($0 is UITextView) }))
        XCTAssertTrue(surface.readingView.readingDocument.text.contains("LEFT"))
        outer.setContentOffset(CGPoint(x: outer.bounds.width, y: 0), animated: false)
        // No layout or explicit AX refresh: this is the native scroll delegate path.
        let reader = surface.readingView
        let edge = (reader.readingDocument.text as NSString).range(of: "EDGE")
        guard edge.location != NSNotFound else {
            XCTFail("AX page did not follow the outer scroll offset")
            return
        }
        XCTAssertFalse(reader.readingDocument.text.contains("LEFT"))
        let first = try XCTUnwrap(reader.readingTextRange(NSRange(location: edge.location, length: 1)))
        let rect = reader.firstRect(for: first)
        XCTAssertFalse(rect.isEmpty)
        XCTAssertTrue(reader.bounds.contains(rect))
        let hit = try XCTUnwrap(reader.characterRange(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(reader.text(in: hit), "E")
        outer.setContentOffset(.zero, animated: false)
        XCTAssertTrue(reader.readingDocument.text.contains("LEFT"))
        XCTAssertFalse(reader.readingDocument.text.contains("EDGE"))
    }

    func testControlAlternateReadingPagesAndPansNeverSendKeysOrMoveCaret() async {
        let surface = surface(mode: .control)
        surface.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        await settle(surface)
        let spy = TerminalDelegateSpy()
        surface.terminal.terminalDelegate = spy
        surface.terminal.feed(text: "\u{1b}[?1049h\u{1b}[HREADING")
        await settle(surface)
        XCTAssertTrue(surface.terminal.getTerminal().isCurrentBufferAlternate)
        let caret = surface.terminal.getTerminal().getCursorLocation()
        let reader = surface.readingView
        let actions: [() -> Bool] = [
            { surface.pageReading(forward: true) }, { surface.pageReading(forward: false) },
            { surface.panReading(forward: true) }, { surface.panReading(forward: false) },
            { reader.accessibilityScroll(.next) }, { reader.accessibilityScroll(.previous) },
            { reader.accessibilityScroll(.left) }, { reader.accessibilityScroll(.right) }
        ]
        for action in actions {
            var reachedBoundary = false
            for _ in 0..<256 {
                if !action() { reachedBoundary = true; break }
            }
            XCTAssertTrue(reachedBoundary, "Reading scroll did not report its local viewport boundary")
            XCTAssertFalse(action(), "Reading scroll crossed its local viewport boundary")
            XCTAssertTrue(spy.bytes.isEmpty, "Accessibility reading sent application keys")
            XCTAssertEqual(surface.terminal.getTerminal().getCursorLocation().x, caret.x)
            XCTAssertEqual(surface.terminal.getTerminal().getCursorLocation().y, caret.y)
        }
    }

    private func contrastRatio(_ color: SwiftTerm.Color, dark: Bool) -> Double {
        func linear(_ component: UInt16) -> Double {
            let value = Double(component) / 65535
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        return dark ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05)
    }
}

@MainActor private final class TerminalDelegateSpy: NSObject, @preconcurrency TerminalViewDelegate {
    var bytes = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { }
    func setTerminalTitle(source: TerminalView, title: String) { }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
    func scrolled(source: TerminalView, position: Double) { }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { }
    func bell(source: TerminalView) { }
    func clipboardCopy(source: TerminalView, content: Data) { }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }
}
