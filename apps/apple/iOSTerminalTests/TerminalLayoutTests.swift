import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// The terminal around the keyboard: a typing view fits the space left above
/// it without losing its width or its prompt, and gets its rows back after; a
/// view-only grid ignores it entirely. Selection copies exactly what's shown.
@MainActor final class TerminalLayoutTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func surface(mode: LocalAttachmentMode, columns: Int = 45, rows: Int = 40) -> RemoteNativeTerminalView.TerminalSurface {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Layout", createdAt: .now, columns: columns, rows: rows)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: mode, session: session, fontSize: 14, isInteractive: true)
        surface.frame = CGRect(x: 0, y: 120, width: 402, height: 700)
        window.rootViewController?.view.addSubview(surface)
        return surface
    }

    private func settle(_ surface: RemoteNativeTerminalView.TerminalSurface) async {
        for _ in 0..<3 {
            surface.setNeedsLayout()
            surface.layoutIfNeeded()
            surface.terminal.layoutIfNeeded()
            await Task.yield()
        }
    }

    /// The last line fully on screen, as the reading view (and VoiceOver) sees it.
    private func lastVisibleLine(_ surface: RemoteNativeTerminalView.TerminalSurface) -> String {
        surface.refreshReadingDocument()
        return surface.readingView.readingDocument.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }

    private func feedLines(_ surface: RemoteNativeTerminalView.TerminalSurface, count: Int) {
        for line in 1...count { surface.terminal.feed(text: "line \(line)\r\n") }
        surface.terminal.feed(text: "host:~$ ")
    }

    func testKeyboardKeepsWidthAndPromptThenGivesRowsBack() async {
        let surface = surface(mode: .control)
        let spy = SizeSpy()
        surface.terminal.terminalDelegate = spy
        await settle(surface)
        feedLines(surface, count: 80)
        await settle(surface)
        let core = surface.terminal.getTerminal()
        let full = (columns: core.cols, rows: core.rows)
        XCTAssertGreaterThanOrEqual(full.rows, 30)
        XCTAssertEqual(lastVisibleLine(surface), "host:~$", "The prompt must be on screen")

        // The keyboard and its key row take the lower part of the screen.
        surface.frame.size.height = 247
        await settle(surface)
        XCTAssertEqual(core.cols, full.columns, "The keyboard must never change the width")
        XCTAssertLessThan(core.rows, full.rows)
        XCTAssertEqual(lastVisibleLine(surface), "host:~$", "The prompt must stay fully above the keyboard; offset \(surface.terminal.contentOffset), frame \(surface.terminal.frame), rows \(core.rows)")
        XCTAssertEqual(spy.sizes.last?.columns, full.columns)

        // Hiding it restores the same grid, with the prompt still in view.
        surface.frame.size.height = 700
        await settle(surface)
        XCTAssertEqual(core.cols, full.columns)
        XCTAssertEqual(core.rows, full.rows, "Hiding the keyboard must give every row back")
        XCTAssertEqual(lastVisibleLine(surface), "host:~$", "The prompt must stay in view; offset \(surface.terminal.contentOffset)")
        // Round 22: the part of a row left over is at the top, as for a
        // watched grid, so the last row sits on the bottom edge.
        XCTAssertEqual(surface.terminal.frame.maxY, surface.bounds.height, accuracy: 1, "No band under the terminal")
        let cell = surface.terminal.getOptimalFrameSize().height / CGFloat(core.rows)
        XCTAssertGreaterThan(surface.terminal.frame.height, surface.bounds.height - cell, "Less than a row left over")
    }

    /// Whatever height the keyboard leaves (it varies with the device, text
    /// size and keyboard), and whatever the text size, the prompt stays whole.
    func testPromptStaysWholeAtEveryHeightAndTextSize() async {
        let surface = surface(mode: .control)
        surface.terminal.terminalDelegate = SizeSpy()
        await settle(surface)
        feedLines(surface, count: 80)
        for font: CGFloat in [12, 14, 15.5, 17, 20] {
            surface.updateFontSize(font)
            for height in stride(from: CGFloat(180), through: 420, by: 7.5) {
                surface.frame.size.height = height
                await settle(surface)
                XCTAssertEqual(lastVisibleLine(surface), "host:~$",
                               "font \(font), height \(height): rows \(surface.terminal.getTerminal().rows), offset \(surface.terminal.contentOffset.y), content \(surface.terminal.contentSize.height), frame \(surface.terminal.frame.height)")
            }
        }
    }

    /// An SSH terminal receives its first output before it is on screen, at
    /// its initial 80 × 24; shown narrower and above the keyboard, the prompt
    /// still ends the view, and output that follows keeps it there.
    func testOutputBeforeFirstLayoutStillEndsAtThePrompt() async {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Early", createdAt: .now, columns: 80, rows: 24)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        surface.terminal.terminalDelegate = SizeSpy()
        let motd = "Welcome to Alpine!\r\n\r\nThe Alpine Wiki contains a large amount of how-to guides and general\r\n"
            + "information about administrating Alpine systems.\r\nSee <https://wiki.alpinelinux.org/>.\r\n\r\n"
        surface.terminal.feed(text: motd + motd + "host:~$ ")
        surface.frame = CGRect(x: 0, y: 246, width: 402, height: 247)
        window.rootViewController?.view.addSubview(surface)
        await settle(surface)
        XCTAssertEqual(lastVisibleLine(surface), "host:~$", "offset \(surface.terminal.contentOffset.y), content \(surface.terminal.contentSize.height), rows \(surface.terminal.getTerminal().rows)")
        surface.terminal.feed(text: "\r\n" + motd + "host:~$ ")
        await settle(surface)
        XCTAssertEqual(lastVisibleLine(surface), "host:~$", "offset \(surface.terminal.contentOffset.y), content \(surface.terminal.contentSize.height)")
        // The keyboard animates in over several frames.
        for height in stride(from: CGFloat(600), through: 247, by: -40) {
            surface.frame.size.height = height
            await settle(surface)
        }
        surface.frame.size.height = 247
        await settle(surface)
        XCTAssertEqual(lastVisibleLine(surface), "host:~$", "offset \(surface.terminal.contentOffset.y), content \(surface.terminal.contentSize.height)")
    }

    /// A touch scroll, or following output, moves SwiftTerm's rows by setting
    /// its content offset without telling the delegate. The reading page
    /// (what VoiceOver reads) is rebuilt anyway, once per run-loop turn.
    func testReadingPageFollowsContentOffsetChanges() async throws {
        let surface = surface(mode: .control)
        surface.terminal.terminalDelegate = SizeSpy()
        await settle(surface)
        feedLines(surface, count: 200)
        await settle(surface)
        let refreshes = FocusCount()
        let previous = surface.terminal.readingChanged
        surface.terminal.readingChanged = { output in refreshes.value += 1; previous?(output) }
        for step in 1...10 { surface.terminal.contentOffset.y -= CGFloat(step) }
        XCTAssertEqual(refreshes.value, 0, "Rebuilt after the scroll steps, not during each")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(refreshes.value, 1, "One rebuild for a burst of scroll steps")
    }

    /// SSH output gathers off the main thread and is fed in one batch: only
    /// the first chunk after a delivery schedules another, nothing is lost or
    /// reordered, and past its bound it reports overflow instead of growing.
    func testSSHOutputBatchesInOrderWithinItsBound() {
        let batch = SSHOutputBatch()
        XCTAssertEqual(batch.append(Data("one ".utf8)), .first)
        XCTAssertEqual(batch.append(Data("two ".utf8)), .queued)
        XCTAssertEqual(String(decoding: batch.take(), as: UTF8.self), "one two ")
        XCTAssertTrue(batch.take().isEmpty)
        XCTAssertEqual(batch.append(Data("three".utf8)), .first)
        XCTAssertEqual(batch.append(Data(count: SSHOutputBatch.limit)), .overflow)
        XCTAssertEqual(String(decoding: batch.take(), as: UTF8.self), "three")
    }

    /// Thousands of lines into the scrollback, the bottom edge lands a hair
    /// short of a whole row in floating point; the last row (the prompt)
    /// must still be on the reading page.
    func testReadingPageKeepsLastRowFarIntoScrollback() {
        let cell = CGSize(width: 8.7, height: 17.05)
        let origin = CGPoint(x: 0, y: 2_985 * cell.height)
        let edge = origin.y + 15 * cell.height
        let visible = CGRect(x: 0, y: edge - 614, width: 402, height: 614)
        let page = TerminalAXViewport.cells(in: visible.offsetBy(dx: 0, dy: -1e-9), origin: origin, cellSize: cell, columns: 46, rows: 15)
        XCTAssertEqual(page.rows, 0..<15)
        // A row that is really cut off still is.
        let clipped = TerminalAXViewport.cells(in: visible.offsetBy(dx: 0, dy: -2), origin: origin, cellSize: cell, columns: 46, rows: 15)
        XCTAssertEqual(clipped.rows, 0..<14)
    }

    /// A fling that comes to rest a few points short of the bottom (within
    /// half a row, so SwiftTerm already follows output again) is finished,
    /// so the prompt isn't cut off and stays on the reading page.
    func testScrollRestingJustShortOfTheBottomFinishesThere() async {
        let surface = surface(mode: .control)
        surface.terminal.terminalDelegate = SizeSpy()
        surface.frame.size.height = 267
        await settle(surface)
        feedLines(surface, count: 600)
        await settle(surface)
        let terminal = surface.terminal
        let bottom = terminal.contentSize.height - terminal.bounds.height
        terminal.contentOffset.y = bottom - 3.33
        XCTAssertEqual(terminal.scrollPosition, 1, "Within half a row, SwiftTerm counts it as the bottom")
        terminal.scrollViewDidEndDecelerating(terminal)
        XCTAssertEqual(terminal.contentOffset.y, bottom, accuracy: 0.01)
        await settle(surface)
        XCTAssertEqual(lastVisibleLine(surface), "host:~$")
    }

    /// The keyboard animates the height through in-between frames; when the
    /// last step keeps the row count, the view still ends on the bottom.
    func testAnimatedHeightKeepsFollowingViewOnTheBottom() async {
        let surface = surface(mode: .control)
        surface.terminal.terminalDelegate = SizeSpy()
        await settle(surface)
        feedLines(surface, count: 600)
        await settle(surface)
        for height: CGFloat in [400, 320, 270.33, 267] {
            surface.frame.size.height = height
            await settle(surface)
        }
        let terminal = surface.terminal
        XCTAssertEqual(terminal.contentOffset.y, terminal.contentSize.height - terminal.bounds.height, accuracy: 0.01)
        XCTAssertEqual(lastVisibleLine(surface), "host:~$")
    }

    /// A view-only (authoritative) grid never follows this device's space.
    func testReadOnlyGridIgnoresTheKeyboard() async {
        let surface = surface(mode: .view, columns: 80, rows: 24)
        let spy = SizeSpy()
        surface.terminal.terminalDelegate = spy
        await settle(surface)
        feedLines(surface, count: 30)
        await settle(surface)
        surface.frame.size.height = 247
        await settle(surface)
        surface.frame.size.height = 700
        await settle(surface)
        XCTAssertEqual(surface.terminal.getTerminal().cols, 80)
        XCTAssertEqual(surface.terminal.getTerminal().rows, 24)
        XCTAssertTrue(spy.sizes.isEmpty, "A read-only view must never ask to resize: \(spy.sizes)")
    }

    /// Copy takes exactly the selected text: no trailing padding on short
    /// lines, and no line break where a long line merely wrapped.
    func testSelectionCopiesExactlyTheText() async {
        let surface = surface(mode: .view, columns: 20, rows: 6)
        await settle(surface)
        let long = String(repeating: "abcde", count: 6)
        surface.terminal.feed(text: "short\r\n" + long + "\r\nend")
        await settle(surface)
        let selection = surface.terminal.selection!
        selection.select(row: 0)
        XCTAssertEqual(selection.getSelectedText().trimmingCharacters(in: .newlines), "short")
        selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 10, row: 2))
        XCTAssertEqual(selection.getSelectedText(), long)
        selection.selectNone()
    }
}

@MainActor private final class SizeSpy: NSObject, @preconcurrency TerminalViewDelegate {
    var sizes: [(columns: Int, rows: Int)] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { sizes.append((newCols, newRows)) }
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

@MainActor private final class FocusCount {
    var value = 0
}
