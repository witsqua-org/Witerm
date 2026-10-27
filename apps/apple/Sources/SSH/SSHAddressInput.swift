import Foundation
import WitermSSH

/// One field for an SSH destination, written the way people already type it:
/// `user@host`, `user@host:port`, `user@[fe80::1]:2222`, or `ssh://user@host`.
enum SSHAddressInput {
    struct Parsed: Equatable {
        var username: String
        var hostname: String
        var port: Int
    }

    enum Problem: Equatable { case empty, missingUser, invalidHost, invalidPort }

    static func parse(_ text: String) -> Result<Parsed, ProblemError> {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix("ssh://") { rest = String(rest.dropFirst(6)) }
        if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
        guard !rest.isEmpty else { return .failure(ProblemError(.empty)) }
        var username = ""
        if let at = rest.lastIndex(of: "@") {
            username = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var hostname = rest
        var port = 22
        if rest.hasPrefix("[") {
            // Bracketed IPv6, optionally followed by :port.
            guard let close = rest.firstIndex(of: "]") else { return .failure(ProblemError(.invalidHost)) }
            hostname = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":"), let value = Int(tail.dropFirst()) else { return .failure(ProblemError(.invalidPort)) }
                port = value
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            hostname = String(rest[..<colon])
            guard let value = Int(rest[rest.index(after: colon)...]) else { return .failure(ProblemError(.invalidPort)) }
            port = value
        }
        guard (1...65535).contains(port) else { return .failure(ProblemError(.invalidPort)) }
        guard !hostname.isEmpty, hostname.utf8.count <= 253,
              !hostname.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "@" || $0 == "/" }),
              !hostname.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return .failure(ProblemError(.invalidHost)) }
        guard !username.isEmpty else { return .failure(ProblemError(.missingUser)) }
        guard username.utf8.count <= 255, !username.contains(where: \.isWhitespace),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return .failure(ProblemError(.missingUser)) }
        return .success(Parsed(username: username, hostname: hostname, port: port))
    }

    /// The field text for a saved host. The default port is left out.
    static func format(_ host: SSHHost) -> String {
        guard !host.hostname.isEmpty else { return "" }
        let user = host.username.isEmpty ? "" : host.username + "@"
        guard host.port != 22 else { return user + host.hostname }
        let name = host.hostname.contains(":") ? "[\(host.hostname)]" : host.hostname
        return user + name + ":" + String(host.port)
    }

    struct ProblemError: Error, Equatable {
        let problem: Problem
        init(_ problem: Problem) { self.problem = problem }

        var message: String {
            switch problem {
            case .empty: String(localized: "Enter an address, like deploy@server.example.com.", bundle: .main)
            case .missingUser: String(localized: "Add the username before @, like deploy@server.example.com.", bundle: .main)
            case .invalidHost: String(localized: "Enter a valid host address without spaces.", bundle: .main)
            case .invalidPort: String(localized: "After the colon, use a port from 1 to 65535.", bundle: .main)
            }
        }
    }
}
