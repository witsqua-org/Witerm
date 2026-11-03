#if ENGINE_GHOSTTY
import CoreText
import GhosttyVt
import Metal
import QuartzCore
import UIKit

// Layouts shared with Shaders.metal.
struct Uniforms {
    var viewport: SIMD2<Float>
    var cell: SIMD2<Float>
    var origin: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var glyphScale: Float
    var pad: Float = 0
}

struct BgInstance {
    var rect: SIMD4<Float>
    var color: UInt32
    var p0: UInt32 = 0, p1: UInt32 = 0, p2: UInt32 = 0
}

struct GlyphInstance {
    var cell: SIMD2<Float>
    var pad = SIMD2<Float>(0, 0)
    var uv: SIMD4<Float>
    var color: UInt32
    var flags: UInt32
    var p0: UInt32 = 0, p1: UInt32 = 0
}

@inline(__always) func pack(_ c: GhosttyColorRgb, alpha: UInt32 = 255) -> UInt32 {
    UInt32(c.r) << 24 | UInt32(c.g) << 16 | UInt32(c.b) << 8 | alpha
}

/// Fonts and pixel metrics for one point size.
struct FontMetrics {
    let size: CGFloat
    let scale: CGFloat
    let cell: CGSize        // points, pixel-snapped
    let fonts: [CTFont]     // regular, bold, italic, bold italic
    let descent: CGFloat

    init(size: CGFloat, scale: CGFloat) {
        self.size = size
        self.scale = scale
        let regular = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        func italic(_ f: UIFont) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(f as CTFont, size, nil, .traitItalic, .traitItalic) ?? f as CTFont
        }
        fonts = [regular as CTFont, bold as CTFont, italic(regular), italic(bold)]
        cell = cellSize(for: regular, scale: scale)
        descent = CTFontGetDescent(regular as CTFont)
    }
}

/// Glyphs rasterized by CoreText (which also does CJK and emoji fallback)
/// into one BGRA texture, packed in rows of cell-height slots.
final class GlyphAtlas {
    struct Entry { var uv: SIMD4<Float>; var color: Bool }
    let texture: MTLTexture
    let size = 2048
    private var x = 0, y = 0
    private var ascii = [Entry?](repeating: nil, count: 128 * 4)
    private var other: [String: Entry] = [:]
    private(set) var generation = 0
    var metrics: FontMetrics

    init(device: MTLDevice, metrics: FontMetrics) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        texture = device.makeTexture(descriptor: d)!
        self.metrics = metrics
    }

    func reset(metrics: FontMetrics) {
        self.metrics = metrics
        x = 0; y = 0
        ascii = [Entry?](repeating: nil, count: 128 * 4)
        other.removeAll()
        generation += 1
    }

    @inline(__always) func lookupASCII(_ cp: UInt32, style: Int) -> Entry? {
        let i = Int(cp) * 4 + style
        if let e = ascii[i] { return e }
        let e = rasterize(String(UnicodeScalar(UInt8(cp))), style: style, cells: 1)
        ascii[i] = e
        return e
    }

    func lookup(_ text: String, style: Int, cells: Int) -> Entry? {
        let key = "\(style)\(cells)\(text)"
        if let e = other[key] { return e }
        let e = rasterize(text, style: style, cells: cells)
        other[key] = e
        return e
    }

    private func rasterize(_ text: String, style: Int, cells: Int) -> Entry? {
        let scale = metrics.scale
        let w = Int(ceil(metrics.cell.width * CGFloat(cells) * scale))
        let h = Int(ceil(metrics.cell.height * scale))
        if x + w > size { x = 0; y += h }
        if y + h > size {
            // Full: start over. The renderer redraws everything next frame.
            reset(metrics: metrics)
        }
        let attr = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): metrics.fonts[style],
            .init(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var isColor = false
        if let runs = CTLineGetGlyphRuns(line) as? [CTRun] {
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                if let f = attrs[kCTFontAttributeName as String] {
                    let font = f as! CTFont
                    if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { isColor = true }
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            let slot = metrics.cell.width * CGFloat(cells)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if width > slot + 0.5 {
                // Wider than its cells (emoji, some fallback fonts): shrink to fit.
                let k = slot / width
                ctx.translateBy(x: 0, y: metrics.descent * (1 - k))
                ctx.scaleBy(x: k, y: k)
                ctx.textPosition = CGPoint(x: 0, y: metrics.descent)
            } else {
                ctx.textPosition = CGPoint(x: cells > 1 ? (slot - width) / 2 : 0, y: metrics.descent)
            }
            CTLineDraw(line, ctx)
        }
        texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        let e = Entry(uv: SIMD4(Float(x), Float(y), Float(w), Float(h)), color: isColor)
        x += w
        return e
    }
}

