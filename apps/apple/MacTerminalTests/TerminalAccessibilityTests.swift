import AppKit
import SwiftUI
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermMac

@MainActor final class TerminalAccessibilityTests: XCTestCase {
    private func terminal(mode: LocalAttachmentMode = .view, columns: Int = 80, rows: Int = 8) -> MacTerminalTextView {
        let view = MacTerminalTextView(mode: mode, columns: columns, rows: rows)
        view.frame = view.getOptimalFrameSize()
        view.layoutSubtreeIfNeeded()
        return view
    }
    private func geometry(_ columns: Int, _ rows: Int) -> LocalSessionInfo {
        LocalSessionInfo(id: "00000000-0000-4000-8000-000000000001", name: "In-memory accessibility",
                         createdAt: Date(timeIntervalSince1970: 0), columns: columns, rows: rows)
    }

    func testPublicTextRangesUnicodeAndCellRectangles() throws {
        let view = terminal()
        view.feed(text: "A中🙂e\u{301} 👩🏽‍💻\r\nword two")
        view.refreshReadingDocument()
        let document = view.readingDocument
        let navigable: any NSAccessibilityProtocol = view
        let source = document.text as NSString
        for value in ["中", "🙂", "e\u{301}", "👩🏽‍💻"] {
            let expected = source.range(of: value)
            XCTAssertNotEqual(expected.location, NSNotFound)
            for index in expected.location..<NSMaxRange(expected) {
                XCTAssertEqual(view.accessibilityRange(for: index), expected)
            }
            XCTAssertEqual(navigable.accessibilityString(for: expected), value)
        }
        let cjk = source.range(of: "中")
        let rect = try XCTUnwrap(view.localReadingRectangles(for: cjk).first)
        XCTAssertEqual(rect.width, view.readingCellSize.width * 2, accuracy: 0.01)
        let line = navigable.accessibilityRange(forLine: 1)
        XCTAssertEqual(navigable.accessibilityString(for: line), "word two")
        XCTAssertEqual(view.accessibilityLine(for: source.range(of: "word").location), 1)
        XCTAssertTrue(document.wordRanges.contains(source.range(of: "word")))
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), source.length)
    }

    func testReadingSelectionCaretAndReadonlyNeverWrites() {
        let view = terminal()
        let spy = TerminalDelegateSpy()
        view.terminalDelegate = spy
        view.feed(text: "A🙂中")
        view.refreshReadingDocument()
        let before = view.getTerminal().getCursorLocation()
        let emoji = (view.readingDocument.text as NSString).range(of: "🙂")
        view.setAccessibilitySelectedTextRange(NSRange(location: emoji.location + 1, length: 1))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), emoji)
        XCTAssertEqual(view.accessibilitySelectedText(), "🙂")
        XCTAssertEqual(view.getTerminal().getCursorLocation().x, before.x)
        XCTAssertEqual(view.getTerminal().getCursorLocation().y, before.y)
        view.setAccessibilitySelectedTextRange(NSRange(location: Int.max, length: Int.max))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), emoji)
        view.setAccessibilityFocused(true)
        XCTAssertTrue(view.isAccessibilityFocused())
        view.insertText("must not send", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(spy.bytes.isEmpty)
        XCTAssertFalse(view.isAccessibilitySelectorAllowed(#selector(view.setAccessibilityValue(_:))))
        XCTAssertEqual(view.readingDocument.caret, view.readingDocument.index(row: before.y, column: before.x))
    }

    func testGeometryAlternateBufferAndScrollPagesInvalidateSelection() {
        let view = terminal(rows: 5)
        view.feed(text: "NORMAL")
        view.refreshReadingDocument()
        view.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 6))
        view.feed(text: "\u{1b}[?1049h\u{1b}[HALTERNATE")
        view.refreshReadingDocument()
        XCTAssertTrue(view.readingDocument.alternate)
        XCTAssertTrue(view.readingDocument.text.contains("ALTERNATE"))
        XCTAssertFalse(view.readingDocument.text.contains("NORMAL"))
        XCTAssertEqual(view.accessibilitySelectedTextRange().length, 0)
        view.applyGeometry(geometry(120, 40))
        XCTAssertEqual(view.getTerminal().cols, 120)
        XCTAssertEqual(view.getTerminal().rows, 40)
        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate)
        view.feed(text: "\u{1b}[?1049l")
        view.refreshReadingDocument()
        XCTAssertFalse(view.readingDocument.alternate)
        let scrolling = terminal(rows: 5)
        for index in 0..<20 { scrolling.feed(text: "public row \(index)\r\n") }
        scrolling.refreshReadingDocument()
        let bottom = scrolling.readingDocument.topRow
        XCTAssertTrue(scrolling.pageReading(forward: false))
        XCTAssertLessThan(scrolling.readingDocument.topRow, bottom)
        XCTAssertTrue(scrolling.pageReading(forward: true))
    }

    func testFontThemeAndActualANSI16PalettePreserveReadonlyGrid() {
        let surface = NativeTerminalView.TerminalSurface(mode: .view, columns: 120, rows: 40)
        surface.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let spy = TerminalDelegateSpy()
        surface.terminal.terminalDelegate = spy
        surface.terminal.feed(text: "\u{1b}[?1049h\u{1b}[HKEEP\u{1b}[1;120HX\u{1b}[H")
        for size: CGFloat in [11, 14, 32] {
            for scheme in [ColorScheme.light, .dark] {
                for contrast in [false, true] {
                    surface.updateAppearance(fontSize: size, highContrast: contrast, scheme: scheme)
                    surface.layoutSubtreeIfNeeded()
                    XCTAssertEqual(surface.terminal.getTerminal().cols, 120)
                    XCTAssertEqual(surface.terminal.getTerminal().rows, 40)
                    XCTAssertTrue(surface.terminal.getTerminal().isCurrentBufferAlternate)
                    XCTAssertEqual(surface.terminal.getTerminal().getCharacter(col: 119, row: 0), "X")
                    let dark = scheme == .dark
                    for (index, color) in TerminalPalette.colors(highContrast: contrast, dark: dark).enumerated() {
                        spy.bytes.removeAll()
                        surface.terminal.feed(text: "\u{1b}]4;\(index);?\u{7}")
                        XCTAssertTrue(String(decoding: spy.bytes, as: UTF8.self).contains(color.formatted()), "Renderer ANSI palette differs")
                        if contrast { XCTAssertGreaterThanOrEqual(contrastRatio(color, dark: dark), 4.5) }
                    }
                }
            }
        }
    }

    func testInheritedSystemAppearanceUpdatesColorsWithoutChangingReadonlyGrid() throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 280))
        host.appearance = NSAppearance(named: .aqua)
        let surface = NativeTerminalView.TerminalSurface(mode: .view, columns: 120, rows: 40)
        host.addSubview(surface)
        surface.frame = host.bounds
        surface.updateAppearance(fontSize: 14, highContrast: true, scheme: nil)
        surface.terminal.feed(text: "\u{1b}[?1049h\u{1b}[HKEEP\u{1b}[1;120HX")
        for (appearance, background) in [(NSAppearance.Name.darkAqua, NSColor.black), (.aqua, .white)] {
            host.appearance = NSAppearance(named: appearance)
            surface.layoutSubtreeIfNeeded()
            XCTAssertNil(surface.appearance, "The terminal must inherit system appearance")
            XCTAssertEqual(surface.terminal.nativeBackgroundColor, background)
            XCTAssertEqual(surface.terminal.getTerminal().cols, 120)
            XCTAssertEqual(surface.terminal.getTerminal().rows, 40)
            XCTAssertTrue(surface.terminal.getTerminal().isCurrentBufferAlternate)
            XCTAssertEqual(surface.terminal.getTerminal().getCharacter(col: 119, row: 0), "X")
        }
    }

    func testControlViewportMinimumAndPathologicalRanges() {
        let surface = NativeTerminalView.TerminalSurface(mode: .control, columns: 80, rows: 24)
        surface.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        surface.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(surface.terminal.getTerminal().cols, 20)
        XCTAssertGreaterThanOrEqual(surface.terminal.getTerminal().rows, 5)
        let view = terminal()
        view.feed(text: "bounded 中")
        view.refreshReadingDocument()
        let document = view.readingDocument
        XCTAssertNil(document.string(for: NSRange(location: Int.max, length: 1)))
        XCTAssertNil(document.normalizedSelection(NSRange(location: -1, length: 1)))
        XCTAssertEqual(document.characterRange(at: -1).location, NSNotFound)
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 12), CGSize(width: 8, height: CGFloat.greatestFiniteMagnitude)] {
            let range = document.range(at: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude), cellSize: size)
            XCTAssertEqual(range.location, NSNotFound)
            XCTAssertTrue(document.rectangles(for: NSRange(location: 0, length: 3), cellSize: size).allSatisfy { $0.maxX.isFinite && $0.maxY.isFinite })
        }
        for rect in [CGRect.infinite, CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 10, height: 10)] {
            let page = TerminalAXViewport.cells(in: rect, origin: .zero, cellSize: CGSize(width: 8, height: 12), columns: 80, rows: 24)
            XCTAssertTrue(page.rows.isEmpty)
            XCTAssertTrue(page.columns.isEmpty)
        }
    }

    func testControlAlternateReadingPagesAndPansNeverSendKeysOrMoveCaret() {
        let surface = NativeTerminalView.TerminalSurface(mode: .control, columns: 80, rows: 24)
        surface.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        surface.layoutSubtreeIfNeeded()
        let view = surface.terminal
        let spy = TerminalDelegateSpy()
        view.terminalDelegate = spy
        view.feed(text: "\u{1b}[?1049h\u{1b}[HREADING")
        view.refreshReadingDocument()
        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate)
        let caret = view.getTerminal().getCursorLocation()
        let actions: [() -> Bool] = [
            { view.pageReading(forward: true) }, { view.pageReading(forward: false) },
            { view.panReading(forward: true) }, { view.panReading(forward: false) }
        ]
        for action in actions {
            var reachedBoundary = false
            for _ in 0..<256 {
                if !action() { reachedBoundary = true; break }
            }
            XCTAssertTrue(reachedBoundary, "Reading scroll did not report its local viewport boundary")
            XCTAssertFalse(action(), "Reading scroll crossed its local viewport boundary")
            XCTAssertTrue(spy.bytes.isEmpty, "Accessibility reading sent application keys")
            XCTAssertEqual(view.getTerminal().getCursorLocation().x, caret.x)
            XCTAssertEqual(view.getTerminal().getCursorLocation().y, caret.y)
        }
    }

    func testReadonlyViewportStartsAtTopLeftAndPreservesScrolledCellAnchor() throws {
        let surface = NativeTerminalView.TerminalSurface(mode: .view, columns: 120, rows: 40)
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 280)
        surface.layoutSubtreeIfNeeded()
        let view = surface.terminal
        view.feed(text: "HEADER\u{1b}[8;6HANCHOR\u{1b}[H")
        view.refreshReadingDocument()
        XCTAssertFalse(view.isFlipped)
        let header = (view.readingDocument.text as NSString).range(of: "HEADER")
        XCTAssertNotEqual(header.location, NSNotFound, "Initial readonly viewport hid the first VT row")
        let rect = try XCTUnwrap(view.localReadingRectangles(for: header).first)
        XCTAssertTrue(view.visibleRect.contains(rect))
        XCTAssertEqual(view.readingDocument.lines.first?.row, 0)
        XCTAssertEqual(view.readingDocument.lines.first?.startColumn, 0)

        let scroll = try XCTUnwrap(view.enclosingScrollView)
        let cell = view.readingCellSize
        scroll.contentView.scroll(to: CGPoint(x: cell.width * 5,
            y: view.bounds.height - scroll.contentView.bounds.height - cell.height * 7))
        scroll.reflectScrolledClipView(scroll.contentView)
        view.refreshReadingDocument()
        func anchor() -> CGPoint {
            let size = view.readingCellSize, visible = scroll.contentView.bounds
            return CGPoint(x: visible.minX / size.width,
                           y: (view.bounds.height - visible.maxY) / size.height)
        }
        let original = anchor()
        XCTAssertGreaterThan(original.x, 0)
        XCTAssertGreaterThan(original.y, 0)
        for size: CGFloat in [24, 11, 32, 14] {
            surface.updateAppearance(fontSize: size, highContrast: false, scheme: .light)
            surface.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.getTerminal().cols, 120)
            XCTAssertEqual(view.getTerminal().rows, 40)
            XCTAssertEqual(anchor().x, original.x, accuracy: 0.05)
            XCTAssertEqual(anchor().y, original.y, accuracy: 0.05)
            XCTAssertTrue(view.readingDocument.text.contains("ANCHOR"))
        }
        surface.frame.size = CGSize(width: 460, height: 300)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(anchor().x, original.x, accuracy: 0.05)
        XCTAssertEqual(anchor().y, original.y, accuracy: 0.05)
        XCTAssertEqual(view.getTerminal().cols, 120)
        XCTAssertEqual(view.getTerminal().rows, 40)
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
