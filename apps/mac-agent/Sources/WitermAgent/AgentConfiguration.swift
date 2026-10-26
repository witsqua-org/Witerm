import Darwin
import Foundation
import WitermCore

struct AgentFailure: Error {
    let code: LocalAgentErrorCode
    init(_ code: LocalAgentErrorCode = .unavailable) { self.code = code }
}

struct AgentConfiguration: Sendable {
    let stateDirectory: URL
    let tmuxPath: String?
    let shellPath: String
    let loginShell: Bool
    let environment: [String: String]

    init(stateDirectory: URL, tmuxPath: String? = nil, shellPath: String? = nil) throws {
        guard stateDirectory.isFileURL, stateDirectory.path.hasPrefix("/"), geteuid() != 0 else { throw AgentFailure() }
        self.stateDirectory = stateDirectory
        let fm = FileManager.default
        if let tmuxPath {
            guard tmuxPath.hasPrefix("/"), fm.isExecutableFile(atPath: tmuxPath) else { throw AgentFailure(.dependencyMissing) }
            self.tmuxPath = tmuxPath
        } else {
            self.tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { fm.isExecutableFile(atPath: $0) }
        }
        // Read passwd data before starting worker threads; no Swift executes in a
        // forked child. The configured shell is never supplied through RPC.
        let entry = getpwuid(geteuid())
        let userShell = entry?.pointee.pw_shell.map { String(cString: $0) } ?? "/bin/zsh"
        let userName = entry?.pointee.pw_name.map { String(cString: $0) } ?? NSUserName()
        let home = entry?.pointee.pw_dir.map { String(cString: $0) } ?? fm.homeDirectoryForCurrentUser.path
        self.shellPath = shellPath ?? userShell
        self.loginShell = shellPath == nil
        guard self.shellPath.hasPrefix("/"), fm.isExecutableFile(atPath: self.shellPath) else { throw AgentFailure() }
        environment = [
            "HOME": home, "USER": userName, "LOGNAME": userName,
            "SHELL": self.shellPath, "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
    }
}

func wireEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

func wireDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

func validSessionID(_ id: String) -> Bool {
    UUID(uuidString: id)?.uuidString.lowercased() == id
}

func validDimensions(columns: Int, rows: Int) -> Bool { (20...500).contains(columns) && (5...200).contains(rows) }
