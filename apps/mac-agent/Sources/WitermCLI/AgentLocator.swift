import Darwin
import Foundation

/// Finds the background service socket and version of the Witerm app this
/// command belongs to. The installed command is a symlink into the app bundle,
/// so it always matches the service it talks to.
enum AgentLocator {
    struct App: Equatable {
        let bundle: URL
        let appGroup: String
        let version: String
    }

    static func socketURL(override: String?, environment: [String: String]) throws -> URL {
        if let path = override ?? environment["WITERM_AGENT_SOCKET"], !path.isEmpty {
            guard path.hasPrefix("/") else { throw CLIFailure.usage("The socket path must be absolute.") }
            return URL(fileURLWithPath: path)
        }
        guard let app = containingApp() else {
            throw CLIFailure(exit: .serviceUnavailable, code: "not_installed",
                             message: "This witerm isn't part of a Witerm app. Install it from Witerm → Settings → Command Line Tools.")
        }
        return socketURL(appGroup: app.appGroup)
    }

    /// The group container path, built directly: a command-line tool has no
    /// App Group entitlement for the system to resolve it from.
    static func socketURL(appGroup: String) -> URL {
        URL(fileURLWithPath: homeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroup, isDirectory: true)
            .appendingPathComponent("local/agent.sock")
    }

    /// The app whose `Contents/Helpers` holds this executable.
    static func containingApp(executable: String? = executablePath()) -> App? {
        guard let executable, let resolved = realpath(executable, nil) else { return nil }
        defer { free(resolved) }
        let contents = URL(fileURLWithPath: String(cString: resolved))
            .deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              let group = info["WitermAppGroup"] as? String, validGroup(group) else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String
        return App(bundle: contents.deletingLastPathComponent(), appGroup: group,
                   version: build.map { "\(short) (\($0))" } ?? short)
    }

    static func validGroup(_ group: String) -> Bool {
        !group.isEmpty && group.utf8.count < 200 && !group.contains("$(") && !group.hasPrefix(".")
            && group.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
            }
    }

    private static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The account's home directory, not `$HOME`, which a shell may override.
    private static func homeDirectory() -> String {
        if let entry = getpwuid(geteuid()), let directory = entry.pointee.pw_dir {
            return FileManager.default.string(withFileSystemRepresentation: directory, length: strlen(directory))
        }
        return NSHomeDirectory()
    }
}
