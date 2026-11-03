#if os(iOS)
import SwiftUI
import UIKit
import SwiftTerm
import UniformTypeIdentifiers
import WitermCore

extension Notification.Name {
    /// A terminal's input view gained or lost the keyboard focus; the object
    /// is the view and `focused` in the user info says which.
    static let witermTerminalFocusChanged = Notification.Name("witermTerminalFocusChanged")
}

struct RemoteNativeTerminalView: UIViewRepresentable {
    let attachment: RemoteTerminalAttachment
    let mode: LocalAttachmentMode
    let keyboardRequest: Int
    var isInteractive: Bool = true
    var fontSize: CGFloat = 14
    var highContrast: Bool = false
    var preferredColorScheme: ColorScheme? = nil
    var palette: TerminalColorScheme = .system
    var announceOutput: Bool = false
    var finder: TerminalFinder? = nil
    var inputDestination: String? = nil
    let onFailure: (Error) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(attachment: attachment, mode: mode, keyboardRequest: keyboardRequest,
                    isInteractive: isInteractive, onFailure: onFailure, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> TerminalSurface {
        TerminalView.textInputDebugEnabled = false
        let surface = TerminalSurface(mode: mode, session: attachment.session,
                                      fontSize: fontSize, isInteractive: isInteractive)
        surface.updateAppearance(highContrast: highContrast, scheme: preferredColorScheme, palette: palette)
        surface.announceOutput = announceOutput
        surface.terminal.inputDestination = inputDestination ?? attachment.session.name
        surface.terminal.focusesWhenShown = isInteractive && mode == .control
        surface.terminal.terminalDelegate = context.coordinator
        context.coordinator.start(surface.terminal)
        finder?.terminal = surface.terminal
        return surface
    }

    func updateUIView(_ view: TerminalSurface, context: Context) {
        view.setInteractive(isInteractive)
        context.coordinator.setInteractive(isInteractive)
        view.updateFontSize(fontSize)
        view.updateAppearance(highContrast: highContrast, scheme: preferredColorScheme, palette: palette)
        view.announceOutput = announceOutput
        context.coordinator.requestKeyboardToggle(keyboardRequest, terminal: view.terminal)
    }

    static func dismantleUIView(_ view: TerminalSurface, coordinator: Coordinator) {
        view.terminal.terminalDelegate = nil
        coordinator.stop()
    }

    @MainActor final class TerminalSurface: UIView, UIScrollViewDelegate {
        let terminal: TerminalInputView
        let readingView = TerminalReadingTextView()
        private let scroll = UIScrollView()
        private let mode: LocalAttachmentMode
        private var session: LocalSessionInfo
        private var frozenGrid: (columns: Int, rows: Int)?
        /// While another device that types sets the session's grid, this
        /// controlling view shows that grid (scrollable, like a viewer) until
        /// it types and its own size applies.
        private var followedGrid: (columns: Int, rows: Int)?
        private var reportedFit: (columns: Int, rows: Int)?
        private var highContrast = false
        private var paletteDark: Bool?
        private var palette = TerminalColorScheme.system
        private var installedPalette: TerminalColorScheme?
        var announceOutput = false
        /// Text never touches the screen edge: this much on each side, or
        /// the safe area in landscape when that's wider.
        static let edgeInset: CGFloat = 6
        /// Back to the newest output, shown while scrolled back.
        private let latestButton = UIButton(type: .system)
        /// The size a pinch would set, shown while pinching.
        private let sizeReadout = UILabel()
        private var pinchStartSize: CGFloat?

        init(mode: LocalAttachmentMode, session: LocalSessionInfo, fontSize: CGFloat, isInteractive: Bool) {
            self.mode = mode
            self.session = session
            terminal = TerminalInputView(mode: mode, session: session,
                                         fontSize: fontSize, isInteractive: isInteractive)
            if !isInteractive { frozenGrid = (session.columns, session.rows) }
            super.init(frame: .zero)
            backgroundColor = .systemBackground
            updateColors()
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (surface: TerminalSurface, _: UITraitCollection) in
                surface.updateColors()
            }
            terminal.getTerminal().silentLog = true
            terminal.notifyUpdateChanges = true
            terminal.linkReporting = .explicit
            terminal.keyboardDismissMode = .interactive
            // The surface already sits within the safe area and above the
            // keyboard. Automatic insets would shift the rows by a fraction
            // of a line, clipping the prompt under the key row.
            terminal.contentInsetAdjustmentBehavior = .never
            terminal.isAccessibilityElement = false
            terminal.accessibilityElementsHidden = true
            readingView.accessibilityLabel = mode == .view ? String(localized: "Terminal Text, Watching", bundle: .main) : String(localized: "Terminal Text", bundle: .main)
            scroll.addSubview(terminal)
            scroll.alwaysBounceHorizontal = false
            scroll.alwaysBounceVertical = false
            // A drag pans one way at a time, so panning a wide grid never
            // also scrolls the output.
            scroll.isDirectionalLockEnabled = true
            scroll.contentInsetAdjustmentBehavior = .never
            addSubview(scroll)
            addSubview(readingView)
            scroll.delegate = self
            accessibilityElements = [readingView]
            terminal.geometryChanged = { [weak self] session in self?.applyGeometry(session) }
            terminal.readingChanged = { [weak self] in self?.refreshReadingDocument(outputChanged: $0) }
            readingView.rectFromGrid = { [weak self] in self?.readingRectFromGrid($0) ?? .zero }
            readingView.pointToGrid = { [weak self] point in self?.readingPointToGrid(point) ?? CGPoint(x: -1, y: -1) }
            readingView.page = { [weak self] in self?.pageReading(forward: $0) ?? false }
            readingView.panHorizontal = { [weak self] in self?.panReading(forward: $0) ?? false }
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            addGestureRecognizer(pinch)
            installLatestButton()
            installSizeReadout()
            terminal.scrollStateChanged = { [weak self] output in self?.updateLatestButton(output: output) }
        }

        private func installLatestButton() {
            var configuration = UIButton.Configuration.gray()
            configuration.image = UIImage(systemName: "arrow.down.to.line")
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .label
            latestButton.configuration = configuration
            latestButton.accessibilityLabel = String(localized: "Jump to Latest", bundle: .main)
            latestButton.accessibilityIdentifier = "terminalJumpToLatest"
            latestButton.showsLargeContentViewer = true
            latestButton.largeContentTitle = latestButton.accessibilityLabel
            latestButton.isHidden = true
            latestButton.addAction(UIAction { [weak self] _ in self?.jumpToLatest() }, for: .touchUpInside)
            addSubview(latestButton)
            addInteraction(UILargeContentViewerInteraction())
        }

        private func installSizeReadout() {
            sizeReadout.font = .preferredFont(forTextStyle: .headline)
            sizeReadout.adjustsFontForContentSizeCategory = true
            sizeReadout.textAlignment = .center
            sizeReadout.textColor = .label
            sizeReadout.backgroundColor = .secondarySystemBackground
            sizeReadout.layer.cornerRadius = 12
            sizeReadout.layer.cornerCurve = .continuous
            sizeReadout.clipsToBounds = true
            sizeReadout.isHidden = true
            sizeReadout.isAccessibilityElement = false
            addSubview(sizeReadout)
        }

        /// Whether the view shows the newest output.
        private var following: Bool { !terminal.canScroll || terminal.scrollPosition >= 0.999 }

        /// Shown while scrolled back; new output meanwhile is said in its value.
        private func updateLatestButton(output: Bool) {
            let hidden = following
            if hidden { latestButton.accessibilityValue = nil }
            else if output { latestButton.accessibilityValue = String(localized: "New output", bundle: .main) }
            guard latestButton.isHidden != hidden else { return }
            latestButton.isHidden = hidden
            accessibilityElements = hidden ? [readingView] : [readingView, latestButton]
            setNeedsLayout()
        }

        private func jumpToLatest() {
            let bottom = max(0, terminal.contentSize.height - terminal.bounds.height)
            terminal.setContentOffset(CGPoint(x: terminal.contentOffset.x, y: bottom),
                                      animated: !UIAccessibility.isReduceMotionEnabled)
            UIAccessibility.post(notification: .layoutChanged, argument: readingView)
        }

        /// Pinching scales the text live and shows the size it will set; the
        /// saved size changes once the fingers lift, so a controlled session
        /// is resized once rather than at every step.
        @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
            let defaults = UserDefaults.standard
            let current = defaults.object(forKey: TerminalFontSize.key) as? Double ?? TerminalFontSize.standard
            let next = TerminalFontSize.clamped((current * Double(pinch.scale)).rounded())
            switch pinch.state {
            case .began, .changed:
                if pinchStartSize == nil { pinchStartSize = terminal.font.pointSize }
                let scale = CGFloat(next / current)
                scroll.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(scaleX: scale, y: scale)
                sizeReadout.text = String(localized: "\(Int(next)) pt", bundle: .main)
                sizeReadout.isHidden = false
                setNeedsLayout()
            case .ended:
                endPinch()
                if next != current {
                    defaults.set(next, forKey: TerminalFontSize.key)
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "\(Int(next)) pt", bundle: .main))
                }
                if next == TerminalFontSize.range.lowerBound || next == TerminalFontSize.range.upperBound {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            default:
                endPinch()
            }
        }

        private func endPinch() {
            pinchStartSize = nil
            scroll.transform = .identity
            sizeReadout.isHidden = true
        }

        required init?(coder: NSCoder) { nil }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView === scroll else { return }
            refreshReadingDocument()
        }

        /// The area the text uses: the view without its side insets.
        private var contentBounds: CGRect {
            let left = max(Self.edgeInset, safeAreaInsets.left), right = max(Self.edgeInset, safeAreaInsets.right)
            return bounds.inset(by: UIEdgeInsets(top: 0, left: left, bottom: 0, right: right))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let content = contentBounds
            if pinchStartSize == nil {
                scroll.transform = .identity
                scroll.frame = content
            }
            readingView.frame = content
            let side: CGFloat = 44, margin: CGFloat = WitermMetrics.Space.m
            latestButton.frame = CGRect(x: content.maxX - side - margin, y: bounds.maxY - side - margin, width: side, height: side)
            let readout = sizeReadout.intrinsicContentSize
            sizeReadout.frame = CGRect(x: bounds.midX - (readout.width + 32) / 2, y: bounds.midY - (readout.height + 16) / 2,
                                       width: readout.width + 32, height: readout.height + 16)
            if let grid = fixedGrid {
                preserveGrid(grid)
                terminal.frame = fixedGridFrame()
                preserveGrid(grid)
            } else {
                reportedFit = nil
                let grid = terminal.getOptimalFrameSize()
                let columns = max(1, terminal.getTerminal().cols)
                let rows = max(1, terminal.getTerminal().rows)
                let pixel = 1 / max(1, traitCollection.displayScale)
                // Large accessibility fonts can require horizontal scrolling
                // to preserve the protocol's minimum 20-column input grid.
                terminal.frame = CGRect(origin: .zero, size: CGSize(
                    width: max(content.width, grid.width / CGFloat(columns) * 20 + pixel),
                    height: max(content.height, grid.height / CGFloat(rows) * 5 + pixel)
                ))
                pinToBottomIfFollowing()
            }
            scroll.contentSize = terminal.frame.size
            // A grid that shrank (such as after following a wider one) must
            // not leave the view scrolled past its new edges.
            let maximum = CGPoint(x: max(0, scroll.contentSize.width - scroll.bounds.width),
                                  y: max(0, scroll.contentSize.height - scroll.bounds.height))
            if scroll.contentOffset.x > maximum.x || scroll.contentOffset.y > maximum.y {
                scroll.contentOffset = CGPoint(x: min(scroll.contentOffset.x, maximum.x), y: min(scroll.contentOffset.y, maximum.y))
            }
            if followedGrid != nil, frozenGrid == nil {
                // Keep the service told of this view's own size, which applies once it types.
                let fit = fitGrid
                if reportedFit.map({ $0 != fit }) ?? true {
                    reportedFit = fit
                    terminal.terminalDelegate?.sizeChanged(source: terminal, newCols: fit.columns, newRows: fit.rows)
                }
            }
            refreshReadingDocument()
            updateLatestButton(output: false)
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        /// The keyboard animates the height through several frames. When the
        /// final one keeps the same number of rows, SwiftTerm doesn't move
        /// its rows again, so a view that follows output was left aligned to
        /// an in-between height, a few points short of the bottom, with the
        /// prompt's foot under the key row. Keep it on the bottom.
        private func pinToBottomIfFollowing() {
            terminal.layoutIfNeeded()
            guard terminal.canScroll, terminal.scrollPosition >= 1, !terminal.isTracking, !terminal.isDecelerating else { return }
            let bottom = max(0, terminal.contentSize.height - terminal.bounds.height)
            if abs(terminal.contentOffset.y - bottom) > 0.01 { terminal.contentOffset.y = bottom }
        }

        /// The grid this view shows at its own size, within the protocol's
        /// limits, computed as SwiftTerm does (whole cells that fit). A cell
        /// size recovered by division can be a hair off, so a size that is an
        /// exact multiple still counts as fitting.
        private var fitGrid: (columns: Int, rows: Int) {
            let cell = cellSize
            guard cell.width > 0, cell.height > 0 else { return (session.columns, session.rows) }
            func whole(_ length: CGFloat, _ unit: CGFloat) -> Int { Int((length / unit) * (1 + 1e-9)) }
            let content = contentBounds
            return (min(500, max(20, whole(content.width, cell.width))), min(200, max(5, whole(content.height, cell.height))))
        }

        func setInteractive(_ enabled: Bool) {
            guard !enabled else { return }
            terminal.disableInput()
            if frozenGrid == nil {
                frozenGrid = (terminal.getTerminal().cols, terminal.getTerminal().rows)
                setNeedsLayout()
            }
        }

        func updateFontSize(_ size: CGFloat) {
            guard terminal.font.pointSize != size else { return }
            // SwiftTerm's font setter resizes from the old frame. A fixed grid
            // must keep its rows/columns while its physical cell size changes.
            terminal.frame = .zero
            terminal.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            if let grid = fixedGrid {
                preserveGrid(grid)
                terminal.frame = fixedGridFrame()
            }
            setNeedsLayout()
        }

        private var fixedGrid: (columns: Int, rows: Int)? {
            mode == .view ? (session.columns, session.rows) : frozenGrid ?? followedGrid
        }

        private func preserveGrid(_ grid: (columns: Int, rows: Int)) {
            if terminal.getTerminal().cols != grid.columns || terminal.getTerminal().rows != grid.rows {
                terminal.getTerminal().resize(cols: grid.columns, rows: grid.rows)
                terminal.sizeChanged(source: terminal.getTerminal())
            }
        }

        private func fixedGridFrame() -> CGRect {
            var frame = terminal.getOptimalFrameSize()
            // SwiftTerm floors frame/cell when laying out. One physical pixel
            // prevents an exact N-cell product rounding back down to N-1.
            let pixel = 1 / max(1, traitCollection.displayScale)
            frame.size.width += pixel
            frame.size.height += pixel
            return frame
        }

        private func updateColors() {
            let dark = overrideUserInterfaceStyle == .dark
                || (overrideUserInterfaceStyle == .unspecified && traitCollection.userInterfaceStyle == .dark)
            // Enhanced contrast takes precedence over a color scheme.
            let values = highContrast ? nil : palette.values(dark: dark)
            terminal.nativeBackgroundColor = highContrast ? (dark ? .black : .white)
                : values.map { UIColor(terminalRGB: $0.background) } ?? UIColor.systemBackground.resolvedColor(with: traitCollection)
            terminal.nativeForegroundColor = highContrast ? (dark ? .white : .black)
                : values.map { UIColor(terminalRGB: $0.foreground) } ?? UIColor.label.resolvedColor(with: traitCollection)
            terminal.caretColor = dark ? .white : .black
            // Selection looks like selection elsewhere in iOS: the tint's
            // highlight behind the text, which keeps its own color, and
            // handles in the tint.
            let tint = terminal.tintColor.resolvedColor(with: traitCollection)
            terminal.selectionHandleColor = tint
            terminal.selectedTextBackgroundColor = tint.withAlphaComponent(highContrast ? 0.4 : 0.28)
            terminal.selectedTextForegroundColor = terminal.nativeForegroundColor
            backgroundColor = terminal.nativeBackgroundColor
            if paletteDark == nil || highContrast || installedPalette != palette || (palette != .system && paletteDark != dark) {
                terminal.installColors(TerminalPalette.colors(highContrast: highContrast, dark: dark, scheme: palette))
                installedPalette = palette
            }
            paletteDark = dark
        }

        func updateAppearance(highContrast: Bool, scheme: ColorScheme?, palette: TerminalColorScheme = .system) {
            let style: UIUserInterfaceStyle = scheme == .dark ? .dark : (scheme == .light ? .light : .unspecified)
            guard overrideUserInterfaceStyle != style || self.highContrast != highContrast || self.palette != palette
                || paletteDark == nil else { return }
            overrideUserInterfaceStyle = style
            // Leaving enhanced contrast reinstalls the scheme's own palette.
            if self.highContrast && !highContrast { installedPalette = nil }
            self.highContrast = highContrast
            self.palette = palette
            updateColors()
        }

        func applyGeometry(_ geometry: LocalSessionInfo) {
            session = geometry
            if mode == .view || frozenGrid != nil { frozenGrid = (geometry.columns, geometry.rows) }
            else if !bounds.isEmpty {
                let fit = fitGrid
                followedGrid = fit == (geometry.columns, geometry.rows) ? nil : (geometry.columns, geometry.rows)
            }
            readingView.clearReadingSelection()
            setNeedsLayout()
            layoutIfNeeded()
            refreshReadingDocument()
        }

        private var cellSize: CGSize {
            let grid = terminal.getOptimalFrameSize(), core = terminal.getTerminal()
            return CGSize(width: grid.width / CGFloat(max(1, core.cols)), height: grid.height / CGFloat(max(1, core.rows)))
        }

        private func readingRectFromGrid(_ grid: CGRect) -> CGRect {
            let base = CGFloat(terminal.getTerminal().getTopVisibleRow()) * cellSize.height
            return terminal.convert(grid.offsetBy(dx: 0, dy: base), to: readingView)
        }

        private func readingPointToGrid(_ point: CGPoint) -> CGPoint {
            let local = terminal.convert(point, from: readingView)
            return CGPoint(x: local.x, y: local.y - CGFloat(terminal.getTerminal().getTopVisibleRow()) * cellSize.height)
        }

        func refreshReadingDocument(outputChanged: Bool = false) {
            let core = terminal.getTerminal()
            guard !core.synchronizedOutputActive, !terminal.bounds.isEmpty else { return }
            let visible = terminal.convert(bounds, from: self).intersection(terminal.bounds)
            let origin = CGPoint(x: 0, y: CGFloat(core.getTopVisibleRow()) * cellSize.height)
            let page = TerminalAXViewport.cells(in: visible, origin: origin, cellSize: cellSize, columns: core.cols, rows: core.rows)
            let cursor = core.getCursorLocation()
            let liveCursor = !terminal.canScroll || terminal.scrollPosition >= 0.999 || core.isCurrentBufferAlternate
                ? (row: cursor.y, column: min(cursor.x, core.cols)) : nil
            let document = TerminalAXDocument.make(terminal: core, rows: page.rows, columns: page.columns, cursor: liveCursor)
            readingView.update(document: document, cellSize: cellSize, font: terminal.font,
                               announceOutput: outputChanged && announceOutput)
            #if DEBUG
            if Self.layoutProbe {
                let base = readingView.accessibilityLabel?.components(separatedBy: " |").first ?? ""
                readingView.accessibilityLabel = base + String(format: " | rows=%d yDisp=%d pos=%.3f page=%d..<%d cell=%.3f frameH=%.2f boundsH=%.2f offset=%.2f content=%.2f mem=%.1f",
                    core.rows, core.getTopVisibleRow(), terminal.scrollPosition, page.rows.lowerBound, page.rows.upperBound,
                    cellSize.height, terminal.frame.height, bounds.height, terminal.contentOffset.y, terminal.contentSize.height,
                    Self.footprintMB()) + String(format: " burst=%.3f", terminal.probeBurst.last - terminal.probeBurst.start)
            }
            #endif
        }

        #if DEBUG
        /// UI tests that measure layout read the grid's numbers from the label.
        private static let layoutProbe = ProcessInfo.processInfo.arguments.contains("--witerm-ui-test-layout-probe")

        /// The app's memory as the system counts it, for the performance probe.
        private static func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }
        #endif

        func pageReading(forward: Bool) -> Bool {
            let core = terminal.getTerminal(), previous = core.getTopVisibleRow()
            // SwiftTerm sends application PageUp/PageDown keys in its alternate
            // buffer. Reading actions must only move the local viewport.
            if !core.isCurrentBufferAlternate {
                if forward { terminal.pageDown() } else { terminal.pageUp() }
            }
            if previous == core.getTopVisibleRow() {
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
                let target = max(0, min(maximum, scroll.contentOffset.y + (forward ? 1 : -1) * scroll.bounds.height))
                guard target != scroll.contentOffset.y else { return false }
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
            }
            refreshReadingDocument()
            return true
        }

        func panReading(forward: Bool) -> Bool {
            let maximum = max(0, scroll.contentSize.width - scroll.bounds.width)
            let target = max(0, min(maximum, scroll.contentOffset.x + (forward ? 1 : -1) * scroll.bounds.width))
            guard target != scroll.contentOffset.x else { return false }
            scroll.setContentOffset(CGPoint(x: target, y: scroll.contentOffset.y), animated: false)
            refreshReadingDocument()
            return true
        }
    }

    @MainActor final class TerminalInputView: TerminalView, @preconcurrency UIEditMenuInteractionDelegate {
        private let mode: LocalAttachmentMode
        private var inputEnabled: Bool
        var inputDestination = ""
        private var pasteToken: UUID?
        private weak var pasteReview: UIViewController?
        private var editMenu: UIEditMenuInteraction?
        private var focusTapRecognizer: UITapGestureRecognizer?
        /// Drags a selection's start or end handle; anywhere else a drag scrolls.
        private var handleRecognizer: UIPanGestureRecognizer?
        var acceptsInput: Bool { mode == .control && inputEnabled }
        /// The view scrolled or got output; `true` for output.
        var scrollStateChanged: ((Bool) -> Void)?

        init(mode: LocalAttachmentMode, session: LocalSessionInfo, fontSize: CGFloat, isInteractive: Bool) {
            TerminalView.textInputDebugEnabled = false
            self.mode = mode
            inputEnabled = isInteractive
            super.init(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                       options: TerminalOptions(cols: session.columns, rows: session.rows))
            inputDestination = session.name
            // Text from the key row's system Paste control (no paste prompt).
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.utf8PlainText.identifier, UTType.plainText.identifier])
            inputAccessoryView = MobileTerminalAccessory(terminal: self)
            // SwiftTerm leaves the scroll delegate unset; ours only finishes
            // a scroll that comes to rest just short of the bottom.
            delegate = self
            installTouchModel()
        }

        // MARK: Touch

        /// Drag scrolls the output (SwiftTerm's own scrolling). A long press
        /// selects the word under the finger and dragging extends it; lifting
        /// shows Copy and the other edit actions. A tap brings up the keyboard
        /// when typing is allowed, or clears a selection. Only a controlling
        /// terminal passes touches to programs that ask for the mouse.
        private func installTouchModel() {
            // SwiftTerm's long press only opens a menu, and needs the keyboard focus a
            // read-only terminal never has.
            for recognizer in gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
                recognizer.isEnabled = false
            }
            let press = UILongPressGestureRecognizer(target: self, action: #selector(selectionPress(_:)))
            press.minimumPressDuration = 0.35
            addGestureRecognizer(press)
            let tap = UITapGestureRecognizer(target: self, action: #selector(focusTap(_:)))
            for recognizer in gestureRecognizers ?? [] {
                if let other = recognizer as? UITapGestureRecognizer, other.numberOfTapsRequired == 2 { tap.require(toFail: other) }
            }
            addGestureRecognizer(tap)
            focusTapRecognizer = tap
            let menu = UIEditMenuInteraction(delegate: self)
            addInteraction(menu)
            editMenu = menu
            let handles = UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:)))
            handles.maximumNumberOfTouches = 1
            addGestureRecognizer(handles)
            // Scrolling waits only until a drag is known not to start on a handle.
            panGestureRecognizer.require(toFail: handles)
            handleRecognizer = handles
            allowMouseReporting = acceptsInput
        }

        /// The cell size, as the renderer lays out its rows.
        private var cell: CGSize {
            let core = getTerminal(), frame = getOptimalFrameSize()
            return CGSize(width: frame.width / CGFloat(max(1, core.cols)), height: frame.height / CGFloat(max(1, core.rows)))
        }

        /// The selection's end that a touch at `point` grabs, within a
        /// 44 pt target around its handle: the start's handle hangs above
        /// its first character, the end's below its last.
        func selectionHandle(near point: CGPoint) -> SelectionHandle? {
            guard selection.active else { return nil }
            let cell = cell
            let (first, last) = Position.compare(selection.start, selection.end) == .before
                ? (selection.start, selection.end) : (selection.end, selection.start)
            let start = CGPoint(x: CGFloat(first.col) * cell.width, y: CGFloat(first.row) * cell.height)
            let end = CGPoint(x: CGFloat(last.col) * cell.width, y: CGFloat(last.row + 1) * cell.height)
            func distance(_ handle: CGPoint) -> CGFloat { hypot(point.x - handle.x, point.y - handle.y) }
            let reach: CGFloat = 22 + cell.height / 2
            let toStart = distance(start), toEnd = distance(end)
            guard min(toStart, toEnd) <= reach else { return nil }
            return toStart < toEnd ? .start : .end
        }

        enum SelectionHandle { case start, end }

        @objc private func dragHandle(_ pan: UIPanGestureRecognizer) {
            let point = pan.location(in: self)
            switch pan.state {
            case .began:
                guard let handle = selectionHandle(near: point) else { return }
                editMenu?.dismissMenu()
                let (first, last) = Position.compare(selection.start, selection.end) == .before
                    ? (selection.start, selection.end) : (selection.end, selection.start)
                // The other end stays put while this one follows the finger.
                selection.pivot = handle == .start ? last : first
                UISelectionFeedbackGenerator().selectionChanged()
            case .changed:
                extendSelection(to: point)
            case .ended, .cancelled:
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            default: break
            }
        }

        /// The buffer position under a point in this view's coordinates,
        /// which scroll with the output.
        func bufferPosition(at point: CGPoint) -> Position {
            let core = getTerminal()
            let frame = getOptimalFrameSize()
            let cell = CGSize(width: frame.width / CGFloat(max(1, core.cols)), height: frame.height / CGFloat(max(1, core.rows)))
            let column = Int(point.x / max(1, cell.width)), row = Int(point.y / max(1, cell.height))
            let lastRow = core.getTopVisibleRow() + core.rows - 1
            return Position(col: min(max(0, column), core.cols - 1), row: min(max(0, row), lastRow))
        }

        /// Starts a selection at the word under `point`; the far end then follows the finger.
        func beginSelection(at point: CGPoint) {
            editMenu?.dismissMenu()
            selection.selectWordOrExpression(at: bufferPosition(at: point), in: getTerminal().buffer)
            selection.selectionMode = .character
            selection.pivot = selection.start
            setNeedsDisplay()
        }

        func extendSelection(to point: CGPoint) {
            guard selection.active, let pivot = selection.pivot else { return }
            var position = bufferPosition(at: point)
            // The selection's end is exclusive; include the character under
            // the finger when dragging forward.
            if (position.row, position.col) >= (pivot.row, pivot.col) {
                position.col = min(position.col + 1, getTerminal().cols)
            }
            selection.pivotExtend(bufferPosition: position)
            setNeedsDisplay()
        }

        @objc private func selectionPress(_ press: UILongPressGestureRecognizer) {
            let point = press.location(in: self)
            switch press.state {
            case .began:
                beginSelection(at: point)
                UISelectionFeedbackGenerator().selectionChanged()
            case .changed:
                extendSelection(to: point)
            case .ended:
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            default: break
            }
        }

        /// The focus tap only clears a selection or brings up the keyboard;
        /// with the keyboard up, SwiftTerm's own tap handles links and mouse clicks.
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer === focusTapRecognizer { return selection.active || (acceptsInput && !isFirstResponder) }
            if recognizer === handleRecognizer { return selectionHandle(near: recognizer.location(in: self)) != nil }
            // SwiftTerm's own selection drag (after a double tap) would move
            // the selection's end from anywhere; here a drag away from the
            // handles scrolls, as in other iOS text. Its mouse drag, for a
            // program that asked for the mouse, still begins.
            if recognizer is UIPanGestureRecognizer, recognizer !== panGestureRecognizer,
               !(allowMouseReporting && getTerminal().mouseMode != .off) { return false }
            return super.gestureRecognizerShouldBegin(recognizer)
        }

        @objc private func focusTap(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended else { return }
            if selection.active {
                selection.selectNone()
                editMenu?.dismissMenu()
                setNeedsDisplay()
            } else if acceptsInput, !isFirstResponder {
                _ = becomeFirstResponder()
            }
        }

        override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { acceptsInput }

        override func paste(itemProviders: [NSItemProvider]) {
            guard acceptsInput,
                  let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            // Load off the view, then come back to the main actor with the
            // text only, so the view itself never crosses isolation.
            Task { @MainActor [weak self] in
                let text: String? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        continuation.resume(returning: (object as? NSString).map(String.init))
                    }
                }
                if let text { self?.reviewOrPaste(text) }
            }
        }

        /// The system's own Paste command among the edit menu's suggestions.
        /// Choosing it counts as the person's paste, so iOS doesn't ask.
        static func systemPaste(in elements: [UIMenuElement]) -> UIMenuElement? {
            for element in elements {
                if let command = element as? UICommand, command.action == #selector(UIResponderStandardEditActions.paste(_:)) {
                    return command
                }
                if let menu = element as? UIMenu, let found = systemPaste(in: menu.children) { return found }
            }
            return nil
        }

        /// The edit actions offered after a selection: Copy and selecting
        /// more always; Paste only where typing is allowed.
        func editActions() -> [UIAction] {
            var actions: [UIAction] = []
            if selection.active {
                actions.append(UIAction(title: String(localized: "Copy", bundle: .main), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    guard let self else { return }
                    UIPasteboard.general.string = self.selection.getSelectedText()
                    self.selection.selectNone()
                    self.setNeedsDisplay()
                })
                actions.append(UIAction(title: String(localized: "Select Line", bundle: .main)) { [weak self] _ in
                    guard let self else { return }
                    self.selection.select(row: self.selection.start.row)
                    self.setNeedsDisplay()
                })
            }
            actions.append(UIAction(title: String(localized: "Select All", bundle: .main)) { [weak self] _ in
                self?.selection.selectAll()
                self?.setNeedsDisplay()
            })
            if acceptsInput, UIPasteboard.general.hasStrings {
                actions.append(UIAction(title: String(localized: "Paste", bundle: .main), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                    self?.paste(nil)
                })
            }
            return actions
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            let paste = String(localized: "Paste", bundle: .main)
            guard acceptsInput, let system = Self.systemPaste(in: suggestedActions) else { return UIMenu(children: editActions()) }
            return UIMenu(children: editActions().filter { $0.title != paste } + [system])
        }

        required init?(coder: NSCoder) { nil }
        override var isAccessibilityElement: Bool {
            get { false }
            set { }
        }
        override var canBecomeFirstResponder: Bool { mode == .control && inputEnabled }

        /// Brings up the keyboard the first time this terminal is on screen
        /// while it accepts typing, so a new connection is ready to type into.
        /// Set once per connection; showing the terminal again keeps whatever
        /// the person chose since.
        var focusesWhenShown = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, focusesWhenShown, acceptsInput else { return }
            focusesWhenShown = false
            // After this layout pass, like the keyboard button's request.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.acceptsInput, !self.isFirstResponder else { return }
                _ = self.becomeFirstResponder()
            }
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { postFocus(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { postFocus(false) }
            return resigned
        }

        /// Lets the keyboard button say whether it shows or hides the keyboard.
        private func postFocus(_ focused: Bool) {
            NotificationCenter.default.post(name: .witermTerminalFocusChanged, object: self, userInfo: ["focused": focused])
        }

        func disableInput() {
            inputEnabled = false
            allowMouseReporting = false
            controlModifier = false
            pasteToken = nil
            pasteReview?.dismiss(animated: false)
            inputAccessoryView?.isUserInteractionEnabled = false
        }

        func sendAccessory(_ bytes: [UInt8]) {
            guard acceptsInput else { return }
            controlModifier = false
            send(bytes)
        }

        /// Types a saved snippet. Multiline snippets go through the same review as
        /// a multiline paste; a single line may add Return when the snippet asks.
        func sendSnippet(_ snippet: CommandSnippet) {
            guard acceptsInput else { return }
            if snippet.isMultiline { reviewOrPaste(snippet.text); return }
            controlModifier = false
            send(snippet.input(bracketedPaste: getTerminal().bracketedPasteMode))
        }

        override func paste(_ sender: Any?) {
            guard acceptsInput, let text = UIPasteboard.general.string else { return }
            reviewOrPaste(text)
        }

        /// Shared by the normal Paste action and native acceptance tests.
        func reviewOrPaste(_ text: String) {
            guard acceptsInput else { return }
            guard text.contains(where: { $0.isNewline }) else { pasteText(text); return }
            guard pasteReview == nil else { return }
            var responder: UIResponder? = self
            while responder != nil, !(responder is UIViewController) { responder = responder?.next }
            guard let controller = responder as? UIViewController, controller.presentedViewController == nil else { return }
            let token = UUID()
            pasteToken = token
            let review = UIHostingController(rootView: TerminalPasteReview(text: text, destination: inputDestination,
                cancel: { [weak self] in
                    self?.pasteToken = nil
                    self?.pasteReview?.dismiss(animated: true)
                }, confirm: { [weak self] in
                    guard let self, self.acceptsInput, self.pasteToken == token else { return }
                    self.pasteToken = nil
                    self.pasteReview?.dismiss(animated: true)
                    self.pasteText(text)
                }))
            pasteReview = review
            controller.present(review, animated: true)
        }

        private func pasteText(_ text: String) {
            guard acceptsInput else { return }
            controlModifier = false
            if getTerminal().bracketedPasteMode { send(Array("\u{1b}[200~".utf8)) }
            send(txt: text)
            if getTerminal().bracketedPasteMode { send(Array("\u{1b}[201~".utf8)) }
        }

        override func insertText(_ text: String) {
            guard mode == .control, inputEnabled else { return }
            super.insertText(text)
        }

        override func deleteBackward() {
            guard mode == .control, inputEnabled else { return }
            super.deleteBackward()
        }

        var geometryChanged: ((LocalSessionInfo) -> Void)?
        var readingChanged: ((Bool) -> Void)?
        private var readingRefreshQueued = false
        private var readingRefreshHasOutput = false

        /// Rebuilds the reading page (what VoiceOver reads) once per run-loop
        /// turn, however many output chunks or scroll steps arrived in it,
        /// rather than once per chunk while long output streams in.
        func requestReadingRefresh(output: Bool) {
            if output { scrollStateChanged?(true) }
            #if DEBUG
            if output { probeOutputArrived() }
            #endif
            readingRefreshHasOutput = readingRefreshHasOutput || output
            guard !readingRefreshQueued else { return }
            readingRefreshQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let output = self.readingRefreshHasOutput
                self.readingRefreshQueued = false
                self.readingRefreshHasOutput = false
                self.readingChanged?(output)
            }
        }

        #if DEBUG
        /// The latest run of output, for the performance probe: when its
        /// first and last deliveries reached the renderer. A pause of a
        /// second starts a new run.
        private(set) var probeBurst: (start: CFTimeInterval, last: CFTimeInterval) = (0, 0)

        private func probeOutputArrived() {
            let now = CACurrentMediaTime()
            if now - probeBurst.last > 1 { probeBurst.start = now }
            probeBurst.last = now
        }
        #endif

        /// A scroll that comes to rest within half a row of the bottom counts
        /// as back at the live screen in SwiftTerm, but the view stayed a few
        /// points short, cutting off the foot of the last row (the prompt)
        /// and leaving it off the reading page. Finish the trip.
        @objc func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { snapToBottomIfFollowing() }

        @objc func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { snapToBottomIfFollowing() }
        }

        private func snapToBottomIfFollowing() {
            guard canScroll, scrollPosition >= 1 else { return }
            let bottom = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
            guard contentOffset.y < bottom else { return }
            setContentOffset(CGPoint(x: contentOffset.x, y: bottom), animated: false)
        }

        /// SwiftTerm moves its rows for a touch scroll, and when it follows
        /// output, by setting the content offset without telling its delegate;
        /// the reading page follows it too.
        override var contentOffset: CGPoint {
            didSet {
                if oldValue != contentOffset {
                    requestReadingRefresh(output: false)
                    scrollStateChanged?(false)
                }
            }
        }

        func applyGeometry(_ session: LocalSessionInfo) {
            if getTerminal().cols != session.columns || getTerminal().rows != session.rows {
                getTerminal().resize(cols: session.columns, rows: session.rows)
                sizeChanged(source: getTerminal())
            }
            geometryChanged?(session)
        }

        override func selectionChanged(source: Terminal) {
            super.selectionChanged(source: source)
            readingChanged?(false)
        }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private var keyboardRequest: Int
        private var keyboardGeneration: UInt64 = 0
        private weak var terminal: TerminalInputView?
        private var isInteractive: Bool
        private let attachment: RemoteTerminalAttachment
        private let mode: LocalAttachmentMode
        private let onFailure: (Error) -> Void
        private let onEnded: () -> Void
        private var outputTask: Task<Void, Never>?
        private var inputTask: Task<Void, Never>?
        private var resizeTask: Task<Void, Never>?
        private var inputQueue: [(data: Data, automatic: Bool)] = []
        /// True while output is fed to the terminal: anything it sends then
        /// is its own answer to a query, not typing.
        private var feeding = false
        private var inputBytes = 0
        private var pendingSize: (Int, Int)?
        private var resizing = false
        private var stopped = false
        private var serverGrid: (Int, Int)

        init(attachment: RemoteTerminalAttachment, mode: LocalAttachmentMode, keyboardRequest: Int,
             isInteractive: Bool,
             onFailure: @escaping (Error) -> Void, onEnded: @escaping () -> Void) {
            self.attachment = attachment
            self.mode = mode
            self.keyboardRequest = keyboardRequest
            self.isInteractive = isInteractive
            self.onFailure = onFailure
            self.onEnded = onEnded
            serverGrid = (attachment.session.columns, attachment.session.rows)
        }

        func setInteractive(_ enabled: Bool) {
            guard !enabled, isInteractive else { return }
            isInteractive = false
            terminal?.disableInput()
            keyboardGeneration &+= 1
            inputQueue.removeAll()
            inputBytes = 0
            pendingSize = nil
            // Canceling an in-flight Core RPC also closes its channel. Let that
            // single ACK finish so a model-owned detach can complete normally.
            if !resizing { resizeTask?.cancel() }
            dismissKeyboard()
        }

        func start(_ view: TerminalInputView) {
            terminal = view
            stabilizeTestCursor(view)
            outputTask = Task { [weak self, weak view, attachment] in
                do {
                    for try await event in attachment.events {
                        try Task.checkCancellation()
                        guard let self, !self.stopped, let view else { return }
                        switch event {
                        case .geometry(let session):
                            self.serverGrid = (session.columns, session.rows)
                            view.applyGeometry(session)
                        case .output(let data):
                            self.feeding = true
                            view.feed(byteArray: Array(data)[...])
                            self.feeding = false
                            self.stabilizeTestCursor(view)
                            view.requestReadingRefresh(output: true)
                        }
                    }
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    self.stop()
                    self.onEnded()
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error)
                }
            }
        }

        /// UI tests that type ask for a steady caret: a blinking one is an
        /// endless animation, so XCTest never sees the app idle. Reapplied
        /// after output, which (through tmux) may reset the cursor style.
        private func stabilizeTestCursor(_ view: TerminalView) {
            #if DEBUG
            if Self.steadyTestCursor { view.getTerminal().setCursorStyle(.steadyBlock) }
            #endif
        }

        #if DEBUG
        private static let steadyTestCursor = ProcessInfo.processInfo.arguments.contains("--witerm-ui-test-steady-terminal-cursor")
        #endif

        func requestKeyboardToggle(_ request: Int, terminal: TerminalInputView) {
            guard request != keyboardRequest else { return }
            keyboardRequest = request
            keyboardGeneration &+= 1
            let generation = keyboardGeneration
            guard !stopped, isInteractive, mode == .control, self.terminal === terminal else { return }
            // Focus changes reenter SwiftUI's focus graph. Run after this
            // representable update, and invalidate requests from old views.
            DispatchQueue.main.async { [weak self, weak terminal] in
                guard let self, let terminal, !self.stopped, self.isInteractive, self.mode == .control,
                      self.keyboardGeneration == generation, self.keyboardRequest == request,
                      self.terminal === terminal, terminal.window != nil else { return }
                if terminal.isFirstResponder { _ = terminal.resignFirstResponder() }
                else { _ = terminal.becomeFirstResponder() }
            }
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            keyboardGeneration &+= 1
            terminal?.disableInput()
            dismissKeyboard()
            terminal = nil
            outputTask?.cancel()
            inputTask?.cancel()
            resizeTask?.cancel()
            inputQueue.removeAll()
            inputBytes = 0
            Task { [attachment] in await attachment.disconnect() }
        }

        private func dismissKeyboard() {
            let previousTerminal = terminal
            DispatchQueue.main.async { [weak previousTerminal] in
                guard let previousTerminal, previousTerminal.isFirstResponder else { return }
                _ = previousTerminal.resignFirstResponder()
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard !stopped, isInteractive, mode == .control, terminal === source, !data.isEmpty else { return }
            let pieces = (data.count + 16 * 1024 - 1) / (16 * 1024)
            guard inputBytes + data.count <= 64 * 1024, inputQueue.count + pieces <= 256 else {
                fail(RelayError.backpressure)
                return
            }
            let bytes = Data(data)
            for offset in stride(from: 0, to: bytes.count, by: 16 * 1024) {
                let piece = bytes.subdata(in: offset..<min(offset + 16 * 1024, bytes.count))
                inputQueue.append((piece, feeding))
                inputBytes += piece.count
            }
            guard inputTask == nil else { return }
            inputTask = Task { [weak self, attachment] in
                defer { self?.inputTask = nil }
                do {
                    while let self, !self.stopped, self.isInteractive, !self.inputQueue.isEmpty {
                        let piece = self.inputQueue.removeFirst()
                        try await attachment.send(piece.data, automatic: piece.automatic)
                        try Task.checkCancellation()
                        guard !self.stopped, self.isInteractive else { break }
                        self.inputBytes -= piece.data.count
                    }
                } catch {
                    guard !Task.isCancelled, self?.isInteractive == true else { return }
                    self?.fail(error)
                }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard !stopped, isInteractive, mode == .control, terminal === source else { return }
            if newCols == serverGrid.0 && newRows == serverGrid.1 { return }
            pendingSize = (min(500, max(20, newCols)), min(200, max(5, newRows)))
            guard resizeTask == nil else { return }
            resizeTask = Task { [weak self, attachment] in
                defer { self?.resizeTask = nil; self?.resizing = false }
                do {
                    while let self, !self.stopped, self.isInteractive, self.pendingSize != nil {
                        try await Task.sleep(for: .milliseconds(100))
                        guard self.isInteractive, !self.stopped, let size = self.pendingSize else { break }
                        self.pendingSize = nil
                        self.resizing = true
                        try await attachment.resize(columns: size.0, rows: size.1)
                        self.resizing = false
                    }
                } catch {
                    guard !Task.isCancelled, self?.isInteractive == true else { return }
                    self?.fail(error)
                }
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) { (source as? TerminalInputView)?.readingChanged?(false) }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { (source as? TerminalInputView)?.readingChanged?(false) }
        func bell(source: TerminalView) { TerminalBell.ring() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard !link.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return }
            UIApplication.shared.open(url)
        }

        private func fail(_ error: Error) {
            guard !stopped else { return }
            stop()
            onFailure(error)
        }
    }
}
#endif
