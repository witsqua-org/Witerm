import Foundation

/// What a typed continuation server address means: the address Witerm would
/// use, or why it can't be one, with a corrected address when there is one.
/// A bare host gets `https://`; plain HTTP is only for a server on this device,
/// as `PairingServerAddress` requires.
struct ServerAddressInput: Equatable {
    enum Problem: Equatable {
        case empty
        case spaces
        /// `user@host`: an SSH login, not a server.
        case sshLogin
        /// `ssh://` or port 22.
        case sshPort
        /// A pasted `witerm://pair` or `witerm://share` link.
        case invitation
        case credentials
        case path(String)
        case insecure
        case unsupportedScheme(String)
        case invalid
    }

    /// The address to save, when it is usable as typed.
    let address: String?
    let problem: Problem?
    /// A usable address close to what was typed.
    let fix: String?
    /// What to put in the SSH host form, for addresses that look like SSH.
    let sshAddress: String?

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ problem: Problem, fix: String? = nil, ssh: String? = nil) -> (String?, Problem?, String?, String?) {
            (nil, problem, fix, ssh)
        }
        let result: (String?, Problem?, String?, String?) = {
            if trimmed.isEmpty { return fail(.empty) }
            if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return fail(.spaces) }
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("witerm://") { return fail(.invitation) }
            if lowered.hasPrefix("ssh://") {
                let parts = URLComponents(string: trimmed)
                return fail(.sshPort, ssh: parts.flatMap(Self.sshAddress(from:)))
            }
            let hasScheme = trimmed.contains("://")
            // Without a scheme, `@` is an SSH login (`user@host`).
            if !hasScheme, trimmed.contains("@") { return fail(.sshLogin, ssh: trimmed) }
            let probe = hasScheme ? trimmed : "https://" + trimmed
            guard let parsed = URLComponents(string: probe), let scheme = parsed.scheme?.lowercased(),
                  let rawHost = parsed.host, !rawHost.isEmpty else { return fail(.invalid) }
            let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard scheme == "http" || scheme == "https" else { return fail(.unsupportedScheme(scheme)) }
            let local = Self.isLoopback(host)
            // No scheme typed: plain HTTP only on this device.
            let chosen = hasScheme ? scheme : (local ? "http" : "https")
            let port = parsed.port
            let secure = Self.root(scheme: "https", host: host, port: port == 80 ? nil : port)
            let typed = Self.root(scheme: chosen, host: host, port: port)
            if port == 22 { return fail(.sshPort, ssh: Self.sshAddress(from: parsed)) }
            if parsed.user != nil || parsed.password != nil { return fail(.credentials, fix: typed) }
            if !(parsed.path.isEmpty || parsed.path == "/") || parsed.query != nil || parsed.fragment != nil {
                var extra = parsed.path
                if let query = parsed.query { extra += "?" + query }
                return fail(.path(extra), fix: typed)
            }
            if chosen == "http", !local { return fail(.insecure, fix: secure) }
            return (typed, nil, nil, nil)
        }()
        address = result.0
        problem = result.1
        fix = result.2
        sshAddress = result.3
    }

    /// `scheme://host[:port]`, with default ports dropped and IPv6 bracketed.
    private static func root(scheme: String, host: String, port: Int?) -> String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(shownHost)" + (port.map { $0 == defaultPort ? "" : ":\($0)" } ?? "")
    }

    private static func sshAddress(from parts: URLComponents) -> String? {
        guard let host = parts.host, !host.isEmpty else { return nil }
        let user = parts.user.map { "\($0)@" } ?? ""
        let port = parts.port.map { $0 == 22 ? "" : ":\($0)" } ?? ""
        return user + host + port
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare == "localhost" || bare == "::1" { return true }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { part in
            guard let value = Int(part), String(value) == part else { return false }
            return (0...255).contains(value)
        }
    }

    /// One line saying what the problem is.
    var title: String? {
        switch problem {
        case nil, .empty?: nil
        case .spaces?: String(localized: "Addresses can’t contain spaces.", bundle: .main)
        case .sshLogin?: String(localized: "This looks like an SSH login", bundle: .main)
        case .sshPort?: String(localized: "Port 22 is for SSH", bundle: .main)
        case .invitation?: String(localized: "This is an invitation, not a server address", bundle: .main)
        case .credentials?: String(localized: "Remove the user name and password", bundle: .main)
        case .path?: String(localized: "Use the server’s root address", bundle: .main)
        case .insecure?: String(localized: "Use HTTPS", bundle: .main)
        case .unsupportedScheme?: String(localized: "Use an HTTPS address", bundle: .main)
        case .invalid?: String(localized: "This isn’t a server address", bundle: .main)
        }
    }

    /// What to do about it.
    var detail: String? {
        switch problem {
        case nil, .empty?, .spaces?: nil
        case .sshLogin?: String(localized: "Continuation servers don’t use a user name. To open a terminal on a computer, add it as an SSH host.", bundle: .main)
        case .sshPort?: String(localized: "Add this computer under SSH Hosts, or enter the continuation server’s own port.", bundle: .main)
        case .invitation?: String(localized: "Use it with Continue from Another Device. It already names its server.", bundle: .main)
        case .credentials?: String(localized: "Continuation servers don’t sign in this way.", bundle: .main)
        case .path(let path)?: String(localized: "Remove “\(path)”. Witerm adds the paths it needs.", bundle: .main)
        case .insecure?: String(localized: "Only a server on this device can use plain HTTP.", bundle: .main)
        case .unsupportedScheme(let scheme)?: String(localized: "Witerm servers use HTTPS, not \(scheme).", bundle: .main)
        case .invalid?: String(localized: "Enter a host name, such as witerm.example.com.", bundle: .main)
        }
    }
}
