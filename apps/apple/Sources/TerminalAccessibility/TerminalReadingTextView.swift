#if os(iOS)
import UIKit

/// One non-editing accessibility representation of the visible VT page. The
/// SwiftTerm view remains the sole keyboard/IME responder, with its AX hidden.
@MainActor final class TerminalReadingTextView: UITextView, UITextViewDelegate, UIAccessibilityReadingContent {
    private(set) var readingDocument = TerminalAXDocument.empty
    var cellSize = CGSize(width: 1, height: 1)
    var rectFromGrid: ((CGRect) -> CGRect)?
    var pointToGrid: ((CGPoint) -> CGPoint)?
    var page: ((Bool) -> Bool)?
    var panHorizontal: ((Bool) -> Bool)?
    private var updating = false
    private var explicitSelection = false
    private var lastAnnouncement = ContinuousClock.now

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        textColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(width: 1_000_000, height: 1_000_000)
        contentInsetAdjustmentBehavior = .never
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .causesPageTurn]
        accessibilityTextualContext = .sourceCode
        accessibilityIdentifier = "remoteTerminalSurface"
        accessibilityLabel = String(localized: "Terminal Text", bundle: .main)
        accessibilityHint = String(localized: "Read by line, word or character. Selection is only used for local reading.", bundle: .main)
        delegate = self
        accessibilityCustomRotors = [rotor(String(localized: "Terminal Lines", bundle: .main), kind: .line), rotor(String(localized: "Terminal Words", bundle: .main), kind: .word), rotor(String(localized: "Terminal Characters", bundle: .main), kind: .character)]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Previous Page", bundle: .main)) { [weak self] _ in self?.page?(false) ?? false },
            UIAccessibilityCustomAction(name: String(localized: "Next Page", bundle: .main)) { [weak self] _ in self?.page?(true) ?? false },
            UIAccessibilityCustomAction(name: String(localized: "Pan Left", bundle: .main)) { [weak self] _ in self?.panHorizontal?(false) ?? false },
            UIAccessibilityCustomAction(name: String(localized: "Pan Right", bundle: .main)) { [weak self] _ in self?.panHorizontal?(true) ?? false },
            UIAccessibilityCustomAction(name: String(localized: "Terminal Cursor", bundle: .main)) { [weak self] _ in
                guard let self, let index = self.readingDocument.caret else { return false }
                self.setReadingSelection(NSRange(location: index, length: 0))
                return true
            }
        ]
    }

    required init?(coder: NSCoder) { nil }
    override var canBecomeFirstResponder: Bool { false }
    override func insertText(_ text: String) { }
    override func deleteBackward() { }
    override func replace(_ range: UITextRange, withText text: String) { }

    func update(document: TerminalAXDocument, cellSize: CGSize, font: UIFont, announceOutput: Bool = false) {
        let old = readingDocument
        let oldRange = selectedRange
        let changed = old.text != document.text
        let selection = explicitSelection ? remapped(oldRange, from: old, to: document) : nil
        readingDocument = document
        self.cellSize = cellSize
        updating = true
        if changed {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = cellSize.height
            paragraph.maximumLineHeight = cellSize.height
            paragraph.lineBreakMode = .byClipping
            attributedText = NSAttributedString(string: document.text,
                attributes: [.font: font, .foregroundColor: UIColor.clear, .paragraphStyle: paragraph])
        }
        selectedRange = selection ?? NSRange(location: document.caret ?? 0, length: 0)
        if selection == nil { explicitSelection = false }
        updating = false
        // Even opted-in live feedback never guesses password semantics or
        // voices a page of potentially sensitive terminal content.
        if changed, announceOutput, UIAccessibility.isVoiceOverRunning,
           lastAnnouncement.duration(to: .now) >= .seconds(2) {
            lastAnnouncement = .now
            UIAccessibility.post(notification: .announcement, argument: String(localized: "New terminal output", bundle: .main))
        }
    }

    private func remapped(_ range: NSRange, from old: TerminalAXDocument, to next: TerminalAXDocument) -> NSRange? {
        guard old.topRow == next.topRow, old.alternate == next.alternate,
              let start = old.gridPosition(at: range.location), let end = old.gridPosition(at: NSMaxRange(range)),
              let newStart = next.index(row: start.row, column: start.column),
              let newEnd = next.index(row: end.row, column: end.column), newEnd >= newStart else { return nil }
        let candidate = NSRange(location: newStart, length: newEnd - newStart)
        return next.string(for: candidate) == old.string(for: range) ? next.normalizedSelection(candidate) : nil
    }

    func clearReadingSelection() {
        explicitSelection = false
        updating = true
        selectedRange = NSRange(location: readingDocument.caret ?? 0, length: 0)
        updating = false
    }

    func setReadingSelection(_ range: NSRange) {
        guard let normalized = readingDocument.normalizedSelection(range) else { return }
        selectedRange = normalized
        explicitSelection = true
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !updating else { return }
        explicitSelection = true
        // This selection belongs to this non-editable document, never to
        // SwiftTerm.selectedTextRange (the keyboard's marked-text buffer).
        setNeedsDisplay()
    }

    func readingRects(for range: NSRange) -> [CGRect] {
        readingDocument.rectangles(for: range, cellSize: cellSize).compactMap { rect in
            guard let mapped = rectFromGrid?(rect) else { return nil }
            let clipped = mapped.intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
    }

    private func nsRange(_ range: UITextRange) -> NSRange? {
        let start = offset(from: beginningOfDocument, to: range.start)
        let end = offset(from: beginningOfDocument, to: range.end)
        let result = NSRange(location: start, length: max(0, end - start))
        return readingDocument.valid(result) ? result : nil
    }

    func readingTextRange(_ range: NSRange) -> UITextRange? {
        guard readingDocument.valid(range),
              let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: beginningOfDocument, offset: NSMaxRange(range)) else { return nil }
        return textRange(from: start, to: end)
    }

    override func firstRect(for range: UITextRange) -> CGRect {
        guard let range = nsRange(range) else { return .zero }
        return readingRects(for: range).first ?? .zero
    }
    override func caretRect(for position: UITextPosition) -> CGRect {
        let index = offset(from: beginningOfDocument, to: position)
        return readingRects(for: NSRange(location: index, length: 0)).first ?? .zero
    }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let value = nsRange(range) else { return [] }
        let rects = readingRects(for: value)
        return rects.enumerated().map { TerminalReadingSelectionRect(rect: $0.element,
            start: $0.offset == 0, end: $0.offset == rects.count - 1) }
    }
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard bounds.contains(point), let grid = pointToGrid?(point) else { return nil }
        let range = readingDocument.range(at: grid, cellSize: cellSize)
        guard range.location != NSNotFound else { return nil }
        return position(from: beginningOfDocument, offset: range.location)
    }
    override func characterRange(at point: CGPoint) -> UITextRange? {
        guard bounds.contains(point), let grid = pointToGrid?(point) else { return nil }
        return readingTextRange(readingDocument.range(at: grid, cellSize: cellSize))
    }

    enum ReadingUnit { case line, word, character }
    func ranges(for unit: ReadingUnit) -> [NSRange] {
        switch unit {
        case .line: return readingDocument.lines.map(\.range)
        case .word: return readingDocument.wordRanges
        case .character:
            var ranges: [NSRange] = [], index = 0
            while index < readingDocument.length {
                let range = readingDocument.characterRange(at: index)
                guard range.length > 0 else { break }
                ranges.append(range)
                index = NSMaxRange(range)
            }
            return ranges
        }
    }
    private func rotor(_ name: String, kind: ReadingUnit) -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: name) { [weak self] predicate in
            guard let self else { return nil }
            let current = predicate.currentItem.targetElement === self
                ? predicate.currentItem.targetRange.flatMap { self.nsRange($0) } : nil
            let forward = predicate.searchDirection == .next
            let all = self.ranges(for: kind).filter { $0 != current && !self.readingRects(for: $0).isEmpty }
            let candidate = forward
                ? all.first(where: { current == nil || $0.location >= NSMaxRange(current!) })
                : all.last(where: { current == nil || NSMaxRange($0) <= current!.location })
            if let candidate, let target = self.readingTextRange(candidate) {
                return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: target)
            }
            if self.page?(forward) == true {
                let next = forward ? self.ranges(for: kind).first : self.ranges(for: kind).last
                if let next, let target = self.readingTextRange(next) {
                    return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: target)
                }
            }
            return nil
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let scrolled: Bool
        switch direction {
        case .down, .next: scrolled = page?(true) ?? false
        case .up, .previous: scrolled = page?(false) ?? false
        case .left: scrolled = panHorizontal?(true) ?? false
        case .right: scrolled = panHorizontal?(false) ?? false
        default: return false
        }
        if scrolled { UIAccessibility.post(notification: .pageScrolled, argument: nil) }
        return scrolled
    }
    func accessibilityLineNumber(for point: CGPoint) -> Int {
        guard let grid = pointToGrid?(point), cellSize.height > 0, grid.y.isFinite,
              grid.y >= 0, grid.y / cellSize.height < 200 else { return NSNotFound }
        let row = Int(floor(grid.y / cellSize.height))
        return readingDocument.lines.firstIndex(where: { $0.row == row }) ?? NSNotFound
    }
    func accessibilityContent(forLineNumber lineNumber: Int) -> String? {
        readingDocument.string(for: readingDocument.range(forLine: lineNumber))
    }
    func accessibilityFrame(forLineNumber lineNumber: Int) -> CGRect {
        guard let rect = readingRects(for: readingDocument.range(forLine: lineNumber)).first else { return .zero }
        return UIAccessibility.convertToScreenCoordinates(rect, in: self)
    }
    func accessibilityPageContent() -> String? { readingDocument.text }
    func accessibilityAttributedContent(forLineNumber lineNumber: Int) -> NSAttributedString? {
        accessibilityContent(forLineNumber: lineNumber).map { NSAttributedString(string: $0) }
    }
    func accessibilityAttributedPageContent() -> NSAttributedString? { NSAttributedString(string: readingDocument.text) }
}

@MainActor private final class TerminalReadingSelectionRect: UITextSelectionRect {
    private let value: CGRect
    private let start: Bool
    private let end: Bool
    init(rect: CGRect, start: Bool, end: Bool) { value = rect; self.start = start; self.end = end; super.init() }
    override var rect: CGRect { value }
    override var writingDirection: NSWritingDirection { .natural }
    override var containsStart: Bool { start }
    override var containsEnd: Bool { end }
    override var isVertical: Bool { false }
}
#endif
