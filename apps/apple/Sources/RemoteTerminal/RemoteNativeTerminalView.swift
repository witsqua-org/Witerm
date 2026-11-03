#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import SwiftTerm
import MetalKit
import os
import UniformTypeIdentifiers
import WitermCore

extension Notification.Name {
    /// A terminal's input view gained or lost the keyboard focus; the object
    /// is the view and `focused` in the user info says which.
    static let witermTerminalFocusChanged = Notification.Name("witermTerminalFocusChanged")
    /// Posted just before a terminal's input view takes or gives up the
    /// keyboard focus, with the same object and user info.
    static let witermTerminalFocusWillChange = Notification.Name("witermTerminalFocusWillChange")
}

/// How much of a terminal's bottom the keyboard covers, from where the key
/// row and the keyboard are now. With a hardware keyboard only the key row
/// shows, and iOS reports nothing when the device rotates with it up, so a
/// keyboard frame or height kept from before belongs to the old orientation:
/// it left landscape running under the key row and portrait 13 rows tall.
/// All rectangles are in the screen's coordinate space as it is now.
enum TerminalKeyboardOverlap {
    /// - Parameters:
    ///   - view: The terminal's frame.
    ///   - screen: The screen's bounds.
    ///   - keyRow: The terminal's key row, while it's in a window.
    ///   - keyRowWindow: The size of the key row's window.
    ///   - reported: The keyboard frame UIKit last reported, with the screen
    ///     size it was reported for.
    ///   - hiddenSinceKeyRowMoved: UIKit said the keyboard hid after the key
    ///     row last moved.
    /// - Returns: `nil` when the answer is the last one: while the key row's
    ///   window is still in the other orientation (just after this view
    ///   rotated, before the key row has), so no grid for the old one
    ///   flashes; and while the key row slides away below the screen, so its
    ///   rows return when the keyboard reports it has gone, together with
    ///   the navigation bar, not 0.4 s ahead of it.
    static func bottom(view: CGRect, screen: CGRect, keyRow: CGRect?, keyRowWindow: CGSize? = nil,
                       reported: (frame: CGRect, screen: CGSize)?, hiddenSinceKeyRowMoved: Bool = false) -> CGFloat? {
        let edge = screen.maxY
        if let row = keyRow {
            if let space = keyRowWindow, screen.width != screen.height,
               space == CGSize(width: screen.height, height: screen.width) { return nil }
            if row.minY >= edge - 0.5, !hiddenSinceKeyRowMoved { return nil }
        }
        func onScreen(_ rect: CGRect) -> Bool { rect.height > 0 && rect.minY < edge - 0.5 && rect.intersects(screen) }
        func docked(_ rect: CGRect) -> Bool { rect.maxY >= edge - 1 }
        // A frame reported for another orientation or window size says
        // nothing about this one.
        let keyboard = reported.flatMap { $0.screen == screen.size && onScreen($0.frame) ? $0.frame : nil }
        var top: CGFloat?
        if let row = keyRow, onScreen(row) {
            // The key row tops whatever covers the bottom: alone (a hardware
            // keyboard) or on a docked keyboard. Only an undocked iPad
            // keyboard, reported away from the bottom, covers less.
            let floating = !docked(row) && keyboard.map { !docked($0) } == true
            if !floating { top = row.minY }
        }
        // Another field's keyboard, such as the find bar's.
        if top == nil, let keyboard, docked(keyboard) { top = keyboard.minY }
        guard let top else { return 0 }
        return min(view.height, max(0, view.maxY - top))
    }
}

struct RemoteNativeTerminalView: UIViewRepresentable {
    let attachment: any PairedTerminalLink
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
    /// The bar's actions for the key row while the bar is hidden for typing.
    var barActions: AnyView? = nil
    /// The bottom-right keyboard button: shows the keyboard, or asks to
    /// type when watching. Nil: no button (the terminal can only watch, or
    /// isn't connected).
    var keyboardButton: (() -> Void)? = nil
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
        // A paired terminal shows the Mac service's own tmux client, which
        // asks for the mouse by itself (tmux 3.6 and later default `mouse`
        // to on, even with -f /dev/null). Its touches stay Witerm's.
        surface.terminal.passesMouseToPrograms = false
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
        view.terminal.setBarActions(barActions)
        view.setKeyboardButton(keyboardButton, identifier: "remoteKeyboard",
                               hint: String(localized: "Starts typing in this terminal.", bundle: .main))
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
        /// Bottom right, within the thumb's reach, only while the keyboard
        /// is hidden; the key row's Hide Keyboard takes its place while the
        /// keyboard is up. It sits in a strip of its own below the text, so
        /// it never covers the cursor line or Jump to Latest.
        private let keyboardButton = UIButton(type: .system)
        private var keyboardButtonAction: (() -> Void)?
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
            readingView.accessibilityLabel = String(localized: "Terminal Text", bundle: .main)
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
            installKeyboardButton()
            installSizeReadout()
            terminal.scrollStateChanged = { [weak self] output in
                #if DEBUG
                if !output { self?.probeMotion() }
                #endif
                self?.updateLatestButton(output: output)
            }
            #if DEBUG
            terminal.drawObserver = { [weak self] in self?.probeDraw($0) }
            #endif
            observeKeyboard()
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

