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

/// Blanks in a snippet, written `{{name}}`, that are asked for each time it's
/// inserted: `git switch {{branch}}`, `ssh {{user}}@{{host}}`. A name starts
/// with a letter and holds letters, digits, spaces, `-` and `_`, so Go and
/// Docker templates such as `{{.Name}}` or `{{json .}}` stay as they are.
/// The same name twice is one blank. Values are typed as given: they're the
/// person's own input, like typing, and never shell-quoted on their behalf.
enum SnippetPlaceholders {
    static let nameLimit = 40
    static let valueLimit = 1_024

    /// Each blank's name once, in the order it first appears.
    static func names(in text: String) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for match in matches(in: text) where seen.insert(match.name).inserted { result.append(match.name) }
        return result
    }

    /// `text` with every blank replaced by its value; a blank without a
    /// value stays as written.
    static func fill(_ text: String, values: [String: String]) -> String {
        var result = "", index = text.startIndex
        for match in matches(in: text) {
            result += text[index..<match.range.lowerBound]
            result += values[match.name] ?? String(text[match.range])
            index = match.range.upperBound
        }
        return result + text[index...]
    }

    /// A value can't contain line breaks or control characters: it would
    /// run the command early or drive the terminal itself.
    static func validValue(_ value: String) -> Bool {
        value.utf8.count <= valueLimit && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private struct Match { let name: String; let range: Range<String.Index> }

    private static func matches(in text: String) -> [Match] {
        var result: [Match] = []
        var search = text.startIndex
        while let open = text.range(of: "{{", range: search..<text.endIndex) {
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else { break }
            let inner = text[open.upperBound..<close.lowerBound]
            let name = inner.trimmingCharacters(in: .whitespaces)
            if validName(name) {
                result.append(Match(name: name, range: open.lowerBound..<close.upperBound))
                search = close.upperBound
            } else {
                search = text.index(after: open.lowerBound)
            }
        }
        return result
    }

    private static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first), name.count <= nameLimit else { return false }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " -_"))
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }
}

extension CommandSnippet {
    /// The blanks to ask for before inserting, if any.
    var placeholders: [String] { SnippetPlaceholders.names(in: text) }

    /// This snippet with its blanks filled in, ready to type.
    func filled(_ values: [String: String]) -> CommandSnippet {
        var copy = self
        copy.text = SnippetPlaceholders.fill(text, values: values)
        return copy
    }
}

/// The last value given for each blank of each snippet, so inserting the same
/// snippet again starts from what was used. In memory only: values can be
/// anything a person types, so they're never written to disk.
@MainActor enum SnippetRecentValues {
    private static var values: [UUID: [String: String]] = [:]

    static func values(for snippet: CommandSnippet) -> [String: String] { values[snippet.id] ?? [:] }

    static func remember(_ given: [String: String], for snippet: CommandSnippet) { values[snippet.id] = given }
}
