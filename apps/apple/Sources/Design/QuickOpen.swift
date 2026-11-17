import Foundation
import SwiftUI

/// One thing Open Quickly can reach: a terminal, an SSH host, a snippet, or a
/// command. `id` is stable across launches ("local:<session>", "ssh:<uuid>",
/// "snippet:<uuid>", "action:<name>") so recent choices can float to the top.
struct QuickOpenItem: Identifiable {
    enum Kind: Int, Comparable {
        case terminal, host, command, snippet

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let kind: Kind
    let title: String
    /// One plain line under the title: what a terminal is doing, a host's
    /// address, a snippet's first line. Matched too, with less weight.
    var detail: String? = nil
    let symbol: String
    /// Other words a person might type for it ("ssh", "connect").
    var keywords: [String] = []
    /// The menu shortcut that does the same, shown so it can be learned.
    var shortcut: String? = nil
    /// A host's identity hue, so the row matches its sidebar row.
    var tint: Color? = nil
    let perform: () -> Void
}

/// How Open Quickly orders what it finds. Pure, so it's tested without UI.
///
/// A match on the title beats one on a keyword or the detail; within each,
/// the whole title beats its start, then the words' initials (`nt` for New
/// Terminal), then a word's start, then the middle, and letters in order
/// (`bdl` for Build logs) come last. Things chosen
/// recently rank higher, and with nothing typed they come first.
enum QuickOpenRanking {
    static let recentKey = "witerm.quickOpen.recent"
    static let recentLimit = 20

    /// Higher is better; nil when `query` isn't in `text` at all.
    static func score(_ query: String, in text: String) -> Int? {
        let needle = fold(query), haystack = fold(text)
        guard !needle.isEmpty, !haystack.isEmpty else { return nil }
        if haystack == needle { return 1_000 }
        if haystack.hasPrefix(needle) { return 800 }
        let letters = needle.filter { $0 != " " }
        if letters.count >= 2, initials(of: haystack).hasPrefix(letters) { return 700 }
        if let range = haystack.range(of: needle) {
            let before = haystack[..<range.lowerBound].last
            return before.map(isBoundary) == true ? 600 : 400
        }
        // Letters in order. Each skipped character costs a little, and each
        // letter that starts a word earns some back, so `nt` finds "New
        // Terminal" before "Content".
        var score = 200
        var index = haystack.startIndex
        var previous: Character? = nil
        for letter in needle where letter != " " {
            var skipped = 0
            while index < haystack.endIndex, haystack[index] != letter {
                previous = haystack[index]
                index = haystack.index(after: index)
                skipped += 1
            }
            guard index < haystack.endIndex else { return nil }
            score -= min(skipped, 20)
            if previous.map(isBoundary) ?? true { score += 8 }
            previous = haystack[index]
            index = haystack.index(after: index)
        }
        return max(score, 1)
    }

    /// The items for `query`, best first. With nothing typed: recent
    /// choices in order, then terminals, hosts and commands (not snippets,
    /// which are only worth listing when asked for).
    static func rank(_ items: [QuickOpenItem], query: String, recent: [String], limit: Int = 50) -> [QuickOpenItem] {
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Array(items.enumerated()
                .filter { $0.element.kind != .snippet || recency[$0.element.id] != nil }
                .sorted { lhs, rhs in
                    let left = recency[lhs.element.id] ?? Int.max, right = recency[rhs.element.id] ?? Int.max
                    if left != right { return left < right }
                    if lhs.element.kind != rhs.element.kind { return lhs.element.kind < rhs.element.kind }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
                .prefix(limit))
        }
        let scored: [(item: QuickOpenItem, score: Int, order: Int)] = items.enumerated().compactMap { offset, item in
            let title = score(trimmed, in: item.title)
            let other = (item.keywords + [item.detail].compactMap { $0 }).compactMap { score(trimmed, in: $0) }.max()
                .map { $0 / 2 }
            guard var best = [title, other].compactMap({ $0 }).max() else { return nil }
            if let rank = recency[item.id] { best += max(0, (recentLimit - rank) * 6) }
            return (item, best, offset)
        }
        return Array(scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.kind != rhs.item.kind { return lhs.item.kind < rhs.item.kind }
            return lhs.order < rhs.order
        }.map(\.item).prefix(limit))
    }

    /// `recent` with `id` moved to the front, capped.
    static func remember(_ id: String, in recent: [String]) -> [String] {
        Array(([id] + recent.filter { $0 != id }).prefix(recentLimit))
    }

    static func loadRecent(from defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: recentKey) ?? []).prefix(recentLimit).map { $0 }
    }

    static func saveRecent(_ ids: [String], to defaults: UserDefaults = .standard) {
        defaults.set(Array(ids.prefix(recentLimit)), forKey: recentKey)
    }

    /// Case, width and accents don't matter: `ubuntu` finds "Ubuntu", and
    /// `cafe` finds "Café".
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The first letter of each word: "new terminal in same folder" is "ntisf".
    private static func initials(of text: String) -> String {
        var result = "", previous: Character? = nil
        for character in text {
            if !isBoundary(character), previous.map(isBoundary) ?? true { result.append(character) }
            previous = character
        }
        return result
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "-_./@:()[]".contains(character)
    }
}
