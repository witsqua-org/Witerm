import Foundation

/// Reads host entries from OpenSSH client configuration text the person
/// chose to import. Only addresses, ports, users, and ProxyJump chains are
/// taken; identity files, agents, and other options are left out, so no
/// credential or behavior is adopted silently.
public enum SSHConfigImport {
    public static let maximumSize = 262_144

    /// One importable alias. `skipped` explains why an entry can't be used.
    public struct Entry: Identifiable, Sendable {
        public var id: String { alias }
        public let alias: String
        public let profile: SSHProfile?
        public let skipped: Skip?
    }

    public enum Skip: Sendable, Equatable { case missingUser, unsupportedJump, invalid }

    /// Applies OpenSSH's rules: blocks are read in order, and the first value
    /// found for a keyword wins. `Match` blocks and `Include` are ignored.
    public static func parse(_ text: String, defaultUsername: String?) -> [Entry] {
        guard text.utf8.count <= maximumSize else { return [] }
        let blocks = blocks(in: text)
        var aliases: [String] = []
        for block in blocks {
            for pattern in block.patterns where !isPattern(pattern) && !aliases.contains(pattern) {
                aliases.append(pattern)
            }
        }
        return aliases.prefix(200).map { alias in
            let options = resolve(alias, in: blocks)
            guard let hosts = endpoints(alias, options: options, blocks: blocks, defaultUsername: defaultUsername, depth: 0) else {
                return Entry(alias: alias, profile: nil, skipped: options["proxyjump"] == nil ? .invalid : .unsupportedJump)
            }
            guard hosts.allSatisfy({ !$0.username.isEmpty }) else {
                return Entry(alias: alias, profile: nil, skipped: .missingUser)
            }
            let profile = SSHProfile(name: String(alias.prefix(80)), host: hosts[hosts.count - 1], jumpHosts: Array(hosts.dropLast()))
            guard (try? profile.validate()) != nil else { return Entry(alias: alias, profile: nil, skipped: .invalid) }
            return Entry(alias: alias, profile: profile, skipped: nil)
        }
    }

    private struct Block {
        var patterns: [String]
        var options: [(String, String)] = []
    }

    private static func blocks(in text: String) -> [Block] {
        // Options before the first Host line apply to every host.
        var blocks = [Block(patterns: ["*"])]
        var inMatch = false
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = tokens(String(line))
            guard let keyword = fields.first?.lowercased(), fields.count > 1 else { continue }
            switch keyword {
            case "host":
                blocks.append(Block(patterns: Array(fields.dropFirst())))
                inMatch = false
            case "match":
                inMatch = true
            default:
                if !inMatch { blocks[blocks.count - 1].options.append((keyword, fields[1])) }
            }
        }
        return blocks
    }

    /// Splits on whitespace or one `=`, honoring double quotes and `#` comments.
    private static func tokens(_ line: String) -> [String] {
        var result: [String] = [], current = "", quoted = false, sawSeparator = false
        for character in line {
            if character == "\"" { quoted.toggle(); continue }
            if !quoted, character == "#" { break }
            if !quoted, character.isWhitespace || (character == "=" && result.isEmpty && !sawSeparator) {
                if character == "=" { sawSeparator = true }
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func isPattern(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || value.hasPrefix("!")
    }

    private static func resolve(_ alias: String, in blocks: [Block]) -> [String: String] {
        var options: [String: String] = [:]
        for block in blocks where matches(alias, block.patterns) {
            for (keyword, value) in block.options where options[keyword] == nil { options[keyword] = value }
        }
        return options
    }

    private static func matches(_ alias: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), alias) { return false }
            } else if glob(pattern, alias) {
                matched = true
            }
        }
        return matched
    }

    private static func glob(_ pattern: String, _ text: String) -> Bool {
        let pattern = Array(pattern.lowercased()), text = Array(text.lowercased())
        func match(_ p: Int, _ t: Int) -> Bool {
            if p == pattern.count { return t == text.count }
            if pattern[p] == "*" { return (t...text.count).contains { match(p + 1, $0) } }
            guard t < text.count, pattern[p] == "?" || pattern[p] == text[t] else { return false }
            return match(p + 1, t + 1)
        }
        return match(0, 0)
    }

    /// The jump chain followed by the target, or nil when it can't be represented.
    private static func endpoints(_ alias: String, options: [String: String], blocks: [Block],
                                  defaultUsername: String?, depth: Int) -> [SSHHost]? {
        guard depth <= 4 else { return nil }
        let port = options["port"].map { Int($0) } ?? 22
        guard let port else { return nil }
        let target = SSHHost(hostname: options["hostname"] ?? alias, port: port,
                             username: options["user"] ?? defaultUsername ?? "")
        var jumps: [SSHHost] = []
        if let proxy = options["proxyjump"], proxy.lowercased() != "none" {
            for hop in proxy.split(separator: ",").map(String.init) {
                if blocks.contains(where: { $0.patterns.contains(hop) && !isPattern(hop) }) {
                    // A named entry brings its own jumps along.
                    guard let chain = endpoints(hop, options: resolve(hop, in: blocks), blocks: blocks,
                                                defaultUsername: defaultUsername, depth: depth + 1) else { return nil }
                    jumps += chain
                } else {
                    guard let host = parseHop(hop, defaultUsername: defaultUsername) else { return nil }
                    jumps.append(host)
                }
            }
        }
        guard jumps.count <= 4 else { return nil }
        return jumps + [target]
    }

    /// `[user@]host[:port]`, or `ssh://[user@]host[:port]`. As in OpenSSH the
    /// host starts after the last `@`, and an `ssh://` username is percent-decoded.
    private static func parseHop(_ value: String, defaultUsername: String?) -> SSHHost? {
        let isURI = value.lowercased().hasPrefix("ssh://")
        var rest = isURI ? String(value.dropFirst(6)) : value
        if isURI, rest.hasSuffix("/") { rest = String(rest.dropLast()) }
        var user = defaultUsername ?? ""
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at]); rest = String(rest[rest.index(after: at)...])
            if isURI { guard let decoded = user.removingPercentEncoding else { return nil }; user = decoded }
            guard !user.isEmpty, !user.hasPrefix("@"), !user.hasSuffix("@"), !user.contains("@@") else { return nil }
        }
        var port = 22
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") { guard let value = Int(tail.dropFirst()) else { return nil }; port = value }
            return SSHHost(hostname: host, port: port, username: user)
        }
        if let colon = rest.lastIndex(of: ":"), rest.filter({ $0 == ":" }).count == 1 {
            guard let value = Int(rest[rest.index(after: colon)...]) else { return nil }
            port = value; rest = String(rest[..<colon])
        }
        return rest.isEmpty ? nil : SSHHost(hostname: rest, port: port, username: user)
    }
}
