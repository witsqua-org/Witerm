#if ENGINE_SWIFTTERM
import SwiftTerm
import UIKit

let engineBuildName = "swiftterm-1.19.0"

/// Times SwiftTerm's Core Graphics drawing: UIView routes layer drawing
/// through draw(_:in:), which calls TerminalView.draw(_:).
final class TimedTerminalView: TerminalView {
    var drawSeconds = 0.0
    var drawCount = 0

    override func draw(_ layer: CALayer, in ctx: CGContext) {
        let t = now()
        super.draw(layer, in: ctx)
        drawSeconds += now() - t
        drawCount += 1
    }
}

@MainActor final class SwiftTermEngine: TerminalEngine, FontReporting, TerminalViewDelegate {
    let tv: TimedTerminalView
    let metal: Bool
    var name: String { metal ? "SwiftTerm Metal" : "SwiftTerm CoreGraphics" }
    var view: UIView { tv }
    var scrollView: UIScrollView { tv }
    var grid: (cols: Int, rows: Int) { (tv.getTerminal().cols, tv.getTerminal().rows) }
    var cellSize: CGSize {
        let f = tv.getOptimalFrameSize()
        return CGSize(width: f.width / CGFloat(grid.cols), height: f.height / CGFloat(grid.rows))
    }
    var drawSeconds: Double { tv.drawSeconds }
    var drawCount: Int { tv.drawCount }
    var fontSize: CGFloat { tv.font.pointSize }

    init(config: EngineConfig) {
        metal = config.metal
        tv = TimedTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: config.fontSize, weight: .regular),
                               options: TerminalOptions(cols: 45, rows: 40, scrollback: config.scrollback))
        tv.getTerminal().silentLog = true
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        tv.terminalDelegate = self
    }

    func didMoveToWindow() {
        guard metal else { return }
        do { try tv.setUseMetal(true) } catch { print("HARNESS metal unavailable: \(error)") }
        print("HARNESS SwiftTerm Metal active: \(tv.isUsingMetalRenderer)")
    }

    func feed(_ bytes: UnsafeRawBufferPointer) {
        tv.feed(byteArray: ArraySlice(bytes.bindMemory(to: UInt8.self)))
    }

    /// As Witerm's `updateFontSize` does: zero the frame so the font setter
    /// can't resize (that path soft-resets), lay out once at zero size, then
    /// lay out at the real frame so SwiftTerm refits (and reflows) its grid.
    func commitFont(size: CGFloat) {
        let frame = tv.frame
        tv.frame = .zero
        tv.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        tv.layoutIfNeeded()
        tv.frame = frame
        tv.layoutIfNeeded()
    }

    func scrollToBottom() {
        tv.layoutIfNeeded()
        let y = max(0, tv.contentSize.height - tv.bounds.height)
        tv.contentOffset = CGPoint(x: 0, y: y)
    }

    func visibleRows() -> [String] {
        let t = tv.getTerminal()
        return (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
    }

    /// SwiftTerm 1.19.0 exposes selection through its own gestures and
    /// getSelection()/selectAll(); there is no public select-word-at-cell.
    func selectWord(row: Int, col: Int) -> String? { nil }

    // TerminalViewDelegate
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class SwiftTermHeadless: HeadlessParser, TerminalDelegate {
    private var terminal: Terminal!

    init(cols: Int, rows: Int, scrollback: Int) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        terminal.silentLog = true
    }

    func feed(_ bytes: UnsafeRawBufferPointer) {
        terminal.feed(buffer: ArraySlice(bytes.bindMemory(to: UInt8.self)))
    }

    func summary() -> String {
        let c = terminal.getCursorLocation()
        return "cursor \(c.x),\(c.y) total-rows \(terminal.buffer.yDisp + terminal.rows)"
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@MainActor func makeEngine(_ config: EngineConfig) -> TerminalEngine? {
    // Witerm keeps a watched grid at its own cell size and pans it; this
    // harness only demonstrates scaling a fixed grid with the GPU renderer.
    config.fixedGrid == nil ? SwiftTermEngine(config: config) : nil
}

func makeHeadless(cols: Int, rows: Int, scrollback: Int) -> HeadlessParser? {
    SwiftTermHeadless(cols: cols, rows: rows, scrollback: scrollback)
}
#endif