/// Builds cell instances from a libghostty-vt render state and draws them.
@MainActor final class GhosttyMetalRenderer {
    let device: MTLDevice
    let layer: CAMetalLayer
    private let queue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let inflight = DispatchSemaphore(value: 3)
    private var buffers: [(bg: MTLBuffer, glyph: MTLBuffer)] = []
    private var bufferIndex = 0
    let atlas: GlyphAtlas

    private var state: GhosttyRenderState?
    private var rows: GhosttyRenderStateRowIterator?
    private var cells: GhosttyRenderStateRowCells?
    private var bg: [BgInstance] = []
    private var glyphs: [GlyphInstance] = []
    private var codepoints = [UInt32](repeating: 0, count: 32)

    // Preallocated out-values for the per-cell get_multi call.
    private let keys: UnsafeMutablePointer<GhosttyRenderStateRowCellsData>
    private let values: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private let rawCell = UnsafeMutablePointer<GhosttyCell>.allocate(capacity: 1)
    private let graphemes = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private let styled = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    var selectionColor: UInt32 = 0x3A6EA5FF
    var cursorColor: UInt32 = 0xC8C8C8B0

    init(metrics: FontMetrics) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        self.device = device
        self.queue = queue
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        let library = try device.makeDefaultLibrary(bundle: .main)
        func pipeline(_ v: String, _ f: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        bgPipeline = try pipeline("bg_vertex", "bg_fragment")
        glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
        atlas = GlyphAtlas(device: device, metrics: metrics)
        for _ in 0..<3 {
            buffers.append((device.makeBuffer(length: 64 * 1024 * MemoryLayout<BgInstance>.stride, options: .storageModeShared)!,
                            device.makeBuffer(length: 64 * 1024 * MemoryLayout<GlyphInstance>.stride, options: .storageModeShared)!))
        }
        keys = .allocate(capacity: 3)
        keys[0] = GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW
        keys[1] = GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN
        keys[2] = GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING
        values = .allocate(capacity: 3)
        values[0] = UnsafeMutableRawPointer(rawCell)
        values[1] = UnsafeMutableRawPointer(graphemes)
        values[2] = UnsafeMutableRawPointer(styled)
        ghostty_render_state_new(nil, &state)
        ghostty_render_state_row_iterator_new(nil, &rows)
        ghostty_render_state_row_cells_new(nil, &cells)
        // One row below the viewport, for the partly visible row while scrolling.
        var overscan = GhosttyRenderStateOverscan(above: 0, below: 1)
        ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_OVERSCAN, &overscan)
    }

    isolated deinit {
        ghostty_render_state_row_cells_free(cells)
        ghostty_render_state_row_iterator_free(rows)
        ghostty_render_state_free(state)
    }

    /// Style index into the atlas: bit 0 bold, bit 1 italic.
    @inline(__always) private func styleIndex(_ s: GhosttyStyle) -> Int { (s.bold ? 1 : 0) | (s.italic ? 2 : 0) }

    /// Updates from the terminal and draws one frame. `shift` is how far
    /// the grid moves up, in points (0 ..< one row), for smooth scrolling.
    /// `cell` is the on-screen cell size in points (smaller than the font's
    /// for a scaled fixed grid).
    func draw(terminal: GhosttyTerminal, shift: CGFloat, cell: CGSize) {
        guard let state else { return }
        ghostty_render_state_update(state, terminal)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        var captured = GhosttyRenderStateOverscan()
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_OVERSCAN, &captured)
        let shift = captured.below == 0 ? 0 : shift
        let defaultFg = pack(colors.foreground)
        let defaultBg = pack(colors.background)

        bg.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        let generation = atlas.generation
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows)
        while ghostty_render_state_row_iterator_next(rows) {
            var vy: Int32 = 0
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &vy)
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
            var sel = GhosttyRenderStateRowSelection()
            sel.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let hasSel = ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS
            let fy = Float(vy)
            var x: UInt16 = 0
            while ghostty_render_state_row_cells_next(cells) {
                defer { x += 1 }
                ghostty_render_state_row_cells_get_multi(cells, 3, keys, values, nil)
                let glen = graphemes.pointee
                var fg = defaultFg
                var back: UInt32? = nil
                var style = GhosttyStyle()
                var styleIdx = 0
                var underline = false
                if styled.pointee {
                    style.size = MemoryLayout<GhosttyStyle>.size
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                    var c = GhosttyColorRgb()
                    if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &c) == GHOSTTY_SUCCESS { fg = pack(c) }
                    if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS { back = pack(c) }
                    if style.inverse { let f = fg; fg = back ?? defaultBg; back = f }
                    if style.faint { fg = (fg & 0xFFFF_FF00) | 0x80 }
                    styleIdx = styleIndex(style)
                    underline = style.underline != 0
                } else if glen == 0 {
                    var c = GhosttyColorRgb()
                    if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS { back = pack(c) }
                }
                var span: Float = 1
                if glen > 0, codepointsNeedWidth(rawCell.pointee) {
                    var wide = GhosttyCellWide(0)
                    ghostty_cell_get(rawCell.pointee, GHOSTTY_CELL_DATA_WIDE, &wide)
                    if wide == GHOSTTY_CELL_WIDE_WIDE { span = 2 }
                }
                if hasSel, x >= sel.start_x, x <= sel.end_x { back = selectionColor }
                let fx = Float(x)
                if let back { bg.append(BgInstance(rect: SIMD4(fx, fy, span, 1), color: back)) }
                if underline { bg.append(BgInstance(rect: SIMD4(fx, fy + 0.9, span, 0.06), color: fg)) }
                guard glen > 0, !(styled.pointee && style.invisible) else { continue }
                var entry: GlyphAtlas.Entry?
                if glen == 1, span == 1 {
                    var cp: UInt32 = 0
                    ghostty_cell_get(rawCell.pointee, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
                    if cp == 32 { continue }
                    entry = cp < 128 ? atlas.lookupASCII(cp, style: styleIdx) : atlas.lookup(String(UnicodeScalar(cp).map(Character.init) ?? " "), style: styleIdx, cells: 1)
                } else {
                    let n = Int(min(glen, 32))
                    codepoints.withUnsafeMutableBufferPointer { buf in
                        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf.baseAddress)
                    }
                    var s = String.UnicodeScalarView()
                    for i in 0..<n { if let u = UnicodeScalar(codepoints[i]) { s.append(u) } }
                    entry = atlas.lookup(String(s), style: styleIdx, cells: Int(span))
                }
                if let entry {
                    glyphs.append(GlyphInstance(cell: SIMD2(fx, fy), uv: entry.uv, color: fg, flags: entry.color ? 1 : 0))
                }
            }
        }
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        if cursor.visible, cursor.viewport_has_value {
            bg.append(BgInstance(rect: SIMD4(Float(cursor.viewport_x), Float(cursor.viewport_y), 1, 1), color: cursorColor))
        }
        ghostty_render_state_clean(state)
        if atlas.generation != generation {
            // The atlas was reset mid-frame; entries from before are stale.
            glyphs.removeAll(keepingCapacity: true)
        }
        encode(background: defaultBg, shift: shift, cell: cell)
    }

    /// Only non-ASCII cells can be wide; skip the extra call otherwise.
    @inline(__always) private func codepointsNeedWidth(_ raw: GhosttyCell) -> Bool {
        var cp: UInt32 = 0
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
        return cp >= 0x1100
    }

    private func encode(background: UInt32, shift: CGFloat, cell: CGSize) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return }
        inflight.wait()
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        bufferIndex = (bufferIndex + 1) % buffers.count
        let (bgBuffer, glyphBuffer) = buffers[bufferIndex]
        let nb = min(bg.count, 64 * 1024), ng = min(glyphs.count, 64 * 1024)
        bg.withUnsafeBytes { bgBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: nb * MemoryLayout<BgInstance>.stride) }
        glyphs.withUnsafeBytes { glyphBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: ng * MemoryLayout<GlyphInstance>.stride) }
        let scale = atlas.metrics.scale
        var u = Uniforms(viewport: SIMD2(Float(layer.drawableSize.width), Float(layer.drawableSize.height)),
                         cell: SIMD2(Float(cell.width * scale), Float(cell.height * scale)),
                         origin: SIMD2(0, Float(-shift * scale)),
                         atlasSize: SIMD2(Float(atlas.size), Float(atlas.size)),
                         glyphScale: Float(cell.height / atlas.metrics.cell.height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(background >> 24 & 255) / 255,
                                                            green: Double(background >> 16 & 255) / 255,
                                                            blue: Double(background >> 8 & 255) / 255, alpha: 1)
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        if nb > 0 {
            enc.setRenderPipelineState(bgPipeline)
            enc.setVertexBuffer(bgBuffer, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: nb)
        }
        if ng > 0 {
            enc.setRenderPipelineState(glyphPipeline)
            enc.setVertexBuffer(glyphBuffer, offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: ng)
        }
        enc.endEncoding()
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }

    /// The viewport rows as text, from the last update (for a reading view).
    func rowsText(terminal: GhosttyTerminal) -> [String] {
        guard let state else { return [] }
        ghostty_render_state_update(state, terminal)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows)
        var out: [String] = []
        while ghostty_render_state_row_iterator_next(rows) {
            var vy: Int32 = 0
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &vy)
            guard vy >= 0 else { continue }
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
            var line = String.UnicodeScalarView()
            while ghostty_render_state_row_cells_next(cells) {
                var glen: UInt32 = 0
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen)
                var raw: GhosttyCell = 0
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                var wide = GhosttyCellWide(0)
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                if glen == 0 { line.append(" "); continue }
                codepoints.withUnsafeMutableBufferPointer { buf in
                    _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf.baseAddress)
                }
                for i in 0..<Int(min(glen, 32)) { if let u = UnicodeScalar(codepoints[i]) { line.append(u) } }
            }
            var s = String(line)
            while s.last == " " { s.removeLast() }
            out.append(s)
        }
        return out
    }
}
#endif
