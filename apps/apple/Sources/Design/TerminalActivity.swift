import Foundation
import Observation
import SwiftTerm

/// What a live terminal is doing, read from its own renderer: the title and
/// folder the shell reports, the last line on screen, and when output last
/// arrived. Lists show it so a person can tell whether to open a terminal.
/// It lives in memory with the renderer and is never stored or sent.
@MainActor @Observable
final class TerminalActivity {
    private(set) var title: String?
    private(set) var directory: String?
    private(set) var lastLine: String?
    private(set) var changedAt: Date?
    /// Output can arrive many times a second; lists update at most once a second.
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private weak var terminal: Terminal?

    func titleChanged(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    /// OSC 7 reports `file://host/path`; only the path is kept.
    func directoryChanged(_ value: String?) {
        guard let value, !value.isEmpty else { directory = nil; return }
        let path = URL(string: value).flatMap { $0.scheme == "file" ? $0.path : nil } ?? value
        directory = path.isEmpty ? nil : String(path.prefix(200))
    }

    func outputArrived(in terminal: Terminal) {
        self.terminal = terminal
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.flush = nil
            self.changedAt = .now
            if let terminal = self.terminal { self.lastLine = Self.lastLine(in: terminal) }
        }
    }

    func stop() {
        flush?.cancel()
        flush = nil
        terminal = nil
    }

    /// The last non-blank line at or above the cursor: usually the newest
    /// output, or the prompt with the command being typed.
    static func lastLine(in terminal: Terminal) -> String? {
        let cursor = terminal.getCursorLocation()
        var row = min(max(cursor.y, 0), terminal.rows - 1)
        while row >= 0 {
            if let line = terminal.getLine(row: row) {
                let text = line.translateToString(trimRight: true)
                    .replacingOccurrences(of: "\0", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return String(text.prefix(160)) }
            }
            row -= 1
        }
        return nil
    }
}
