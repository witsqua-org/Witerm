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

/// Pinching: the drawn text scales live about the fingers with nothing
/// recomputed, then one size is set as they lift, with one reflow and one
/// resize, in the same pass (no frame at the old size in between).
@MainActor final class TerminalPinchTests: XCTestCase {
    private var window: UIWindow!
    private var savedSize: Any?

    override func setUp() async throws {
        savedSize = UserDefaults.standard.object(forKey: TerminalFontSize.key)
        UserDefaults.standard.set(14.0, forKey: TerminalFontSize.key)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        if let savedSize { UserDefaults.standard.set(savedSize, forKey: TerminalFontSize.key) }
        else { UserDefaults.standard.removeObject(forKey: TerminalFontSize.key) }
        window.isHidden = true
        window = nil
    }

    private func surface(mode: LocalAttachmentMode, columns: Int = 45, rows: Int = 40) async -> RemoteNativeTerminalView.TerminalSurface {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Pinch", createdAt: .now, columns: columns, rows: rows)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: mode, session: session, fontSize: 14, isInteractive: true)
        surface.frame = CGRect(x: 0, y: 120, width: 402, height: 700)
        window.rootViewController?.view.addSubview(surface)
        for _ in 0..<3 { surface.setNeedsLayout(); surface.layoutIfNeeded(); await Task.yield() }
        return surface
    }

    private func grid(_ surface: RemoteNativeTerminalView.TerminalSurface) -> String {
        "\(surface.terminal.getTerminal().cols)x\(surface.terminal.getTerminal().rows)"
    }

    func testPinchScalesLiveAboutTheFingersThenSetsOneSize() async throws {
        let surface = await surface(mode: .control)
        let spy = PinchSizeSpy()
        surface.terminal.terminalDelegate = spy
        let before = grid(surface)
        let scroll = try XCTUnwrap(surface.terminal.superview)
        let anchor = CGPoint(x: 100, y: 200)
        let underFingers = scroll.convert(anchor, from: surface)
        let layouts = surface.fullLayouts
        for step in 1...30 {
            let scale = 1 + CGFloat(step) * 0.0143
            surface.pinchMoved(scale: scale, at: anchor)
            surface.layoutIfNeeded()   // as each frame's commit would
            XCTAssertEqual(scroll.transform.a, scale, accuracy: 0.0001, "The scale follows the fingers continuously")
            let moved = scroll.convert(underFingers, to: surface)
            XCTAssertEqual(moved.x, anchor.x, accuracy: 0.01)
            XCTAssertEqual(moved.y, anchor.y, accuracy: 0.01, "The point under the fingers stays there")
        }
        XCTAssertEqual(surface.terminal.font.pointSize, 14, "No font change while pinching")
        XCTAssertEqual(grid(surface), before, "No grid change while pinching")
        XCTAssertEqual(surface.fullLayouts, layouts, "No full layout pass (grid, reading page) while pinching")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(spy.sizes.isEmpty, "No resize while pinching: \(spy.sizes)")

        surface.pinchEnded(scale: 1.43)
        XCTAssertEqual(surface.terminal.font.pointSize, 20, accuracy: 0.001, "The new size applies as the fingers lift, not a SwiftUI update later")
        XCTAssertTrue(scroll.transform.isIdentity)
        XCTAssertNotEqual(grid(surface), before, "The grid reflows at once")
        XCTAssertEqual(UserDefaults.standard.double(forKey: TerminalFontSize.key), 20)
        try? await Task.sleep(for: .milliseconds(30))
        let distinct = spy.sizes.map { "\($0.columns)x\($0.rows)" }.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(distinct, [grid(surface)], "One resize, to the new grid")
        // SwiftUI's own update with the saved size, a rounding error away, is a no-op.
        let count = spy.sizes.count, font = surface.terminal.font
        surface.updateFontSize(20 + 1e-9)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(spy.sizes.count, count)
        XCTAssertTrue(surface.terminal.font === font, "The font isn't set again")
    }

    /// Watching: the Mac's grid stays; only the drawing grows.
    func testPinchOnAViewOnlyGridKeepsTheMacsGrid() async {
        let surface = await surface(mode: .view, columns: 80, rows: 24)
        let spy = PinchSizeSpy()
        surface.terminal.terminalDelegate = spy
        let width = surface.terminal.frame.width
        surface.pinchMoved(scale: 1.2, at: CGPoint(x: 50, y: 50))
        surface.pinchEnded(scale: 1.3)
        XCTAssertEqual(grid(surface), "80x24")
        XCTAssertEqual(surface.terminal.font.pointSize, 18, accuracy: 0.001)
        XCTAssertGreaterThan(surface.terminal.frame.width, width)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(spy.sizes.allSatisfy { $0.columns == 80 && $0.rows == 24 }, "\(spy.sizes)")
    }

    func testPinchTargetStaysWithinTheSizesAllowed() {
        let wide = RemoteNativeTerminalView.TerminalSurface.pinchTarget(scale: 10, stored: 14)
        XCTAssertEqual(wide.size, 32)
        XCTAssertEqual(wide.scale, CGFloat(32.0 / 14.0), accuracy: 0.0001)
        let narrow = RemoteNativeTerminalView.TerminalSurface.pinchTarget(scale: 0.1, stored: 14)
        XCTAssertEqual(narrow.size, 11)
        XCTAssertEqual(RemoteNativeTerminalView.TerminalSurface.pinchTarget(scale: 1.03, stored: 14).size, 14)
    }
}

@MainActor private final class PinchSizeSpy: NSObject, @preconcurrency TerminalViewDelegate {
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
