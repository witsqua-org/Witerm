#if os(macOS)
import AppKit
import SwiftUI
import SwiftTerm
import WitermCore

struct NativeTerminalView: NSViewRepresentable {
    let attachment: LocalTerminalAttachment
    let mode: LocalAttachmentMode
    var fontSize: CGFloat = 14
    var highContrast: Bool = false
    var preferredColorScheme: ColorScheme? = nil
    var palette: TerminalColorScheme = .system
    var announceOutput: Bool = false
    let onFailure: (Error) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(attachment: attachment, mode: mode, onFailure: onFailure, onEnded: onEnded)
    }

    func makeNSView(context: Context) -> TerminalSurface {
        let surface = TerminalSurface(
            mode: mode, columns: attachment.session.columns, rows: attachment.session.rows
        )
        surface.updateAppearance(fontSize: fontSize, highContrast: highContrast, scheme: preferredColorScheme, palette: palette)
        surface.terminal.announceOutput = announceOutput
        surface.terminal.terminalDelegate = context.coordinator
        context.coordinator.start(surface.terminal)
        return surface
    }

    func updateNSView(_ nsView: TerminalSurface, context: Context) {
        nsView.updateAppearance(fontSize: fontSize, highContrast: highContrast, scheme: preferredColorScheme, palette: palette)
        nsView.terminal.announceOutput = announceOutput
    }

    static func dismantleNSView(_ nsView: TerminalSurface, coordinator: Coordinator) {
        nsView.terminal.terminalDelegate = nil
        coordinator.stop()
    }

    @MainActor final class TerminalSurface: NSView {
        let terminal: AccessibleTerminalView
        private let scroll = NSScrollView()
        private let mode: LocalAttachmentMode
        private var columns: Int
        private var rows: Int
        private var contrast = false
        private var installedContrast: Bool?
        private var palette = TerminalColorScheme.system
        private var installedPalette: TerminalColorScheme?
        private var paletteDark: Bool?
        private var initializedReadingViewport = false
        private var pendingReadingAnchor: CGPoint?

        init(mode: LocalAttachmentMode, columns: Int, rows: Int) {
            self.mode = mode
            self.columns = columns
            self.rows = rows
            terminal = AccessibleTerminalView(mode: mode, columns: columns, rows: rows)
            super.init(frame: .zero)
            terminal.configureNativeColors()
            terminal.getTerminal().silentLog = true
            terminal.optionAsMetaKey = false
            terminal.linkReporting = .explicit
            scroll.drawsBackground = true
            scroll.backgroundColor = .textBackgroundColor
            scroll.setAccessibilityLabel(String(localized: "Terminal Viewport", bundle: .main))
            scroll.setAccessibilityHelp(String(localized: "Scroll to browse terminal content.", bundle: .main))
            scroll.setAccessibilityIdentifier("localTerminalViewport")
            scroll.hasHorizontalScroller = mode == .view
            scroll.hasVerticalScroller = mode == .view
            scroll.documentView = terminal
            addSubview(scroll)
            terminal.geometryChanged = { [weak self] session in
                self?.columns = session.columns
                self?.rows = session.rows
                self?.needsLayout = true
            }
        }

        required init?(coder: NSCoder) { nil }

        func updateAppearance(fontSize: CGFloat, highContrast: Bool, scheme: ColorScheme?,
                              palette: TerminalColorScheme = .system) {
            contrast = highContrast
            self.palette = palette
            appearance = scheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
            if fontSize.isFinite, fontSize > 0, terminal.font.pointSize != fontSize {
                if mode == .view, pendingReadingAnchor == nil {
                    pendingReadingAnchor = readingViewportAnchor()
                }
                terminal.frame = .zero
                terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
                needsLayout = true
            }
            updateColors()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        private func updateColors() {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // Enhanced contrast takes precedence over a color scheme.
            let values = contrast ? nil : palette.values(dark: dark)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                terminal.nativeBackgroundColor = contrast ? (dark ? .black : .white)
                    : values.map { NSColor(terminalRGB: $0.background) } ?? .textBackgroundColor
                terminal.nativeForegroundColor = contrast ? (dark ? .white : .black)
                    : values.map { NSColor(terminalRGB: $0.foreground) } ?? .textColor
                terminal.caretColor = dark ? .white : .black
                scroll.backgroundColor = terminal.nativeBackgroundColor
            }
            if installedContrast != contrast || installedPalette != palette || paletteDark == nil
                || ((contrast || palette != .system) && paletteDark != dark) {
                terminal.installColors(TerminalPalette.colors(highContrast: contrast, dark: dark, scheme: palette))
                installedContrast = contrast
                installedPalette = palette
            }
            paletteDark = dark
        }

        override func layout() {
            super.layout()
            let readingAnchor: CGPoint? = mode == .view ? (pendingReadingAnchor ?? readingViewportAnchor() ?? .zero) : nil
            scroll.frame = bounds
            scroll.tile()
            let viewport = scroll.contentView.bounds.size
            if mode == .view {
                if terminal.getTerminal().cols != columns || terminal.getTerminal().rows != rows {
                    terminal.getTerminal().resize(cols: columns, rows: rows)
                    terminal.sizeChanged(source: terminal.getTerminal())
                }
                let grid = terminal.getOptimalFrameSize()
                terminal.frame = grid
                if terminal.getTerminal().cols != columns || terminal.getTerminal().rows != rows {
                    terminal.getTerminal().resize(cols: columns, rows: rows)
                    terminal.sizeChanged(source: terminal.getTerminal())
                }
                if viewport.width > 0, viewport.height > 0, let readingAnchor {
                    let cell = terminal.readingCellSize
                    let maximumX = max(0, terminal.bounds.width - viewport.width)
                    let maximumY = max(0, terminal.bounds.height - viewport.height)
                    // SwiftTerm is unflipped: the visual top is the largest y.
                    // Preserve a cell anchor rather than a font-dependent pixel
                    // offset, and initialize a new readonly viewport top-left.
                    let position = CGPoint(
                        x: min(maximumX, max(0, readingAnchor.x * cell.width)),
                        y: min(maximumY, max(0, terminal.bounds.height - viewport.height - readingAnchor.y * cell.height))
                    )
                    scroll.contentView.scroll(to: position)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    initializedReadingViewport = true
                    pendingReadingAnchor = nil
                }
            } else {
                let cell = terminal.readingCellSize
                let reserved = max(0, terminal.getOptimalFrameSize().width - cell.width * CGFloat(terminal.getTerminal().cols))
                let size = CGSize(width: max(viewport.width, cell.width * 20 + reserved), height: max(viewport.height, cell.height * 5))
                scroll.hasHorizontalScroller = size.width > viewport.width
                scroll.hasVerticalScroller = size.height > viewport.height
                terminal.frame = CGRect(origin: .zero, size: size)
            }
            terminal.refreshReadingDocument()
        }

        private func readingViewportAnchor() -> CGPoint? {
            guard initializedReadingViewport, !terminal.bounds.isEmpty else { return nil }
            let cell = terminal.readingCellSize
            guard cell.width > 0, cell.height > 0, cell.width.isFinite, cell.height.isFinite else { return nil }
            let visible = scroll.contentView.bounds
            return CGPoint(x: max(0, visible.minX / cell.width),
                           y: max(0, (terminal.bounds.height - visible.maxY) / cell.height))
        }
    }

    typealias AccessibleTerminalView = MacTerminalTextView

    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private let attachment: LocalTerminalAttachment
        private let mode: LocalAttachmentMode
        private let onFailure: (Error) -> Void
        private let onEnded: () -> Void
        private var outputTask: Task<Void, Never>?
        private var inputTask: Task<Void, Never>?
        private var resizeTask: Task<Void, Never>?
        private var inputQueue: [Data] = []
        private var inputBytes = 0
        private var pendingSize: (Int, Int)?
        private var stopped = false
        private var serverGrid: (Int, Int)
        private weak var terminalView: TerminalView?

        init(attachment: LocalTerminalAttachment, mode: LocalAttachmentMode, onFailure: @escaping (Error) -> Void, onEnded: @escaping () -> Void) {
            self.attachment = attachment
            self.mode = mode
            self.onFailure = onFailure
            self.onEnded = onEnded
            serverGrid = (attachment.session.columns, attachment.session.rows)
        }

        func start(_ view: TerminalView) {
            terminalView = view
            outputTask = Task { [weak self, weak view, attachment] in
                do {
                    for try await event in attachment.events {
                        try Task.checkCancellation()
                        guard let self, !self.stopped, let view else { return }
                        switch event {
                        case .geometry(let session):
                            self.serverGrid = (session.columns, session.rows)
                            (view as? MacTerminalTextView)?.applyGeometry(session)
                        case .output(let data):
                            view.feed(byteArray: Array(data)[...])
                            (view as? MacTerminalTextView)?.refreshReadingDocument(outputChanged: true)
                        }
                    }
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    self.stopped = true
                    self.onEnded()
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error)
                }
            }
        }

        func stop() {
            stopped = true
            (terminalView as? MacTerminalTextView)?.freezeInput()
            outputTask?.cancel()
            inputTask?.cancel()
            resizeTask?.cancel()
            inputQueue.removeAll()
            inputBytes = 0
            Task { [attachment] in await attachment.disconnect() }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard !stopped, mode == .control, !data.isEmpty else { return }
            let pieces = (data.count + 16 * 1024 - 1) / (16 * 1024)
            guard inputBytes + data.count <= 64 * 1024, inputQueue.count + pieces <= 256 else {
                fail(LocalAgentClientError.backpressure)
                return
            }
            let bytes = Data(data)
            for offset in stride(from: 0, to: bytes.count, by: 16 * 1024) {
                let piece = bytes.subdata(in: offset..<min(offset + 16 * 1024, bytes.count))
                inputQueue.append(piece)
                inputBytes += piece.count
            }
            guard inputTask == nil else { return }
            inputTask = Task { [weak self, attachment] in
                do {
                    while let self, !self.stopped, !self.inputQueue.isEmpty {
                        let piece = self.inputQueue.removeFirst()
                        try await attachment.send(piece)
                        try Task.checkCancellation()
                        self.inputBytes -= piece.count
                    }
                    self?.inputTask = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error)
                }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard !stopped, mode == .control else { return }
            if newCols == serverGrid.0 && newRows == serverGrid.1 { return }
            pendingSize = (min(500, max(20, newCols)), min(200, max(5, newRows)))
            guard resizeTask == nil else { return }
            resizeTask = Task { [weak self, attachment] in
                do {
                    while let self, !self.stopped, self.pendingSize != nil {
                        try await Task.sleep(for: .milliseconds(50))
                        guard let size = self.pendingSize else { break }
                        self.pendingSize = nil
                        try await attachment.resize(columns: size.0, rows: size.1)
                    }
                    self?.resizeTask = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error)
                }
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) { (source as? MacTerminalTextView)?.refreshReadingDocument() }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { (source as? MacTerminalTextView)?.refreshReadingDocument() }
        func bell(source: TerminalView) { TerminalBell.ring() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard !link.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return }
            NSWorkspace.shared.open(url)
        }

        private func fail(_ error: Error) {
            guard !stopped else { return }
            stop()
            onFailure(error)
        }
    }
}
#endif
