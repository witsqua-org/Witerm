import Foundation

/// A saved command, typed into the focused terminal on request. Snippets stay
/// in this device's preferences; they are never synced or sent to a server.
struct CommandSnippet: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    /// Presses Return after a single-line snippet. Multiline snippets never
    /// add one, matching pasted text.
    var runsImmediately = false

    var isMultiline: Bool { text.contains(where: \.isNewline) }

    /// The bytes to type: bracketed like a paste when the program asked for
    /// that, with line breaks sent as Return.
    func input(bracketedPaste: Bool) -> [UInt8] {
        let body = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        var result = bracketedPaste ? "\u{1b}[200~" + body + "\u{1b}[201~" : body
        if runsImmediately, !isMultiline { result += "\r" }
        return Array(result.utf8)
    }
}

enum CommandSnippets {
    static let key = "witerm.commandSnippets"
    static let limit = 50
    static let nameLimit = 60
    static let textLimit = 4_096

    static func decode(_ data: Data?) -> [CommandSnippet] {
        guard let data, let values = try? JSONDecoder().decode([CommandSnippet].self, from: data) else { return [] }
        return Array(values.filter { validate(name: $0.name, text: $0.text) == nil }.prefix(limit))
    }

    static func encode(_ snippets: [CommandSnippet]) -> Data {
        (try? JSONEncoder().encode(Array(snippets.prefix(limit)))) ?? Data()
    }

    static func load(from defaults: UserDefaults = .standard) -> [CommandSnippet] {
        decode(defaults.data(forKey: key))
    }

    /// A reason the snippet can't be saved, or nil.
    static func validate(name: String, text: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > nameLimit || trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return String(localized: "Use a name of up to 60 characters without control characters.", bundle: .main)
        }
        if text.isEmpty || text.utf8.count > textLimit {
            return String(localized: "Enter a command of up to 4 KB.", bundle: .main)
        }
        // Escape and other controls could drive the terminal itself; only text,
        // tabs, and line breaks are allowed.
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains($0) }) {
            return String(localized: "Commands can't contain control characters other than tabs and line breaks.", bundle: .main)
        }
        return nil
    }
}
