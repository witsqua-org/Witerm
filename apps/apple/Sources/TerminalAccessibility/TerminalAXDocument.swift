import Foundation
import CoreGraphics
import SwiftTerm

/// A bounded reading page, indexed in UTF-16 as required by AppKit/UIKit text APIs.
/// It describes VT cells, never an editable shell command buffer.
struct TerminalAXDocument: Equatable {
    struct Cell: Equatable {
        let range: NSRange
        let row: Int
        let column: Int
        let width: Int
    }
    struct Line: Equatable {
        let range: NSRange
        let row: Int
        let startColumn: Int
        let endColumn: Int
    }

    let text: String
    let cells: [Cell]
    let lines: [Line]
    let caret: Int?
    let alternate: Bool
    let topRow: Int
    var length: Int { (text as NSString).length }
    static let empty = TerminalAXDocument(text: "", cells: [], lines: [], caret: nil, alternate: false, topRow: 0)

    static func make(terminal: Terminal, rows visibleRows: Range<Int>, columns visibleColumns: Range<Int>,
                     cursor: (row: Int, column: Int)?) -> Self {
        let lowerRow = max(0, min(terminal.rows, visibleRows.lowerBound))
        let upperRow = max(lowerRow, min(terminal.rows, visibleRows.upperBound))
        let lowerColumn = max(0, min(terminal.cols, visibleColumns.lowerBound))
        let upperColumn = max(lowerColumn, min(terminal.cols, visibleColumns.upperBound))
        var text = "", cells: [Cell] = [], lines: [Line] = [], caret: Int?
        var offset = 0
        for row in lowerRow..<upperRow {
            guard let line = terminal.getLine(row: row) else { continue }
            if !lines.isEmpty { text += "\n"; offset += 1 }
            let start = offset
            let cursorLimit = cursor?.row == row ? min(upperColumn, cursor!.column) : lowerColumn
            let end = max(lowerColumn, min(line.count, upperColumn, max(line.getTrimmedLength(), cursorLimit)))
            var column = lowerColumn
            while column < end {
                let cell = line[column]
                let width = Int(cell.width)
                if width == 0 { column += 1; continue }
                let character = terminal.getCharacter(for: cell)
                let value = character == "\0" ? " " : String(character)
                let count = value.utf16.count
                if cursor?.row == row, let cursor, cursor.column >= column, cursor.column < column + width { caret = offset }
                cells.append(Cell(range: NSRange(location: offset, length: count), row: row, column: column, width: width))
                text += value
                offset += count
                column += width
            }
            if cursor?.row == row, let cursor, cursor.column >= end, cursor.column <= upperColumn { caret = offset }
            lines.append(Line(range: NSRange(location: start, length: offset - start), row: row,
                              startColumn: lowerColumn, endColumn: end))
        }
        return Self(text: text, cells: cells, lines: lines, caret: caret,
                    alternate: terminal.isCurrentBufferAlternate,
                    topRow: terminal.getTopVisibleRow() + terminal.buffer.totalLinesTrimmed)
    }

    func valid(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= length && range.length <= length - range.location
    }

    func string(for range: NSRange) -> String? {
        guard valid(range) else { return nil }
        return (text as NSString).substring(with: range)
    }

    func characterRange(at index: Int) -> NSRange {
        guard index >= 0, index < length else {
            return index == length ? NSRange(location: length, length: 0) : NSRange(location: NSNotFound, length: 0)
        }
        return (text as NSString).rangeOfComposedCharacterSequence(at: index)
    }

    func normalizedSelection(_ range: NSRange) -> NSRange? {
        guard valid(range) else { return nil }
        guard range.length > 0 else {
            return NSRange(location: range.location == length ? length : characterRange(at: range.location).location, length: 0)
        }
        return (text as NSString).rangeOfComposedCharacterSequences(for: range)
    }

