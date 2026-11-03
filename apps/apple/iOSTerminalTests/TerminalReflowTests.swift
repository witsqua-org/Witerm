import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// Round 14: a text size change reflows a typing terminal's grid at once,
/// from the new cell size, and tells the host once; a view-only grid keeps
/// the Mac's columns and rows and only draws them at the new size. Neither
/// goes through SwiftTerm's soft reset, which would drop the program's modes.
@MainActor final class TerminalReflowTests: XCTestCase {
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
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Reflow", createdAt: .now, columns: columns, rows: rows)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: mode, session: session, fontSize: 14, isInteractive: true)
        surface.frame = CGRect(x: 0, y: 120, width: 402, height: 700)
        window.rootViewController?.view.addSubview(surface)
        return surface
    }

    /// Layout passes only: nothing here changes the surface's frame.
    private func settle(_ surface: RemoteNativeTerminalView.TerminalSurface) async {
        for _ in 0..<3 {
            surface.setNeedsLayout()
            surface.layoutIfNeeded()
            surface.terminal.layoutIfNeeded()
            await Task.yield()
        }
    }

    private func grid(_ surface: RemoteNativeTerminalView.TerminalSurface) -> String {
        "\(surface.terminal.getTerminal().cols)x\(surface.terminal.getTerminal().rows)"
    }

    /// The whole cells of the current font that fit the text area.
    private func fitting(_ surface: RemoteNativeTerminalView.TerminalSurface) -> String {
        let core = surface.terminal.getTerminal(), frame = surface.terminal.getOptimalFrameSize()
        let cell = CGSize(width: frame.width / CGFloat(core.cols), height: frame.height / CGFloat(core.rows))
        let area = surface.readingView.frame
        return "\(Int(area.width / cell.width * (1 + 1e-9)))x\(Int(area.height / cell.height * (1 + 1e-9)))"
    }

    func testTextSizeChangeReflowsTheGridAtOnceAndTellsTheHost() async {
        let surface = surface(mode: .control)
        let spy = ReflowSizeSpy()
        surface.terminal.terminalDelegate = spy
        await settle(surface)
        let original = grid(surface)
        XCTAssertEqual(original, fitting(surface))
        // A program's mode that a soft reset would clear.
        surface.terminal.feed(text: "\u{1b}[?1h")
        XCTAssertTrue(surface.terminal.getTerminal().applicationCursor)
        spy.sizes.removeAll()

        surface.updateFontSize(20)
        await settle(surface)
        let larger = grid(surface)
        XCTAssertNotEqual(larger, original, "Larger text must change the grid without waiting for a resize")
        XCTAssertEqual(larger, fitting(surface), "The grid is the whole cells of the new size that fit")
        XCTAssertEqual(spy.sizes.last.map { "\($0.columns)x\($0.rows)" }, larger, "The host must be told the new grid")
        XCTAssertTrue(surface.terminal.getTerminal().applicationCursor, "A text size change must not soft-reset the terminal")

        surface.updateFontSize(14)
        await settle(surface)
        XCTAssertEqual(grid(surface), original, "The original size gives the original grid back")
        XCTAssertEqual(spy.sizes.last.map { "\($0.columns)x\($0.rows)" }, original)
        XCTAssertTrue(surface.terminal.getTerminal().applicationCursor)
    }

    /// One step, as from the actions menu, asks the host once.
    func testOneTextSizeStepAsksForOneResize() async {
        let surface = surface(mode: .control)
        let spy = ReflowSizeSpy()
        surface.terminal.terminalDelegate = spy
        await settle(surface)
        spy.sizes.removeAll()
        surface.updateFontSize(15)
        await settle(surface)
        try? await Task.sleep(for: .milliseconds(50))
        let distinct = spy.sizes.map { "\($0.columns)x\($0.rows)" }.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(distinct, [grid(surface)], "One size, once: \(spy.sizes)")
    }

    /// A watching (view-only) terminal keeps the Mac's grid: only the cells
    /// grow or shrink, and it never asks to resize.
    func testReadOnlyGridKeepsTheMacsGridWhenTextSizeChanges() async {
        let surface = surface(mode: .view, columns: 80, rows: 24)
        let spy = ReflowSizeSpy()
        surface.terminal.terminalDelegate = spy
        await settle(surface)
        surface.terminal.feed(text: "\u{1b}[?1h")
        let width = surface.terminal.frame.width
        for size: CGFloat in [20, 11, 14] {
            surface.updateFontSize(size)
            await settle(surface)
            XCTAssertEqual(grid(surface), "80x24", "font \(size)")
            XCTAssertEqual(surface.terminal.font.pointSize, size)
        }
        surface.updateFontSize(20)
        await settle(surface)
        XCTAssertGreaterThan(surface.terminal.frame.width, width, "Larger text draws the same grid larger")
        XCTAssertTrue(surface.terminal.getTerminal().applicationCursor, "A text size change must not soft-reset the terminal")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(spy.sizes.allSatisfy { $0.columns == 80 && $0.rows == 24 }, "A read-only view must never ask for another size: \(spy.sizes)")
    }
}

@MainActor private final class ReflowSizeSpy: NSObject, @preconcurrency TerminalViewDelegate {
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
