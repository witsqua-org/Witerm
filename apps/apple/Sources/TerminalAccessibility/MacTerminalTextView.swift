#if os(macOS)
import AppKit
import SwiftTerm
import WitermCore

@MainActor final class MacTerminalTextView: TerminalView {
    private(set) var readingDocument = TerminalAXDocument.empty
    private var readingSelection: NSRange?
    private var readingFocused = false
    private var inputEnabled: Bool
    private var requestedInitialFocus = false
    private var lastAnnouncement = ContinuousClock.now
    var announceOutput = false
    var geometryChanged: ((LocalSessionInfo) -> Void)?
    var stopInput: (() -> Void)?

    init(mode: LocalAttachmentMode, columns: Int = 80, rows: Int = 24, fontSize: CGFloat = 14) {
        inputEnabled = mode == .control
        super.init(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                   options: TerminalOptions(cols: columns, rows: rows))
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityRoleDescription(String(localized: "Terminal Text", bundle: .main))
        setAccessibilityIdentifier("localTerminalSurface")
        setAccessibilityLabel(mode == .view ? String(localized: "Terminal, Watching", bundle: .main) : String(localized: "Terminal", bundle: .main))
        setAccessibilityHelp(String(localized: "Read by line, word or character. Text selection is only used for local reading.", bundle: .main))
        notifyUpdateChanges = true
        // Files dropped from Finder type their paths, as in Terminal.
        registerForDraggedTypes([.fileURL])
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Previous Page", bundle: .main)) { [weak self] in self?.pageReading(forward: false) ?? false },
            NSAccessibilityCustomAction(name: String(localized: "Next Page", bundle: .main)) { [weak self] in self?.pageReading(forward: true) ?? false },
            NSAccessibilityCustomAction(name: String(localized: "Pan Left", bundle: .main)) { [weak self] in self?.panReading(forward: false) ?? false },
            NSAccessibilityCustomAction(name: String(localized: "Pan Right", bundle: .main)) { [weak self] in self?.panReading(forward: true) ?? false },
            NSAccessibilityCustomAction(name: String(localized: "Terminal Cursor", bundle: .main)) { [weak self] in
                guard let self else { return false }
                self.scroll(toPosition: 1)
                self.refreshReadingDocument()
                guard let caret = self.readingDocument.caret else { return false }
                self.setAccessibilitySelectedTextRange(NSRange(location: caret, length: 0))
                return true
            }
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleInitialFocus()
    }

    override func layout() {
        super.layout()
        scheduleInitialFocus()
        refreshReadingDocument()
    }

    /// Whether the terminal takes keyboard focus the next time it is shown.
    /// On by default; the owner turns it off while a person browses the
    /// sidebar with the keyboard, so arrowing through sessions keeps focus there.
    var focusWhenShown: Bool {
        get { !requestedInitialFocus }
        set { requestedInitialFocus = !newValue }
    }

    /// Takes keyboard focus now, or as soon as the terminal is on screen and
    /// no sheet covers its window.
    func requestFocus() {
        requestedInitialFocus = false
        scheduleInitialFocus()
    }