    var wordRanges: [NSRange] {
        var result: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
            result.append(NSRange(range, in: text))
        }
        return result
    }

    func lineIndex(at index: Int) -> Int? {
        guard index >= 0, index <= length, !lines.isEmpty else { return nil }
        return lines.lastIndex(where: { $0.range.location <= index }) ?? 0
    }

    func range(forLine index: Int) -> NSRange {
        guard lines.indices.contains(index) else { return NSRange(location: NSNotFound, length: 0) }
        return lines[index].range
    }

    func gridPosition(at index: Int) -> (row: Int, column: Int)? {
        guard let lineIndex = lineIndex(at: index) else { return nil }
        let line = lines[lineIndex]
        if let cell = cells.first(where: { $0.row == line.row && NSLocationInRange(index, $0.range) }) {
            return (cell.row, cell.column)
        }
        return (line.row, line.endColumn)
    }

    func index(row: Int, column: Int) -> Int? {
        guard let line = lines.first(where: { $0.row == row }) else { return nil }
        if let cell = cells.first(where: { $0.row == row && column >= $0.column && column < $0.column + $0.width }) {
            return cell.range.location
        }
        return column <= line.startColumn ? line.range.location : NSMaxRange(line.range)
    }

    func rectangles(for range: NSRange, cellSize: CGSize) -> [CGRect] {
        guard valid(range), cellSize.width > 0, cellSize.height > 0,
              cellSize.width.isFinite, cellSize.height.isFinite else { return [] }
        if range.length == 0, let position = gridPosition(at: range.location) {
            let rect = CGRect(x: CGFloat(position.column) * cellSize.width, y: CGFloat(position.row) * cellSize.height,
                              width: 1, height: cellSize.height)
            return Self.finite(rect) ? [rect] : []
        }
        var result: [CGRect] = []
        for line in lines {
            let selected = cells.filter { $0.row == line.row && NSIntersectionRange($0.range, range).length > 0 }
            guard let first = selected.first, let last = selected.last else { continue }
            result.append(CGRect(x: CGFloat(first.column) * cellSize.width, y: CGFloat(line.row) * cellSize.height,
                                 width: CGFloat(last.column + last.width - first.column) * cellSize.width,
                                 height: cellSize.height))
        }
        return result.filter(Self.finite)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }

    func range(at point: CGPoint, cellSize: CGSize) -> NSRange {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              cellSize.width > 0, cellSize.height > 0, cellSize.width.isFinite, cellSize.height.isFinite,
              point.x / cellSize.width < CGFloat((lines.map(\.endColumn).max() ?? 0) + 1),
              point.y / cellSize.height < CGFloat((lines.map(\.row).max() ?? -1) + 1),
              let index = index(row: Int(floor(point.y / cellSize.height)), column: Int(floor(point.x / cellSize.width)))
        else { return NSRange(location: NSNotFound, length: 0) }
        return characterRange(at: index)
    }
}

enum TerminalAXViewport {
    static func cells(in visible: CGRect, origin: CGPoint, cellSize: CGSize, columns: Int, rows: Int) -> (rows: Range<Int>, columns: Range<Int>) {
        guard !visible.isEmpty, !visible.isNull, !visible.isInfinite, columns >= 0, rows >= 0,
              cellSize.width > 0, cellSize.height > 0, cellSize.width.isFinite, cellSize.height.isFinite,
              visible.minX.isFinite, visible.minY.isFinite, visible.maxX.isFinite, visible.maxY.isFinite,
              origin.x.isFinite, origin.y.isFinite else { return (0..<0, 0..<0) }
        func index(_ value: CGFloat, _ start: CGFloat, _ unit: CGFloat, _ limit: Int, roundUp: Bool) -> Int {
            // Far into the scrollback, an edge that falls exactly on a cell
            // boundary can come out a hair short (14.9999…), which dropped
            // the last whole row, the prompt, from the page. Snap those.
            let raw = (value - start) / unit
            let quotient = abs(raw - raw.rounded()) < 1e-6 ? raw.rounded() : raw
            guard quotient > 0 else { return 0 }
            guard quotient < CGFloat(limit) else { return limit }
            return Int(roundUp ? ceil(quotient) : floor(quotient))
        }
        let left = index(visible.minX, origin.x, cellSize.width, columns, roundUp: true)
        let right = max(left, index(visible.maxX, origin.x, cellSize.width, columns, roundUp: false))
        let top = index(visible.minY, origin.y, cellSize.height, rows, roundUp: true)
        let bottom = max(top, index(visible.maxY, origin.y, cellSize.height, rows, roundUp: false))
        return (top..<min(bottom, top + 200), left..<min(right, left + 500))
    }
}