        private func installKeyboardButton() {
            var configuration: UIButton.Configuration
            if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled { configuration = .glass() }
            else { configuration = .gray() }
            configuration.image = UIImage(systemName: "keyboard")
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .label
            keyboardButton.configuration = configuration
            let label = String(localized: "Show Keyboard", bundle: .main)
            keyboardButton.accessibilityLabel = label
            keyboardButton.showsLargeContentViewer = true
            keyboardButton.largeContentTitle = label
            keyboardButton.largeContentImage = UIImage(systemName: "keyboard")
            keyboardButton.isHidden = true
            keyboardButton.addAction(UIAction { [weak self] _ in self?.keyboardButtonAction?() }, for: .touchUpInside)
            addSubview(keyboardButton)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFocusChanged),
                                                   name: .witermTerminalFocusChanged, object: terminal)
        }

        /// The keyboard button's action, or nil for no button. A paired
        /// terminal passes one only while watching one it may type in.
        func setKeyboardButton(_ action: (() -> Void)?, identifier: String, hint: String? = nil) {
            keyboardButtonAction = action
            keyboardButton.accessibilityIdentifier = identifier
            keyboardButton.accessibilityHint = hint
            updateKeyboardButton()
        }

        @objc private func keyboardFocusChanged() {
            holdsStripForKeyboard = terminal.isFirstResponder && keyboardButtonAction != nil && keyboardOverlap == 0
            if holdsStripForKeyboard {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.holdsStripForKeyboard else { return }
                    self.holdsStripForKeyboard = false
                    self.setNeedsLayout()
                }
            }
            updateKeyboardButton()
        }

        private func updateKeyboardButton() {
            let hidden = keyboardButtonAction == nil || terminal.isFirstResponder
            guard keyboardButton.isHidden != hidden else { return }
            keyboardButton.isHidden = hidden
            updateAccessibilityElements()
            setNeedsLayout()
        }

        /// The text first, then Jump to Latest and the keyboard button when shown.
        private func updateAccessibilityElements() {
            accessibilityElements = [readingView] + (latestButton.isHidden ? [] : [latestButton])
                + (keyboardButton.isHidden ? [] : [keyboardButton])
        }

        /// The strip under the text that holds the keyboard button: there
        /// whenever nothing covers the bottom, and gone in the same layout as
        /// the keyboard's own inset arrives, so showing or hiding the keyboard
        /// still changes the grid once (not once for focus, once for the
        /// keyboard).
        private var keyboardButtonStrip: CGFloat {
            guard keyboardButtonAction != nil, keyboardOverlap == 0,
                  !terminal.isFirstResponder || holdsStripForKeyboard else { return 0 }
            return Self.keyboardButtonSide + 2 * WitermMetrics.Space.s
        }

        /// Just focused: the strip stays until the keyboard's inset arrives
        /// (or a moment passes), so the grid changes once. While focused, a
        /// keyboard frame in flux (rotating) never brings the strip back.
        private var holdsStripForKeyboard = false

        static let keyboardButtonSide: CGFloat = 44

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
            updateAccessibilityElements()
            setNeedsLayout()
        }

        private func jumpToLatest() {
            let bottom = max(0, terminal.contentSize.height - terminal.bounds.height)
            terminal.setContentOffset(CGPoint(x: terminal.contentOffset.x, y: bottom),
                                      animated: !UIAccessibility.isReduceMotionEnabled)
            UIAccessibility.post(notification: .layoutChanged, argument: readingView)
        }

        /// Pinching scales what's already drawn, continuously and about the
        /// point between the fingers, and shows the size it will set: no font,
        /// grid or resize changes and no layout pass while the fingers move.
        /// Lifting them sets that size once, so the grid reflows once and a
        /// controlled session is resized once.
        @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
            #if DEBUG
            let started = CACurrentMediaTime()
            probeMotion()
            if pinch.state == .ended, Self.layoutProbe { pinchEndedAt = started; pinchSettle = "" }
            defer { if pinch.state == .changed { probePinchStep(CACurrentMediaTime() - started) } }
            #endif
            switch pinch.state {
            case .began, .changed: pinchMoved(scale: pinch.scale, at: pinch.location(in: self))
            case .ended: pinchEnded(scale: pinch.scale)
            default: endPinch()
            }
        }

        private var storedFontSize: Double {
            UserDefaults.standard.object(forKey: TerminalFontSize.key) as? Double ?? TerminalFontSize.standard
        }

        /// The scale a pinch shows (continuous, within the sizes allowed) and
        /// the whole size it sets.
        static func pinchTarget(scale: CGFloat, stored: Double) -> (scale: CGFloat, size: Double) {
            let range = TerminalFontSize.range
            let live = min(CGFloat(range.upperBound / stored), max(CGFloat(range.lowerBound / stored), scale))
            return (live, TerminalFontSize.clamped((stored * Double(live)).rounded()))
        }

        /// Where the pinch began, which stays under the fingers.
        private var pinchAnchor: CGPoint = .zero

        func pinchMoved(scale: CGFloat, at point: CGPoint) {
            if pinchStartSize == nil {
                pinchStartSize = terminal.font.pointSize
                pinchAnchor = point
            }
            let target = Self.pinchTarget(scale: scale, stored: storedFontSize)
            if UIAccessibility.isReduceMotionEnabled {
                scroll.transform = .identity
            } else {
                // A view scales about its center; this keeps the anchor fixed.
                let offset = CGPoint(x: pinchAnchor.x - scroll.center.x, y: pinchAnchor.y - scroll.center.y)
                scroll.transform = CGAffineTransform(translationX: offset.x, y: offset.y)
                    .scaledBy(x: target.scale, y: target.scale).translatedBy(x: -offset.x, y: -offset.y)
            }
            let text = String(localized: "\(Int(target.size)) pt", bundle: .main)
            if sizeReadout.text != text || sizeReadout.isHidden {
                sizeReadout.text = text
                sizeReadout.isHidden = false
                layoutSizeReadout()
            }
        }

        /// Sets the new size in this same pass, under the scaled view, so no
        /// frame shows the old size between the pinch and the new font.
        func pinchEnded(scale: CGFloat) {
            #if DEBUG
            var marks = [CACurrentMediaTime()]
            defer {
                marks.append(CACurrentMediaTime())
                let parts = zip(marks, marks.dropFirst()).map { String(format: "%.1f", ($1 - $0) * 1000) }
                pinchLift = parts.joined(separator: "/")
            }
            #endif
            let stored = storedFontSize
            let next = Self.pinchTarget(scale: scale, stored: stored).size
            if next != stored {
                // The point size keeps the Dynamic Type factor the view has.
                updateFontSize(terminal.font.pointSize * CGFloat(next / stored))
                #if DEBUG
                marks.append(CACurrentMediaTime())
                #endif
                UserDefaults.standard.set(next, forKey: TerminalFontSize.key)
                UIAccessibility.post(notification: .announcement, argument: String(localized: "\(Int(next)) pt", bundle: .main))
                #if DEBUG
                marks.append(CACurrentMediaTime())
                #endif
            }
            if next == TerminalFontSize.range.lowerBound || next == TerminalFontSize.range.upperBound {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            endPinch()
            layoutIfNeeded()
        }

        #if DEBUG
        /// Milliseconds the lift spent: font, saving the size, layout (reflow).
        private var pinchLift = ""
        #endif

        private func endPinch() {
            pinchStartSize = nil
            scroll.transform = .identity
            sizeReadout.isHidden = true
            setNeedsLayout()
        }

        private func layoutSizeReadout() {
            let content = contentBounds, readout = sizeReadout.intrinsicContentSize
            sizeReadout.frame = CGRect(x: content.midX - (readout.width + 32) / 2, y: content.midY - (readout.height + 16) / 2,
                                       width: readout.width + 32, height: readout.height + 16)
        }

        required init?(coder: NSCoder) { nil }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView === scroll else { return }
            // Panning a wide grid by touch: the reading page catches up when
            // the pan stops, unless VoiceOver is reading it.
            if scroll.isTracking || scroll.isDecelerating, !UIAccessibility.isVoiceOverRunning { return }
            refreshReadingDocument()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if scrollView === scroll { terminal.scrollWillBegin() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard scrollView === scroll else { return }
            refreshReadingDocument()
            terminal.scrollDidStop()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard scrollView === scroll, !decelerate else { return }
            refreshReadingDocument()
            terminal.scrollDidStop()
        }

        /// The area the text uses: the view without its side insets and
        /// without the part the keyboard covers.
        private var contentBounds: CGRect {
            let left = max(Self.edgeInset, safeAreaInsets.left), right = max(Self.edgeInset, safeAreaInsets.right)
            return bounds.inset(by: UIEdgeInsets(top: 0, left: left, bottom: keyboardOverlap + keyboardButtonStrip, right: right))
        }

        // MARK: Keyboard

        /// How much of the view's bottom the keyboard (or the key row alone)
        /// covers, as of the last layout. SwiftUI's keyboard avoidance is off
        /// for terminals: it kept a frame from the orientation the keyboard
        /// was shown in, because iOS reports nothing when the device rotates
        /// with only the key row up.
        private(set) var keyboardOverlap: CGFloat = 0

        /// The keyboard frame UIKit last reported, in screen coordinates,
        /// with the screen size it was reported for. One keyboard serves
        /// every terminal.
        private static var reportedKeyboard: (frame: CGRect, screen: CGSize)?
        /// Orders the keyboard's hiding and this view's key row moves.
        private static var keyboardEvents = 0
        private static var hiddenAt = 0
        private var keyRowMovedAt = 0
        /// Where the key row was last seen, in screen coordinates.
        private var keyRowSeen: CGRect?

        private func observeKeyboard() {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(keyboardWillMove(_:)),
                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            for name in [UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidShowNotification,
                         UIResponder.keyboardDidHideNotification] {
                center.addObserver(self, selector: #selector(keyboardDidMove(_:)), name: name, object: nil)
            }
            terminal.keyRowMoved = { [weak self] in
                self?.noteKeyRow()
                self?.keyboardMayHaveMoved()
            }
        }

        private func recordKeyboard(_ note: Notification) {
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
                  let screen = (note.object as? UIScreen) ?? window?.windowScene?.screen else { return }
            Self.reportedKeyboard = (frame, screen.coordinateSpace.bounds.size)
            if note.name == UIResponder.keyboardDidHideNotification {
                Self.keyboardEvents += 1
                Self.hiddenAt = Self.keyboardEvents
            }
            #if DEBUG
            let tag = note.name == UIResponder.keyboardWillChangeFrameNotification ? "wcf"
                : note.name == UIResponder.keyboardDidChangeFrameNotification ? "dcf"
                : note.name == UIResponder.keyboardDidShowNotification ? "ds" : "dh"
            Self.probeEvent(tag + String(format: "(%.0f,%.0f)", frame.minY, frame.height))
            #endif
        }

        /// The key row's frame, while it's in a shown window.
        private var keyRowFrame: (frame: CGRect, window: CGSize)? {
            guard let screen = window?.windowScene?.screen, let row = terminal.inputAccessoryView,
                  let rowWindow = row.window, !rowWindow.isHidden, !row.isHidden else { return nil }
            return (row.convert(row.bounds, to: screen.coordinateSpace), rowWindow.bounds.size)
        }

        /// Counts a move only when the key row really moved (it also lays
        /// out when its keys change, as when the bar returns).
        private func noteKeyRow() {
            let frame = keyRowFrame?.frame
            guard frame != keyRowSeen else { return }
            keyRowSeen = frame
            #if DEBUG
            Self.probeEvent(frame.map { String(format: "k(%.0f)", $0.minY) } ?? "k(out)")
            #endif
            Self.keyboardEvents += 1
            keyRowMovedAt = Self.keyboardEvents
        }

        /// Only noted: the space changes once the keyboard has moved (or
        /// the key row reports where it is), as the bar's return does.
        @objc private func keyboardWillMove(_ note: Notification) { recordKeyboard(note) }

        @objc private func keyboardDidMove(_ note: Notification) {
            recordKeyboard(note)
            keyboardMayHaveMoved()
        }

        /// Lays out again when the keyboard's space changed: now, and once
        /// more after this turn, when the key row's own move has landed.
        func keyboardMayHaveMoved() {
            relayoutIfKeyboardMoved()
            DispatchQueue.main.async { [weak self] in
                self?.noteKeyRow()
                self?.relayoutIfKeyboardMoved()
            }
        }

        private func relayoutIfKeyboardMoved() {
            guard let measured = measuredKeyboardOverlap() else { return }
            if abs(measured - keyboardOverlap) > 0.25 { setNeedsLayout() }
        }

        /// Measured from where the key row and the keyboard are now, in the
        /// current orientation, never from a height kept from before; `nil`
        /// while the key row hasn't rotated yet.
        private func measuredKeyboardOverlap() -> CGFloat? {
            guard let screen = window?.windowScene?.screen else { return 0 }
            let space = screen.coordinateSpace, row = keyRowFrame
            return TerminalKeyboardOverlap.bottom(view: convert(bounds, to: space), screen: space.bounds, keyRow: row?.frame,
                                                  keyRowWindow: row?.window, reported: Self.reportedKeyboard,
                                                  hiddenSinceKeyRowMoved: Self.hiddenAt > keyRowMovedAt)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // While pinching, only the size readout moves (its text changing
            // asks for layout); everything else waits for the fingers to lift.
            guard pinchStartSize == nil else { return layoutSizeReadout() }
            #if DEBUG
            fullLayouts += 1
            let started = CACurrentMediaTime()
            defer { probeLayout(CACurrentMediaTime() - started) }
            #endif
            if let measured = measuredKeyboardOverlap() { keyboardOverlap = measured }
            if keyboardOverlap > 0 { holdsStripForKeyboard = false }
            let content = contentBounds
            scroll.transform = .identity
            scroll.frame = content
            readingView.frame = content
            let side: CGFloat = 44, margin: CGFloat = WitermMetrics.Space.m
            latestButton.frame = CGRect(x: content.maxX - side - margin, y: content.maxY - side - margin, width: side, height: side)
            let keySide = Self.keyboardButtonSide
            keyboardButton.frame = CGRect(x: bounds.maxX - max(WitermMetrics.Space.l, safeAreaInsets.right) - keySide,
                                          y: content.maxY + WitermMetrics.Space.s, width: keySide, height: keySide)
            layoutSizeReadout()
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
            #if DEBUG
            countProbedGrid()
            #endif
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
            // A pinch sets the size itself; SwiftUI's update with the saved
            // size then lands within a rounding error of it.
            guard abs(terminal.font.pointSize - size) > 0.01 else { return }
            #if DEBUG
            defer { probePinchSettled(font: true) }
            #endif
            // SwiftTerm's font setter resizes from the current frame and then
            // soft-resets the terminal, clearing the program's modes; with no
            // frame it changes only the cells. A fixed grid must keep its
            // rows/columns while its physical cell size changes.
            terminal.frame = .zero
            terminal.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            if let grid = fixedGrid {
                preserveGrid(grid)
                terminal.frame = fixedGridFrame()
            } else {
                // SwiftTerm refits its grid in layout only when its size
                // differs from the last layout's, so getting the same frame
                // back kept the old columns and rows. Lay it out once with no
                // size: the next layout fits whole cells of the new size and
                // tells the host, through SwiftTerm's own resize.
                terminal.layoutIfNeeded()
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
            // The handles the Metal trial draws follow the tint.
            terminal.updateMetalHandles()
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
            #if DEBUG
            if motionLink != nil { motion.readings += 1 }
            #endif
            let visible = terminal.convert(contentBounds, from: self).intersection(terminal.bounds)
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
                readingView.accessibilityLabel = base + String(format: " | cols=%d grids=%d rows=%d yDisp=%d pos=%.3f page=%d..<%d cell=%.3f frameH=%.2f boundsH=%.2f offset=%.2f content=%.2f mem=%.1f",
                    core.cols, probeGridChanges, core.rows, core.getTopVisibleRow(), terminal.scrollPosition, page.rows.lowerBound, page.rows.upperBound,
                    cellSize.height, terminal.frame.height, bounds.height, terminal.contentOffset.y, terminal.contentSize.height,
                    Self.footprintMB()) + String(format: " burst=%.3f", terminal.probeBurst.last - terminal.probeBurst.start)
                    + probeKeyboardDiagnostics()
                    + " motion=" + motionReport + " settle=" + pinchSettle + " lift=" + pinchLift
                    + " events=" + Self.probeEvents.joined(separator: ",")
                    + " gridlog=" + probeGridLog.joined(separator: ">")
                    + probeSelection()
                    + (terminal.isUsingMetalRenderer ? " renderer=metal" : " renderer=coretext")
                    + probeGridFit()
            }
            #endif
        }

        #if DEBUG
        /// UI tests that measure layout read the grid's numbers from the label.
        private static let layoutProbe = ProcessInfo.processInfo.arguments.contains("--witerm-ui-test-layout-probe")
        /// How many times layout changed the grid, so a test can tell one
        /// resize from several on the way to the same size.
        private var probeGridChanges = 0
        private var probeLastGrid: (columns: Int, rows: Int)?
        /// The last few grids layout went through, oldest first.
        private var probeGridLog: [String] = []
        private var probeLastGridTime = CACurrentMediaTime()

        /// How many characters are selected, and where the handle knobs are
        /// in the window, for tests that drag them.
        private func probeSelection() -> String {
            let selected = terminal.selection.active ? terminal.selection.getSelectedText().count : 0
            guard let knobs = terminal.selectionKnobs() else { return " sel=\(selected) knobs=none" }
            let start = terminal.convert(knobs.start, to: nil), end = terminal.convert(knobs.end, to: nil)
            return " sel=\(selected)" + String(format: " knobs=%.1f,%.1f,%.1f,%.1f", start.x, start.y, end.x, end.y)
        }

        /// Whether the grid fills the text area: the rows that fit it, and
        /// the blank height under the grid (or the part of it below the area).
        private func probeGridFit() -> String {
            let shown = scroll.bounds.height, grid = terminal.frame.height
            var line = String(format: " mode=%@ fitRows=%d gap=%.1f overflow=%.1f", mode == .view ? "view" : "control",
                              fitGrid.rows, max(0, shown - grid), max(0, grid - shown))
            if RemoteFixture.isActive { line += " links=\(FixtureMac.shared.opened)" }
            return line
        }

        /// The keyboard's space and where the key row is, in screen points.
        private func probeKeyboardDiagnostics() -> String {
            func describe(_ rect: CGRect) -> String { String(format: "%.0f,%.0f,%.0f,%.0f", rect.minX, rect.minY, rect.width, rect.height) }
            var parts = [String(format: "overlap=%.1f", keyboardOverlap)]
            if let window, let screen = window.windowScene?.screen {
                parts.append("screen=" + describe(screen.coordinateSpace.bounds))
                parts.append("surface=" + describe(convert(bounds, to: screen.coordinateSpace)))
                if let row = terminal.inputAccessoryView, row.window != nil {
                    parts.append("keyRow=" + describe(row.convert(row.bounds, to: screen.coordinateSpace)))
                }
            }
            return " kbdiag=[" + parts.joined(separator: " ") + "]"
        }

        private func countProbedGrid() {
            guard Self.layoutProbe else { return }
            let grid = (columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
            if let last = probeLastGrid, last != grid {
                probeGridChanges += 1
                // Each grid with the milliseconds since the one before it.
                let now = CACurrentMediaTime()
                let gap = Int(((now - probeLastGridTime) * 1000).rounded())
                probeLastGridTime = now
                probeGridLog = Array((probeGridLog + ["\(grid.columns)x\(grid.rows)+\(gap)"]).suffix(6))
                Self.probeEvent("g\(grid.columns)x\(grid.rows)")
                probePinchSettled(font: false)
            }
            probeLastGrid = grid
        }

        /// Full layout passes, for tests.
        private(set) var fullLayouts = 0

        // MARK: Motion probe

        /// Frame pacing and main-thread work while the view scrolls or is
        /// pinched, measured from the first movement until 0.4 s after the
        /// last, for UI tests that measure smoothness. A display link runs
        /// only then, so XCTest still sees the app idle between gestures.
        private struct MotionStats {
            var frames = 0, hitches = 0, worst = 0.0, nominal = 0.0
            var draws = 0, drawTotal = 0.0, drawWorst = 0.0
            var layouts = 0, layoutTotal = 0.0, readings = 0
            var pinchSteps = 0, pinchStepWorst = 0.0
            /// Main-thread busy time between frames (everything the run loop
            /// did: output parsing, layout, drawing, Core Animation's commit
            /// with Core Graphics' rasterizing, Metal's encoding), and the
            /// drawing the probe times, per frame.
            var busy: [Double] = [], draw: [Double] = []
        }
        private var motionLink: CADisplayLink?
        private var motionLast: CFTimeInterval = 0
        private var motionAt: CFTimeInterval = 0
        private var motion = MotionStats()
        private var motionReport = ""
        private var pinchEndedAt: CFTimeInterval?
        private var pinchSettle = ""
        /// Run-loop observers for when the main thread wakes and sleeps.
        /// (Bracketing Core Animation's commit with observers either side of
        /// its order measured nothing on iOS 27; Time Profiler splits it.)
        private var busyObservers: [CFRunLoopObserver] = []
        private var awakeSince: CFTimeInterval?
        private var busyThisFrame = 0.0, drawThisFrame = 0.0

        func probeMotion() {
            guard Self.layoutProbe else { return }
            motionAt = CACurrentMediaTime()
            guard motionLink == nil else { return }
            motion = MotionStats()
            motionLast = 0
            let link = CADisplayLink(target: self, selector: #selector(probeFrame(_:)))
            link.add(to: .main, forMode: .common)
            motionLink = link
            startBusyObservers()
        }

        private func startBusyObservers() {
            busyThisFrame = 0; drawThisFrame = 0
            awakeSince = CACurrentMediaTime()
            func observe(_ activities: CFRunLoopActivity, _ order: CFIndex, _ body: @escaping @MainActor (CFRunLoopActivity) -> Void) {
                let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, order) { _, activity in
                    MainActor.assumeIsolated { body(activity) }
                }
                if let observer {
                    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                    busyObservers.append(observer)
                }
            }
            // First after waking, last before sleeping: the run loop's awake time.
            observe(.afterWaiting, CFIndex.min) { [weak self] _ in self?.awakeSince = CACurrentMediaTime() }
            observe(.beforeWaiting, CFIndex.max) { [weak self] _ in
                guard let self, let since = self.awakeSince else { return }
                self.busyThisFrame += CACurrentMediaTime() - since
                self.awakeSince = nil
            }
        }

        private func stopBusyObservers() {
            for observer in busyObservers { CFRunLoopObserverInvalidate(observer) }
            busyObservers = []
        }

        /// Ends the frame's busy time at the display link, which runs while awake.
        private func closeBusyFrame() {
            let now = CACurrentMediaTime()
            if let since = awakeSince { busyThisFrame += now - since; awakeSince = now }
            motion.busy.append(busyThisFrame)
            motion.draw.append(drawThisFrame)
            busyThisFrame = 0; drawThisFrame = 0
        }

        private static func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }

        @objc private func probeFrame(_ link: CADisplayLink) {
            if motionLast > 0 {
                let delta = link.timestamp - motionLast
                motion.frames += 1
                motion.worst = max(motion.worst, delta)
                motion.nominal = link.duration
                if delta > link.duration * 1.5 { motion.hitches += 1 }
                closeBusyFrame()
            } else {
                busyThisFrame = 0; drawThisFrame = 0
            }
            motionLast = link.timestamp
            guard link.timestamp - motionAt > 0.4, pinchStartSize == nil else { return }
            link.invalidate()
            motionLink = nil
            stopBusyObservers()
            let m = motion
            func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) * 1000 }
            motionReport = String(format: "frames:%d,hitches:%d,worstms:%.1f,nominalms:%.1f,draws:%d,drawms:%.2f,drawworstms:%.2f,layouts:%d,layoutms:%.2f,readings:%d,pinchsteps:%d,pinchstepworstms:%.2f",
                                  m.frames, m.hitches, m.worst * 1000, m.nominal * 1000, m.draws, m.draws > 0 ? m.drawTotal / Double(m.draws) * 1000 : 0,
                                  m.drawWorst * 1000, m.layouts, m.layouts > 0 ? m.layoutTotal / Double(m.layouts) * 1000 : 0, m.readings,
                                  m.pinchSteps, m.pinchStepWorst * 1000)
                + String(format: ",busyms:%.2f,busyp95ms:%.2f,busyworstms:%.2f,drawframems:%.2f,drawframep95ms:%.2f",
                         mean(m.busy), Self.percentile(m.busy, 0.95) * 1000, (m.busy.max() ?? 0) * 1000,
                         mean(m.draw), Self.percentile(m.draw, 0.95) * 1000)
            refreshReadingDocument()
        }

        private func probeDraw(_ seconds: CFTimeInterval) {
            guard motionLink != nil else { return }
            motion.draws += 1
            drawThisFrame += seconds
            motion.drawTotal += seconds
            motion.drawWorst = max(motion.drawWorst, seconds)
        }

        private func probeLayout(_ seconds: CFTimeInterval) {
            guard motionLink != nil else { return }
            motion.layouts += 1
            motion.layoutTotal += seconds
        }

        private func probePinchStep(_ seconds: CFTimeInterval) {
            motion.pinchSteps += 1
            motion.pinchStepWorst = max(motion.pinchStepWorst, seconds)
        }

        /// From the fingers lifting to the new font, and to the new grid.
        private func probePinchSettled(font: Bool) {
            guard let ended = pinchEndedAt else { return }
            let ms = Int(((CACurrentMediaTime() - ended) * 1000).rounded())
            if font { pinchSettle = "font:\(ms)" } else {
                pinchSettle += ",grid:\(ms)"
                pinchEndedAt = nil
            }
        }

        static var probeEvents: [String] = []
        static var probeEventTime = CACurrentMediaTime()
        static func probeEvent(_ name: String) {
            guard layoutProbe else { return }
            let now = CACurrentMediaTime()
            probeEvents = Array((probeEvents + ["\(name)+\(Int(((now - probeEventTime) * 1000).rounded()))"]).suffix(16))
            probeEventTime = now
        }

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
            #if DEBUG
            // UI tests on a simulator with a hardware keyboard: a plain view
            // the software keyboard's size takes its place, so the keyboard's
            // space, its notifications and the key row on top behave as on
            // a phone (`-witerm.debug.softwareKeyboard YES`).
            if Self.standInKeyboard { inputView = StandInKeyboard() }
            #endif
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
            // The system's duration (0.35 s turned a finger that rested a
            // moment before swiping into a selection), and never from a touch
            // that only stops a fling.
            press.minimumPressDuration = Self.selectionPressDuration
            press.delegate = pressGate
            addGestureRecognizer(press)
            selectionPressRecognizer = press
            let tap = UITapGestureRecognizer(target: self, action: #selector(focusTap(_:)))
            for recognizer in gestureRecognizers ?? [] {
                if let other = recognizer as? UITapGestureRecognizer, other.numberOfTapsRequired == 2 { tap.require(toFail: other) }
            }
            addGestureRecognizer(tap)
            focusTapRecognizer = tap
            let menu = UIEditMenuInteraction(delegate: self)
            addInteraction(menu)
            editMenu = menu
            let handles = HandleDrag(target: self, action: #selector(dragHandle(_:)))
            handles.maximumNumberOfTouches = 1
            addGestureRecognizer(handles)
            // Scrolling waits only until a drag is known not to start on a handle.
            panGestureRecognizer.require(toFail: handles)
            handleRecognizer = handles
            let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheelDragged(_:)))
            wheel.maximumNumberOfTouches = 1
            wheel.require(toFail: handles)
            addGestureRecognizer(wheel)
            wheelRecognizer = wheel
            allowMouseReporting = acceptsInput && passesMouseToPrograms
            #if DEBUG
            observeGestures()
            #endif
        }

        // MARK: Mouse wheel

        /// Drags one finger for a program that asked for the mouse.
        private(set) var wheelRecognizer: UIPanGestureRecognizer?
        /// Points dragged that haven't made a whole row yet.
        private var wheelRemainder: CGFloat = 0
        private var wheelPoint: CGPoint = .zero
        private var wheelMomentum: CADisplayLink?
        private var wheelVelocity: CGFloat = 0

        /// The program asked for the mouse (tmux `mouse on`, vim `mouse=a`,
        /// htop, less with the mouse) and this view controls the terminal.
        var reportsMouse: Bool { allowMouseReporting && getTerminal().mouseMode != .off }

        /// Programs that ask for the mouse get wheel steps and clicks (SSH).
        /// Off for paired terminals, whose stream comes from Witerm's own
        /// tmux: there a swipe scrolls Witerm's scrollback and a tap stays a
        /// tap, as when watching.
        var passesMouseToPrograms = true {
            didSet { allowMouseReporting = acceptsInput && passesMouseToPrograms }
        }

        /// A one-finger swipe never sends a button drag, which tmux and vim
        /// turn into their own text selection: for a program that asked for
        /// the mouse it sends wheel steps at the finger, one per row dragged,
        /// and coasts like a scroll view after a fling, so the program scrolls
        /// its own view. Without the mouse it scrolls Witerm's scrollback.
        @objc private func wheelDragged(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                stopWheelMomentum()
                wheelRemainder = 0
                wheelPoint = pan.location(in: self)
                wheel(by: pan.translation(in: self).y)
                pan.setTranslation(.zero, in: self)
            case .changed:
                wheel(by: pan.translation(in: self).y)
                pan.setTranslation(.zero, in: self)
            case .ended:
                let velocity = pan.velocity(in: self).y
                if abs(velocity) > Self.wheelStopSpeed { startWheelMomentum(velocity) }
            default: break
            }
        }

        /// Below this many points a second a fling's coast stops.
        private static let wheelStopSpeed: CGFloat = 40

        /// Sends a wheel step per whole row of `points` dragged: down (the
        /// content following the finger toward older lines) is wheel up.
        func wheel(by points: CGFloat) {
            guard reportsMouse else {
                stopWheelMomentum()
                return
            }
            let height = cell.height
            guard height > 0 else { return }
            wheelRemainder += points
            let rows = Int(wheelRemainder / height)
            guard rows != 0 else { return }
            wheelRemainder -= CGFloat(rows) * height
            let core = getTerminal(), cell = cell
            let screen = CGPoint(x: wheelPoint.x - bounds.minX, y: wheelPoint.y - bounds.minY)
            let column = min(max(0, Int(screen.x / max(1, cell.width))), core.cols - 1)
            let row = min(max(0, Int(screen.y / max(1, height))), core.rows - 1)
            let flags = core.encodeButton(button: rows > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
            // At most a screenful per step, however fast the finger moved.
            for _ in 0..<min(abs(rows), core.rows) {
                core.sendEvent(buttonFlags: flags, x: column, y: row, pixelX: Int(screen.x), pixelY: Int(screen.y))
            }
        }

        private func startWheelMomentum(_ velocity: CGFloat) {
            wheelVelocity = velocity
            guard wheelMomentum == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(wheelCoast(_:)))
            link.add(to: .main, forMode: .common)
            wheelMomentum = link
        }

        /// UIScrollView's normal deceleration (0.998 per millisecond).
        @objc private func wheelCoast(_ link: CADisplayLink) {
            let elapsed = max(0, link.targetTimestamp - link.timestamp)
            wheel(by: wheelVelocity * CGFloat(elapsed))
            wheelVelocity *= CGFloat(pow(0.998, elapsed * 1000))
            if abs(wheelVelocity) < Self.wheelStopSpeed { stopWheelMomentum() }
        }

        /// Stops a coast; `true` when one was running (the touch only stopped it).
        @discardableResult func stopWheelMomentum() -> Bool {
            guard let link = wheelMomentum else { return false }
            link.invalidate()
            wheelMomentum = nil
            return true
        }

        /// The cell size, as the renderer lays out its rows.
        private var cell: CGSize {
            let core = getTerminal(), frame = getOptimalFrameSize()
            return CGSize(width: frame.width / CGFloat(max(1, core.cols)), height: frame.height / CGFloat(max(1, core.rows)))
        }

        /// UIKit's own long-press duration.
        static let selectionPressDuration: TimeInterval = 0.5
        /// A handle's touch target: a 44 pt square centered on its knob.
        static let handleTarget: CGFloat = 44

        /// The selection's end that a touch at `point` grabs: only within the
        /// 44 pt square centered on a handle's knob (the start's hangs above
        /// its first character, the end's below its last). A touch on the
        /// text, even next to a handle, scrolls; the target used to reach
        /// 22 pt plus half a row from the text's corner, so a swipe that
        /// started on the selected row or the one under it moved the
        /// selection instead.
        func selectionHandle(near point: CGPoint) -> SelectionHandle? {
            guard let knobs = selectionKnobs() else { return nil }
            func distance(_ knob: CGPoint) -> CGFloat? {
                let half = Self.handleTarget / 2
                guard abs(point.x - knob.x) <= half, abs(point.y - knob.y) <= half else { return nil }
                return hypot(point.x - knob.x, point.y - knob.y)
            }
            switch (distance(knobs.start), distance(knobs.end)) {
            case let (start?, end?): return start <= end ? .start : .end
            case (.some, nil): return .start
            case (nil, .some): return .end
            case (nil, nil): return nil
            }
        }

        enum SelectionHandle { case start, end }

        private var selectionPressRecognizer: UILongPressGestureRecognizer?
        private lazy var pressGate = SelectionPressGate(terminal: self)
        /// From where the finger took a handle to the middle of the character
        /// at that end, so the end doesn't jump to the row the knob hangs in.
        private var handleGrabOffset = CGVector.zero
        /// A scroll hid the edit menu; it returns when the scroll stops.
        private var editMenuHiddenForScroll = false

        /// How far SwiftTerm draws each handle's knob (a 12 pt dot) from the
        /// selection's corner: above the first character, below the last.
        static let knobRadius: CGFloat = 6

        /// The centers of the selection's two handle knobs, in this view's
        /// coordinates (which scroll with the output).
        func selectionKnobs() -> (start: CGPoint, end: CGPoint)? {
            guard selection.active else { return nil }
            let cell = cell
            let (first, last) = Position.compare(selection.start, selection.end) == .before
                ? (selection.start, selection.end) : (selection.end, selection.start)
            return (CGPoint(x: CGFloat(first.col) * cell.width, y: CGFloat(first.row) * cell.height - Self.knobRadius),
                    CGPoint(x: CGFloat(last.col) * cell.width, y: CGFloat(last.row + 1) * cell.height + Self.knobRadius))
        }

        @objc private func dragHandle(_ pan: UIPanGestureRecognizer) {
            let point = pan.location(in: self)
            switch pan.state {
            case .began:
                let touched = Self.touchDown(of: pan, in: self)
                guard let handle = selectionHandle(near: touched), let knobs = selectionKnobs() else { return }
                editMenu?.dismissMenu()
                let (first, last) = Position.compare(selection.start, selection.end) == .before
                    ? (selection.start, selection.end) : (selection.end, selection.start)
                // The other end stays put while this one follows the finger.
                selection.pivot = handle == .start ? last : first
                // The middle of the first or last selected character.
                let cell = cell, rise = Self.knobRadius + cell.height / 2
                let anchor = handle == .start ? CGPoint(x: knobs.start.x + cell.width / 2, y: knobs.start.y + rise)
                    : CGPoint(x: knobs.end.x - cell.width / 2, y: knobs.end.y - rise)
                handleGrabOffset = CGVector(dx: anchor.x - touched.x, dy: anchor.y - touched.y)
                UISelectionFeedbackGenerator().selectionChanged()
            case .changed:
                extendSelection(to: CGPoint(x: point.x + handleGrabOffset.dx, y: point.y + handleGrabOffset.dy))
            case .ended, .cancelled:
                presentSelectionMenu(at: point)
            default: break
            }
        }

        /// Where a drag's finger came down. A drag is known only after it has
        /// moved about 10 pt, and testing where the finger was by then let a
        /// swipe toward a handle take it from farther away than one moving off.
        /// (The pan's translation is still zero when it asks to begin.)
        static func touchDown(of pan: UIPanGestureRecognizer, in view: UIView) -> CGPoint {
            guard let down = (pan as? HandleDrag)?.touchDown, let source = pan.view else { return pan.location(in: view) }
            return source.convert(down, to: view)
        }

        /// A pan that remembers where its first finger came down.
        final class HandleDrag: UIPanGestureRecognizer {
            private(set) var touchDown: CGPoint?

            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
                if touchDown == nil, let touch = touches.first { touchDown = touch.location(in: view) }
                super.touchesBegan(touches, with: event)
            }

            override func reset() {
                super.reset()
                touchDown = nil
            }
        }

        /// The selected rows, with the handles' knobs, in this view's coordinates.
        func selectionBounds() -> CGRect? {
            guard let knobs = selectionKnobs() else { return nil }
            let top = knobs.start.y - Self.knobRadius, bottom = knobs.end.y + Self.knobRadius
            let width = cell.width * CGFloat(getTerminal().cols)
            // One row spans its two ends; more rows span the grid's width.
            let oneRow = bottom - top < cell.height * 1.5 + Self.knobRadius * 4
            let left = oneRow ? min(knobs.start.x, knobs.end.x) : 0, right = oneRow ? max(knobs.start.x, knobs.end.x) : width
            return CGRect(x: left - Self.knobRadius, y: top, width: right - left + Self.knobRadius * 2, height: bottom - top)
        }

        /// Shows Copy and the other actions beside the selection, not over
        /// it or its handles, while any of it is on screen.
        func presentSelectionMenu(at point: CGPoint? = nil) {
            guard selection.active, let rect = selectionBounds()?.intersection(bounds), !rect.isNull, !rect.isEmpty else { return }
            let source = point.map { rect.contains($0) ? $0 : CGPoint(x: rect.midX, y: rect.midY) } ?? CGPoint(x: rect.midX, y: rect.midY)
            editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            guard selection.active, let rect = selectionBounds()?.intersection(bounds), !rect.isNull, !rect.isEmpty else { return .null }
            return rect
        }

        /// A scroll starting never becomes a selection, and hides the edit
        /// menu until it stops, as in other iOS text; the selection stays.
        /// (The touch that starts it has usually closed the menu already.)
        func scrollWillBegin() {
            if let press = selectionPressRecognizer, press.state == .possible {
                press.isEnabled = false
                press.isEnabled = true
            }
            if selection.active {
                editMenuHiddenForScroll = true
                editMenu?.dismissMenu()
            }
        }

        func scrollDidStop() {
            guard editMenuHiddenForScroll else { return }
            editMenuHiddenForScroll = false
            presentSelectionMenu()
        }

        override func mouseModeChanged(source: Terminal) {
            super.mouseModeChanged(source: source)
            if source.mouseMode == .off { stopWheelMomentum() }
            #if DEBUG
            observeGestures()
            logGesture("mouseModeChanged", nil, mouseMode: source.mouseMode)
            #endif
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
                presentSelectionMenu(at: point)
            default: break
            }
        }

        /// The focus tap only clears a selection or brings up the keyboard;
        /// with the keyboard up, SwiftTerm's own tap handles links and mouse clicks.
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            let begins = shouldBegin(recognizer)
            #if DEBUG
            logGesture("shouldBegin=\(begins)", recognizer)
            #endif
            return begins
        }

        private func shouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer === focusTapRecognizer { return selection.active || (acceptsInput && !isFirstResponder) }
            if let pan = recognizer as? UIPanGestureRecognizer, pan === handleRecognizer {
                return selectionHandle(near: Self.touchDown(of: pan, in: self)) != nil
            }
            if recognizer === selectionPressRecognizer { return !isDragging && !isDecelerating }
            // For a program that asked for the mouse a swipe is the wheel;
            // otherwise it scrolls Witerm's scrollback.
            if recognizer === wheelRecognizer { return reportsMouse }
            if recognizer === panGestureRecognizer, reportsMouse { return false }
            // SwiftTerm's other drags never begin: its selection drag (after
            // a double tap) would move the selection's end from anywhere, and
            // its mouse drag sent a held button that tmux and vim turned into
            // their own selection ("swiping selects text" while typing).
            if recognizer is UIPanGestureRecognizer, recognizer !== panGestureRecognizer { return false }
            // Only Witerm's long press selects: SwiftTerm's (disabled) and any
            // the system adds to a text-input view while it has the keyboard.
            if recognizer is UILongPressGestureRecognizer { return false }
            return super.gestureRecognizerShouldBegin(recognizer)
        }

        #if DEBUG
        /// DEBUG only: each gesture on the terminal (which one, whether it
        /// may begin, the mouse and focus state), never terminal content.
        /// `log stream --predicate 'subsystem == "com.witerm" AND category == "terminal-gestures"'`.
        private static let gestureLog = Logger(subsystem: "com.witerm", category: "terminal-gestures")
        private var observedGestures = Set<ObjectIdentifier>()

        private func gestureName(_ recognizer: UIGestureRecognizer?) -> String {
            guard let recognizer else { return "-" }
            let role = recognizer === panGestureRecognizer ? "scroll" : recognizer === wheelRecognizer ? "wheel"
                : recognizer === handleRecognizer ? "handle" : recognizer === selectionPressRecognizer ? "selectionPress"
                : recognizer === focusTapRecognizer ? "focusTap" : "other"
            return "\(type(of: recognizer))[\(role)]"
        }

        func logGesture(_ event: String, _ recognizer: UIGestureRecognizer?, mouseMode: Terminal.MouseMode? = nil) {
            let state = "mouseMode=\(mouseMode ?? getTerminal().mouseMode) allowMouseReporting=\(allowMouseReporting) firstResponder=\(isFirstResponder) acceptsInput=\(acceptsInput) selection=\(selection?.active ?? false)"
            Self.gestureLog.notice("\(event, privacy: .public) \(self.gestureName(recognizer), privacy: .public) \(state, privacy: .public)")
        }

        /// Follows every recognizer on the view, SwiftTerm's and the system's included.
        func observeGestures() {
            for recognizer in gestureRecognizers ?? [] where observedGestures.insert(ObjectIdentifier(recognizer)).inserted {
                recognizer.addTarget(self, action: #selector(gestureStateChanged(_:)))
            }
        }

        @objc private func gestureStateChanged(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began: logGesture("began", recognizer)
            case .ended: logGesture("ended", recognizer)
            case .cancelled: logGesture("cancelled", recognizer)
            default: break
            }
        }

        /// When a selection starts, which recognizers were running, here and on the window.
        func logSelectionStarted(mouseMode: Terminal.MouseMode) {
            let running = ((gestureRecognizers ?? []) + (window?.gestureRecognizers ?? []))
                .filter { $0.state == .began || $0.state == .changed }.map(gestureName).joined(separator: ",")
            logGesture("selectionStarted running=[\(running)]", nil, mouseMode: mouseMode)
        }
        #endif

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
        #if DEBUG
        static let standInKeyboard = UserDefaults.standard.bool(forKey: "witerm.debug.softwareKeyboard")
        #endif

        /// Brings up the keyboard the first time this terminal is on screen
        /// while it accepts typing, so a new connection is ready to type into.
        /// Set once per connection; showing the terminal again keeps whatever
        /// the person chose since.
        var focusesWhenShown = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopWheelMomentum() }
            #if DEBUG || WITERM_RENDERER_TRIAL
            // SwiftTerm's Metal renderer attaches once the view is in a window.
            if window != nil, RendererTrial.usesMetal, !isUsingMetalRenderer { startMetalTrial() }
            #endif
            guard window != nil, focusesWhenShown, acceptsInput else { return }
            focusesWhenShown = false
            // After this layout pass, like the keyboard button's request.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.acceptsInput, !self.isFirstResponder else { return }
                _ = self.becomeFirstResponder()
            }
        }

        override func becomeFirstResponder() -> Bool {
            if !isFirstResponder { postFocus(true, will: true) }
            let became = super.becomeFirstResponder()
            if became { postFocus(true) } else if !isFirstResponder { postFocus(false) }
            #if DEBUG
            // The system may add text-input gestures to a view with the keyboard.
            DispatchQueue.main.async { [weak self] in
                self?.observeGestures()
                self?.logGesture("becameFirstResponder=\(became) recognizers=\(self?.gestureRecognizers?.count ?? 0)", nil)
            }
            #endif
            return became
        }

        override func resignFirstResponder() -> Bool {
            if isFirstResponder { postFocus(false, will: true) }
            let resigned = super.resignFirstResponder()
            if resigned { postFocus(false) } else if isFirstResponder { postFocus(true) }
            return resigned
        }

        /// While the navigation bar is hidden for typing, the key row ends
        /// with Hide Keyboard and these actions; `nil` puts it back.
        func setBarActions(_ actions: AnyView?) {
            (inputAccessoryView as? MobileTerminalAccessory)?.setBarActions(actions)
        }

        /// Lets the keyboard button say whether it shows or hides the keyboard.
        /// `will` comes just before the change, so a layout that depends on
        /// it (the bar hidden while typing in landscape) lands in the same
        /// pass as the keyboard's, and the grid is resized once.
        private func postFocus(_ focused: Bool, will: Bool = false) {
            #if DEBUG
            TerminalSurface.probeEvent((focused ? "f+" : "f-") + (will ? "w" : ""))
            #endif
            NotificationCenter.default.post(name: will ? .witermTerminalFocusWillChange : .witermTerminalFocusChanged,
                                            object: self, userInfo: ["focused": focused])
        }

        func disableInput() {
            stopWheelMomentum()
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
        /// The key row was laid out, or came or went: the keyboard's space
        /// may have changed (rotating with only the key row up reports
        /// nothing else).
        var keyRowMoved: (() -> Void)?
        private var readingRefreshQueued = false
        private var readingRefreshHasOutput = false
        private var readingRefreshDeferred = false
        /// From a finger starting a scroll until it (and its fling) stops.
        private var touchScrolling = false

        /// Rebuilds the reading page (what VoiceOver reads) once per run-loop
        /// turn, however many output chunks or scroll steps arrived in it,
        /// rather than once per chunk while long output streams in.
        func requestReadingRefresh(output: Bool) {
            if output { scrollStateChanged?(true) }
            #if DEBUG
            if output { probeOutputArrived() }
            #endif
            readingRefreshHasOutput = readingRefreshHasOutput || output
            // While a finger scrolls the view (or its fling coasts) and
            // VoiceOver isn't running, nothing reads the page, and it was
            // rebuilt every frame; it catches up once the scroll stops. (A
            // flag of our own: asking UIScrollView, per output chunk, walks
            // the focus system.)
            if touchScrolling, !UIAccessibility.isVoiceOverRunning {
                if !readingRefreshDeferred { confirmScrollingLater() }
                readingRefreshDeferred = true
                return
            }
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
        /// How long each frame's drawing took, for the motion probe.
        var drawObserver: ((CFTimeInterval) -> Void)?

        override func draw(_ layer: CALayer, in ctx: CGContext) {
            // With Metal, the Metal view's frames are timed instead.
            guard let drawObserver, !isUsingMetalRenderer else { return super.draw(layer, in: ctx) }
            let started = CACurrentMediaTime()
            super.draw(layer, in: ctx)
            drawObserver(CACurrentMediaTime() - started)
        }

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
        @objc func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollEnded() }

        @objc func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { scrollEnded() }
        }

        /// Also brings the reading page up to date after a touch scroll.
        @objc func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            touchScrolling = true
            scrollWillBegin()
        }

        /// A scroll stopped another way (such as Jump to Latest during a
        /// fling) may not say it ended; check twice a second while deferred.
        private func confirmScrollingLater() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.touchScrolling, self.readingRefreshDeferred else { return }
                if self.isTracking || self.isDecelerating { self.confirmScrollingLater() } else { self.scrollEnded() }
            }
        }

        /// Also brings the reading page up to date after a touch scroll.
        private func scrollEnded() {
            touchScrolling = false
            snapToBottomIfFollowing()
            scrollDidStop()
            guard readingRefreshDeferred else { return }
            readingRefreshDeferred = false
            requestReadingRefresh(output: false)
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
                    alignMetalRows()
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
            #if DEBUG
            // Delegate callbacks can come while SwiftTerm is still setting up,
            // before its selection and terminal exist: log from `source`.
            let active = selection?.active ?? false
            if active != loggedSelectionActive {
                loggedSelectionActive = active
                if active { logSelectionStarted(mouseMode: source.mouseMode) } else { logGesture("selectionEnded", nil, mouseMode: source.mouseMode) }
            }
            #endif
            updateMetalHandles()
            readingChanged?(false)
        }

        #if DEBUG
        private var loggedSelectionActive = false
        #endif

        // MARK: Renderer trial

        /// SwiftTerm's Metal renderer draws no selection handles (its Core
        /// Graphics path draws them with the text), so Witerm draws the same
        /// line and 12 pt knob over it, in the handle color.
        private var metalHandles: [CAShapeLayer] = []
        /// Witerm's fixes for the Metal renderer are on (off with `metalRaw`).
        private var fixesMetal = false
        private weak var trialMetalView: MTKView?

        override func layoutSubviews() {
            super.layoutSubviews()
            alignMetalRows()
            updateMetalHandles()
        }

        /// SwiftTerm 1.19's Metal renderer draws whole rows from the top of
        /// its view, starting at the first row the scroll offset reaches, and
        /// ignores the part of that row scrolled past: the text sat up to a
        /// row lower than where touches, selection and its handles put it,
        /// and moved in whole-row steps while the content scrolled smoothly.
        /// Moving its view up by that part puts every row where it belongs.
        /// (The renderer still can't draw below its first row plus the view's
        /// height, so up to a row at the bottom stays blank, the prompt's foot
        /// included; that needs SwiftTerm itself.) Under it, a plain view in
        /// the terminal's background covers what the Core Graphics layer
        /// leaves there.
        private func alignMetalRows() {
            guard fixesMetal, let metalView = trialMetalView else { return }
            if metalBackdrop.superview !== self { insertSubview(metalBackdrop, belowSubview: metalView) }
            if metalBackdrop.frame != bounds { metalBackdrop.frame = bounds }
            let height = cell.height
            guard height > 0 else { return }
            // SwiftTerm's content is its lines times the row height, as the renderer counts them.
            let offset = min(max(0, contentOffset.y), max(0, contentSize.height - bounds.height))
            let part = offset - (offset / height).rounded(.down) * height
            let origin = CGPoint(x: bounds.minX, y: bounds.minY - part)
            if metalView.frame.origin != origin { metalView.frame.origin = origin }
        }

        private let metalBackdrop: UIView = {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            return view
        }()

        func updateMetalHandles() {
            guard isUsingMetalRenderer, fixesMetal else { return }
            metalBackdrop.backgroundColor = nativeBackgroundColor
            if metalHandles.isEmpty {
                metalHandles = [CAShapeLayer(), CAShapeLayer()]
                for handle in metalHandles {
                    handle.lineWidth = 2
                    layer.addSublayer(handle)
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard let knobs = selectionKnobs() else {
                for handle in metalHandles where !handle.isHidden { handle.isHidden = true }
                return
            }
            let rise = Self.knobRadius + cell.height
            let color = selectionHandleColor.resolvedColor(with: traitCollection).cgColor
            for (index, knob) in [knobs.start, knobs.end].enumerated() {
                let path = CGMutablePath()
                // The start's line runs down from its knob, the end's up to it.
                path.move(to: knob)
                path.addLine(to: CGPoint(x: knob.x, y: knob.y + (index == 0 ? rise : -rise)))
                path.addEllipse(in: CGRect(x: knob.x - Self.knobRadius, y: knob.y - Self.knobRadius,
                                           width: Self.knobRadius * 2, height: Self.knobRadius * 2))
                let handle = metalHandles[index]
                handle.path = path
                handle.fillColor = color
                handle.strokeColor = color
                handle.isHidden = false
                // Above the Metal view, which SwiftTerm may add after us.
                handle.zPosition = 1
            }
        }

        #if DEBUG || WITERM_RENDERER_TRIAL
        private func startMetalTrial() {
            do { try setUseMetal(true) } catch { return }
            trialMetalView = subviews.first(where: { $0 is MTKView }) as? MTKView
            #if DEBUG
            if let metal = trialMetalView, let renderer = metal.delegate {
                let probe = MetalDrawProbe(renderer: renderer)
                probe.observer = { [weak self] in self?.drawObserver?($0) }
                metalProbe = probe
                metal.delegate = probe
            }
            #endif
            fixesMetal = !RendererTrial.raw
            alignMetalRows()
            updateMetalHandles()
        }
        #endif

        #if DEBUG
        private var metalProbe: MetalDrawProbe?
        #endif
    }

    #if DEBUG
    /// The software keyboard's stand-in for UI tests (see `standInKeyboard`):
    /// as tall as the iPhone's English keyboard with its suggestions bar.
    final class StandInKeyboard: UIInputView {
        init() {
            super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 336), inputViewStyle: .keyboard)
            allowsSelfSizing = true
            isAccessibilityElement = false
            accessibilityIdentifier = "standInKeyboard"
        }
        required init?(coder: NSCoder) { nil }
        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: traitCollection.verticalSizeClass == .compact ? 209 : 336)
        }
    }
    #endif

    #if DEBUG || WITERM_RENDERER_TRIAL
    /// Which renderer draws iOS terminals, for measuring only, never in
    /// product UI: launching with `-witerm.debug.renderer metal` selects
    /// SwiftTerm's Metal renderer; anything else keeps Core Graphics, the
    /// default. Debug builds only (or builds with `WITERM_RENDERER_TRIAL`).
    enum RendererTrial {
        static let usesMetal = UserDefaults.standard.string(forKey: "witerm.debug.renderer") == "metal"
        /// `-witerm.debug.metalRaw YES`: SwiftTerm's Metal renderer as it
        /// comes, without Witerm's handles and color refresh, for comparison.
        static let raw = UserDefaults.standard.bool(forKey: "witerm.debug.metalRaw")
    }
    #endif

    #if DEBUG
    /// Times the Metal renderer's frames (main-thread CPU: building rows and
    /// encoding; the GPU's own time isn't included) for the motion probe.
    @MainActor final class MetalDrawProbe: NSObject, MTKViewDelegate {
        private let renderer: any MTKViewDelegate
        var observer: ((CFTimeInterval) -> Void)?

        init(renderer: any MTKViewDelegate) { self.renderer = renderer }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.mtkView(view, drawableSizeWillChange: size)
        }

        func draw(in view: MTKView) {
            let started = CACurrentMediaTime()
            renderer.draw(in: view)
            observer?(CACurrentMediaTime() - started)
        }
    }
    #endif

    /// A touch that lands while the output is still moving (a fling's
    /// coast, here, in the grid's sideways scroll, or a program's wheel
    /// coast) only stops it, as elsewhere in iOS; resting there never
    /// starts a selection.
    @MainActor final class SelectionPressGate: NSObject, UIGestureRecognizerDelegate {
        private weak var terminal: TerminalInputView?

        init(terminal: TerminalInputView) { self.terminal = terminal }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let terminal else { return true }
            let coasting = terminal.stopWheelMomentum()
            return !coasting && !terminal.isDecelerating && (terminal.superview as? UIScrollView)?.isDecelerating != true
        }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private var keyboardRequest: Int
        private var keyboardGeneration: UInt64 = 0
        private weak var terminal: TerminalInputView?
        private var isInteractive: Bool
        private var attachment: any PairedTerminalLink
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

        init(attachment: any PairedTerminalLink, mode: LocalAttachmentMode, keyboardRequest: Int,
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
        // Coalesced, as for SSH: SwiftTerm reports these for every scroll
        // step and redrawn range, which rebuilt the reading page each time.
        func scrolled(source: TerminalView, position: Double) { (source as? TerminalInputView)?.requestReadingRefresh(output: false) }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { (source as? TerminalInputView)?.requestReadingRefresh(output: false) }
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
