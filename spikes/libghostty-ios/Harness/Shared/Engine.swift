import UIKit

/// Settings shared by every engine so the comparison uses the same grid.
struct EngineConfig {
    var fontSize: CGFloat = 14
    var scrollback = 10_000
    var metal = false
    /// A fixed authoritative grid (watch mode). nil fits the view.
    var fixedGrid: (cols: Int, rows: Int)?
}

/// One on-screen terminal renderer under test.
@MainActor protocol TerminalEngine: AnyObject {
    var name: String { get }
    /// The view to add to the window. The harness sizes it.
    var view: UIView { get }
    /// The scroll view whose content offset moves through scrollback.
    var scrollView: UIScrollView { get }
    var grid: (cols: Int, rows: Int) { get }
    var cellSize: CGSize { get }
    /// Main-thread seconds spent inside the renderer's own draw path so far.
    var drawSeconds: Double { get }
    var drawCount: Int { get }
    func didMoveToWindow()
    func feed(_ bytes: UnsafeRawBufferPointer)
    /// Commits a new font size (the end of a pinch): new metrics and a refit grid.
    func commitFont(size: CGFloat)
    func scrollToBottom()
    /// The visible rows as text, as a reading view would need them.
    func visibleRows() -> [String]
    /// Selects the word at a viewport cell and returns its text.
    func selectWord(row: Int, col: Int) -> String?
}

/// A parser with no view, for raw throughput.
protocol HeadlessParser: AnyObject {
    init(cols: Int, rows: Int, scrollback: Int)
    func feed(_ bytes: UnsafeRawBufferPointer)
    /// A value derived from the final state, so the work can't be skipped
    /// and the engines can be compared for agreement.
    func summary() -> String
}

/// Pixel-snapped cell size, computed the way SwiftTerm 1.19.0 does on iOS
/// (`computeFontDimensions`), so both engines get the same grid.
func cellSize(for font: UIFont, scale: CGFloat) -> CGSize {
    let ct = font as CTFont
    let height = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
    let width = "W".size(withAttributes: [.font: font]).width
    return CGSize(width: max(1, (width * scale).rounded() / scale),
                  height: max(1, ceil(height * scale) / scale))
}