    private func scheduleInitialFocus() {
        guard !requestedInitialFocus, inputEnabled, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        requestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in self?.focusWhenUncovered(attempts: 20) }
    }

    /// A sheet that is closing hands focus back to whatever had it before,
    /// so wait for it to finish rather than lose focus to it.
    private func focusWhenUncovered(attempts: Int) {
        guard inputEnabled, let window else { return }
        if window.attachedSheet != nil, attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusWhenUncovered(attempts: attempts - 1) }
            return
        }
        _ = window.makeFirstResponder(self)
        // SwiftUI restores focus to the sidebar shortly after a sheet ends.
        if attempts < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.inputEnabled, let window = self.window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return }
                _ = window.makeFirstResponder(self)
            }
        }
    }

    func freezeInput() {
        inputEnabled = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === self else { return }
            _ = window.makeFirstResponder(nil)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Watching: say that the key went nowhere, as macOS does elsewhere.
        guard inputEnabled else { NSSound.beep(); return }
        super.insertText(string, replacementRange: replacementRange)
    }

    func applyGeometry(_ session: LocalSessionInfo) {
        // Core has validated this geometry and its order relative to VT bytes.
        if getTerminal().cols != session.columns || getTerminal().rows != session.rows {
            getTerminal().resize(cols: session.columns, rows: session.rows)
            sizeChanged(source: getTerminal())
        }
        readingSelection = nil
        selectNone()
        geometryChanged?(session)
        refreshReadingDocument()
    }

    func refreshReadingDocument(outputChanged: Bool = false) {
        let terminal = getTerminal()
        guard !terminal.synchronizedOutputActive, terminal.cols > 0, terminal.rows > 0, !bounds.isEmpty else { return }
        let size = readingCellSize
        let visible = visibleRect
        let topLeft = CGRect(x: visible.minX, y: bounds.height - visible.maxY, width: visible.width, height: visible.height)
        let page = TerminalAXViewport.cells(in: topLeft, origin: .zero, cellSize: size,
                                           columns: terminal.cols, rows: terminal.rows)
        let location = terminal.getCursorLocation()
        let cursor = !canScroll || scrollPosition >= 0.999 || terminal.isCurrentBufferAlternate
            ? (row: location.y, column: min(location.x, terminal.cols)) : nil
        let next = TerminalAXDocument.make(terminal: terminal, rows: page.rows, columns: page.columns, cursor: cursor)
        if let selection = readingSelection {
            if next.topRow == readingDocument.topRow, next.alternate == readingDocument.alternate,
               let start = readingDocument.gridPosition(at: selection.location),
               let end = readingDocument.gridPosition(at: NSMaxRange(selection)),
               let newStart = next.index(row: start.row, column: start.column),
               let newEnd = next.index(row: end.row, column: end.column), newEnd >= newStart {
                let remapped = NSRange(location: newStart, length: newEnd - newStart)
                readingSelection = next.string(for: remapped) == readingDocument.string(for: selection) ? remapped : nil
            } else { readingSelection = nil }
        }
        let changed = next.text != readingDocument.text
        readingDocument = next
        if outputChanged, changed, announceOutput, NSWorkspace.shared.isVoiceOverEnabled,
           lastAnnouncement.duration(to: .now) >= .seconds(2) {
            lastAnnouncement = .now
            // Do not infer password fields or speak raw terminal output.
            if let application = NSApp {
                NSAccessibility.post(element: application, notification: .announcementRequested,
                    userInfo: [.announcement: String(localized: "New terminal output", bundle: .main), .priority: NSAccessibilityPriorityLevel.low.rawValue])
            }
        }
    }

    var readingCellSize: CGSize {
        let terminal = getTerminal(), frame = getOptimalFrameSize()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let width = max(1, (advance * scale).rounded() / scale)
        return CGSize(width: width, height: frame.height / CGFloat(max(1, terminal.rows)))
    }

    func pageReading(forward: Bool) -> Bool {
        let before = getTerminal().getTopVisibleRow()
        // Alternate-buffer page keys are application input in SwiftTerm, not
        // local scrollback. Accessibility reading must never send those keys.
        if !getTerminal().isCurrentBufferAlternate {
            if forward { pageDown() } else { pageUp() }
        }
        if before == getTerminal().getTopVisibleRow() {
            guard let scroll = enclosingScrollView else { return false }
            let previous = scroll.contentView.bounds.origin
            let delta = scroll.contentView.bounds.height * (forward ? -1 : 1)
            let target = max(0, min(max(0, bounds.height - scroll.contentView.bounds.height), previous.y + delta))
            guard target != previous.y else { return false }
            scroll.contentView.scroll(to: CGPoint(x: previous.x, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        readingSelection = nil
        refreshReadingDocument()
        return true
    }

    func panReading(forward: Bool) -> Bool {
        guard let scroll = enclosingScrollView else { return false }
        let old = scroll.contentView.bounds.origin
        let maximum = max(0, bounds.width - scroll.contentView.bounds.width)
        let target = max(0, min(maximum, old.x + (forward ? 1 : -1) * scroll.contentView.bounds.width))
        guard old.x != target else { return false }
        scroll.contentView.scroll(to: CGPoint(x: target, y: old.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        readingSelection = nil
        refreshReadingDocument()
        return true
    }

    func localReadingRectangles(for range: NSRange) -> [CGRect] {
        readingDocument.rectangles(for: range, cellSize: readingCellSize).map {
            CGRect(x: $0.minX, y: bounds.height - $0.maxY, width: $0.width, height: $0.height).intersection(visibleRect)
        }.filter { !$0.isNull && !$0.isEmpty }
    }

    override func accessibilityValue() -> Any? { refreshReadingDocument(); return readingDocument.text }
    override func accessibilityNumberOfCharacters() -> Int { refreshReadingDocument(); return readingDocument.length }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        refreshReadingDocument(); return NSRange(location: 0, length: readingDocument.length)
    }
    override func accessibilityString(for range: NSRange) -> String? {
        refreshReadingDocument(); return readingDocument.string(for: range)
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let string = accessibilityString(for: range) else { return nil }
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: nativeForegroundColor])
    }
    override func accessibilityRange(for index: Int) -> NSRange {
        refreshReadingDocument(); return readingDocument.characterRange(at: index)
    }
    override func accessibilityStyleRange(for index: Int) -> NSRange { accessibilityRange(for: index) }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        refreshReadingDocument(); return readingDocument.range(forLine: line)
    }
    override func accessibilityLine(for index: Int) -> Int {
        refreshReadingDocument(); return readingDocument.lineIndex(at: index) ?? NSNotFound
    }
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        refreshReadingDocument()
        guard let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard visibleRect.contains(local) else { return NSRange(location: NSNotFound, length: 0) }
        return readingDocument.range(at: CGPoint(x: local.x, y: bounds.height - local.y), cellSize: readingCellSize)
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        refreshReadingDocument()
        guard let window, let first = localReadingRectangles(for: range).first else { return .zero }
        let rect = localReadingRectangles(for: range).dropFirst().reduce(first) { $0.union($1) }
        return window.convertToScreen(convert(rect, to: nil))
    }
    override func accessibilitySelectedTextRange() -> NSRange {
        refreshReadingDocument()
        return readingSelection ?? NSRange(location: readingDocument.caret ?? NSNotFound, length: 0)
    }
    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        let range = accessibilitySelectedTextRange()
        return range.location == NSNotFound ? [] : [NSValue(range: range)]
    }
    override func accessibilitySelectedText() -> String? { readingDocument.string(for: accessibilitySelectedTextRange()) }
    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityLine(for: accessibilitySelectedTextRange().location)
    }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        refreshReadingDocument()
        guard let normalized = readingDocument.normalizedSelection(range) else { return }
        readingSelection = normalized
        if normalized.length > 0, let start = readingDocument.gridPosition(at: normalized.location),
           let end = readingDocument.gridPosition(at: NSMaxRange(normalized)) {
            selection.setSelection(start: Position(col: start.column, row: start.row + getTerminal().getTopVisibleRow()),
                                   end: Position(col: end.column, row: end.row + getTerminal().getTopVisibleRow()))
        } else { selectNone() }
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }
    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        guard let range = ranges?.first?.rangeValue else { return }
        setAccessibilitySelectedTextRange(range)
    }
    override func isAccessibilityFocused() -> Bool { readingFocused || window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        readingFocused = focused
        if focused, inputEnabled { scheduleInitialFocus() }
    }
    override func accessibilityPerformPress() -> Bool {
        readingFocused = true
        if inputEnabled { scheduleInitialFocus() }
        return true
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if [#selector(setAccessibilityValue(_:)), #selector(setAccessibilitySelectedText(_:)),
            #selector(setAccessibilityInsertionPointLineNumber(_:))].contains(selector) { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    // MARK: Context menu and file drops

    /// Right-click: Copy (with a selection), Paste (only while typing),
    /// Select All, and Find…, the same commands as the Edit menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy", bundle: .main), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Paste", bundle: .main), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Select All", bundle: .main), action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let find = NSMenuItem(title: String(localized: "Find…", bundle: .main), action: #selector(performTextFinderAction(_:)), keyEquivalent: "")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(find)
        for item in menu.items { item.target = self }
        return menu
    }

    /// Paste types into the terminal, so it's off while watching.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), !inputEnabled { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        inputEnabled && !Self.droppedPaths(sender).isEmpty ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    /// Types each file's path, quoted for the shell and separated by spaces,
    /// without pressing Return.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.droppedPaths(sender)
        guard inputEnabled, !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        insertText(paths.map(Self.shellQuoted).joined(separator: " ") + " ", replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    private static func droppedPaths(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    /// A path as one shell word: bare when it's only safe characters,
    /// otherwise in single quotes (a quote inside becomes '\'').
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,:@%"))
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ $0.isASCII && safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
