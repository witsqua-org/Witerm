#if ENGINE_GHOSTTY
import GhosttyVt
import UIKit

let engineBuildName = "libghostty-vt-1.4.0"

/// Owns one libghostty-vt terminal.
final class GhosttyCore {
    let term: GhosttyTerminal

    init(cols: Int, rows: Int, scrollback: Int) {
        var t: GhosttyTerminal?
        let r = ghostty_terminal_new(nil, &t, UInt16(cols), UInt16(rows))
        precondition(r == GHOSTTY_SUCCESS && t != nil, "ghostty_terminal_new failed")
        term = t!
        // libghostty-vt's default byte limit is 10,000 bytes (about one
        // page, so almost no history). Clear it and limit by lines only, as
        // SwiftTerm does.
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        var lines = scrollback
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // Grapheme clustering (mode 2027) is off by default in libghostty-vt;
        // without it ZWJ emoji, skin tones and flags split into cells.
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes)
    }

    deinit { ghostty_terminal_free(term) }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        ghostty_terminal_vt_write(term, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    func value<T>(_ key: GhosttyTerminalData, _ initial: T) -> T {
        var v = initial
        ghostty_terminal_get(term, key, &v)
        return v
    }

    var scrollbar: GhosttyTerminalScrollbar { value(GHOSTTY_TERMINAL_DATA_SCROLLBAR, GhosttyTerminalScrollbar()) }

    func setColors(fg: GhosttyColorRgb, bg: GhosttyColorRgb) {
        var f = fg, b = bg
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &f)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &b)
    }
}

/// A terminal view: a CAMetalLayer that draws the viewport, under a
/// transparent UIScrollView that supplies touch scrolling and its physics.
/// The scroll view's content is the whole scrollback; its offset picks the
/// viewport row and the sub-row shift.
@MainActor final class GhosttyTerminalView: UIView, UIScrollViewDelegate {
    let core: GhosttyCore
    let renderer: GhosttyMetalRenderer
    let scroll = UIScrollView()
    private(set) var metrics: FontMetrics
    let fixedGrid: (cols: Int, rows: Int)?
    private(set) var grid: (cols: Int, rows: Int)
    private var viewportRow = -1
    private var shift: CGFloat = 0
    private var followBottom = true
    private var ignoreScroll = false
    private var needsSync = false
    private var link: CADisplayLink?
    var drawSeconds = 0.0
    var drawCount = 0

    init(config: EngineConfig) throws {
        let scale = UIScreen.main.scale
        metrics = FontMetrics(size: config.fontSize, scale: scale)
        fixedGrid = config.fixedGrid
        grid = config.fixedGrid ?? (45, 40)
        core = GhosttyCore(cols: grid.cols, rows: grid.rows, scrollback: config.scrollback)
        core.setColors(fg: GhosttyColorRgb(r: 230, g: 230, b: 230), bg: GhosttyColorRgb(r: 0, g: 0, b: 0))
        renderer = try GhosttyMetalRenderer(metrics: metrics)
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(renderer.layer)
        renderer.layer.contentsScale = scale
        scroll.delegate = self
        scroll.backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    /// On-screen cell size: the font's, or smaller to fit a fixed grid.
    var cell: CGSize {
        guard let fixedGrid, bounds.width > 0 else { return metrics.cell }
        let k = min(1, bounds.width / (metrics.cell.width * CGFloat(fixedGrid.cols)))
        return CGSize(width: metrics.cell.width * k, height: metrics.cell.height * k)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = bounds
        renderer.layer.drawableSize = CGSize(width: bounds.width * metrics.scale, height: bounds.height * metrics.scale)
        CATransaction.commit()
        ignoreScroll = true
        scroll.frame = bounds
        ignoreScroll = false
        refit()
    }

    /// Fits the grid to the view (unless fixed) through libghostty's resize,
    /// which reflows the primary screen and its scrollback.
    func refit() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if fixedGrid == nil {
            let c = metrics.cell
            let cols = min(500, max(20, Int(bounds.width / c.width * (1 + 1e-9))))
            let rows = min(200, max(5, Int(bounds.height / c.height * (1 + 1e-9))))
            if cols != grid.cols || rows != grid.rows {
                grid = (cols, rows)
                ghostty_terminal_resize(core.term, UInt16(cols), UInt16(rows),
                                        UInt32(c.width * metrics.scale), UInt32(c.height * metrics.scale))
            }
        }
        sync()
        render()
    }

    func setFont(size: CGFloat) {
        metrics = FontMetrics(size: size, scale: metrics.scale)
        renderer.atlas.reset(metrics: metrics)
        viewportRow = -1
        refit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    func feed(_ bytes: UnsafeRawBufferPointer) {
        core.write(bytes)
        needsSync = true
    }

    /// Output is drawn at most once per display frame.
    @objc private func tick() {
        guard needsSync else { return }
        needsSync = false
        sync()
        render()
    }

    /// Matches the scroll view's content to libghostty's scrollback.
    private func sync() {
        let sb = core.scrollbar
        let c = cell
        let rows = fixedGrid?.rows ?? grid.rows
        // Leftover points below the last whole row, so the bottom offset
        // lands exactly on a row.
        let extra = max(0, bounds.height - CGFloat(rows) * c.height)
        let height = CGFloat(sb.total) * c.height + extra
        ignoreScroll = true
        if scroll.contentSize.height != height || scroll.contentSize.width != bounds.width {
            scroll.contentSize = CGSize(width: bounds.width, height: height)
        }
        if followBottom {
            var bottom = GhosttyTerminalScrollViewport()
            bottom.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
            ghostty_terminal_scroll_viewport(core.term, bottom)
            scroll.contentOffset.y = max(0, height - bounds.height)
            shift = 0
        } else {
            scroll.contentOffset.y = CGFloat(core.scrollbar.offset) * c.height + shift
        }
        viewportRow = Int(core.scrollbar.offset)
        ignoreScroll = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !ignoreScroll else { return }
        let c = cell
        let y = max(0, scrollView.contentOffset.y)
        let row = Int(y / c.height)
        shift = y - CGFloat(row) * c.height
        if row != viewportRow {
            var v = GhosttyTerminalScrollViewport()
            v.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
            v.value.row = row
            ghostty_terminal_scroll_viewport(core.term, v)
            viewportRow = row
        }
        let sb = core.scrollbar
        followBottom = sb.offset + sb.len >= sb.total
        render()
    }

    func render() {
        let t = now()
        renderer.draw(terminal: core.term, shift: shift, cell: cell)
        drawSeconds += now() - t
        drawCount += 1
    }
}

@MainActor final class GhosttyEngine: TerminalEngine, FontReporting {
    let tv: GhosttyTerminalView
    var name: String { "libghostty-vt + spike Metal renderer" }
    var view: UIView { tv }
    var scrollView: UIScrollView { tv.scroll }
    var grid: (cols: Int, rows: Int) { tv.grid }
    var cellSize: CGSize { tv.cell }
    var drawSeconds: Double { tv.drawSeconds }
    var drawCount: Int { tv.drawCount }
    var fontSize: CGFloat { tv.metrics.size }

    init(config: EngineConfig) throws { tv = try GhosttyTerminalView(config: config) }

    func didMoveToWindow() {}
    func feed(_ bytes: UnsafeRawBufferPointer) { tv.feed(bytes) }
    func commitFont(size: CGFloat) { tv.setFont(size: size) }

    func scrollToBottom() {
        tv.layoutIfNeeded()
        let s = tv.scroll
        s.contentOffset.y = max(0, s.contentSize.height - s.bounds.height)
    }

    func visibleRows() -> [String] { tv.renderer.rowsText(terminal: tv.core.term) }

    func selectWord(row: Int, col: Int) -> String? {
        let term = tv.core.term
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(col), y: UInt32(row))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(term, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        var options = GhosttyTerminalSelectWordOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        options.ref = ref
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_word(term, &options, &selection) == GHOSTTY_SUCCESS else { return nil }
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        var format = GhosttyTerminalSelectionFormatOptions()
        format.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        format.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        format.trim = true
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_terminal_selection_format_alloc(term, nil, format, &ptr, &len) == GHOSTTY_SUCCESS else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        tv.render()
        guard let ptr else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}

final class GhosttyHeadless: HeadlessParser {
    private let core: GhosttyCore

    init(cols: Int, rows: Int, scrollback: Int) {
        core = GhosttyCore(cols: cols, rows: rows, scrollback: scrollback)
    }

    func feed(_ bytes: UnsafeRawBufferPointer) { core.write(bytes) }

    func summary() -> String {
        let x: UInt16 = core.value(GHOSTTY_TERMINAL_DATA_CURSOR_X, 0)
        let y: UInt16 = core.value(GHOSTTY_TERMINAL_DATA_CURSOR_Y, 0)
        let total: Int = core.value(GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, 0)
        return "cursor \(x),\(y) total-rows \(total)"
    }
}

@MainActor func makeEngine(_ config: EngineConfig) -> TerminalEngine? {
    do { return try GhosttyEngine(config: config) } catch {
        print("HARNESS ghostty engine failed: \(error)")
        return nil
    }
}

func makeHeadless(cols: Int, rows: Int, scrollback: Int) -> HeadlessParser? {
    GhosttyHeadless(cols: cols, rows: rows, scrollback: scrollback)
}
#endif
