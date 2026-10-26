import Darwin
import Foundation
import WitermCore

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

private struct Evidence: Codable {
    let socketPath: String
    let sessionID: String
    let sessionName: String
    let nonce: String
    let shellPID: Int32
    let workerPID: Int32
    let workerIdentity: String
    var passed: [String]
    var cleaned = false
}

private actor Capture {
    private var bytes = Data()
    func append(_ value: Data) {
        bytes.append(value)
        if bytes.count > 1_048_576 { bytes.removeFirst(bytes.count - 1_048_576) }
    }
    func text() -> String { String(decoding: bytes, as: UTF8.self) }
}

private func collect(_ attachment: LocalTerminalAttachment, _ capture: Capture) -> Task<Void, Never> {
    Task {
        do { for try await data in attachment.output { await capture.append(data) } }
        catch { /* Transport errors are reported by the following bounded check. */ }
    }
}

private func waitFor(_ needle: String, in capture: Capture) async throws -> String {
    for _ in 0..<100 {
        let text = await capture.text()
        if text.contains(needle) { return text }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ProbeFailure("Terminal did not return the fresh probe result")
}

private func value(_ key: String, in text: String) throws -> String {
    let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: key) + "=([A-Za-z0-9-]+)")
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { throw ProbeFailure("Missing probe field") }
    return String(text[range])
}

private func identity(of worker: Int32, shell: Int32) throws -> String {
    guard worker > 1, shell > 1, kill(worker, 0) == 0, kill(shell, 0) == 0 else {
        throw ProbeFailure("Expected test process is no longer alive")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(worker), "-o", "ppid=", "-o", "lstart=", "-o", "comm="]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    process.waitUntilExit()
    let fields = text.split(whereSeparator: { $0.isWhitespace })
    guard process.terminationStatus == 0, fields.count >= 7, Int32(fields[0]) == shell,
          fields.last == "/bin/sleep" else { throw ProbeFailure("Test worker identity changed") }
    return text
}

private func validateEvidenceURL(_ url: URL) throws {
    let normalized = url.standardizedFileURL
    guard normalized.path.hasPrefix("/tmp/") || normalized.path.hasPrefix("/private/tmp/") else {
        throw ProbeFailure("Evidence must be kept in an owner-only temporary directory")
    }
    var info = stat()
    guard lstat(normalized.deletingLastPathComponent().path, &info) == 0,
          info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
        throw ProbeFailure("Evidence directory must be private and owned by the current user")
    }
}

private func readEvidence(_ url: URL) throws -> Evidence {
    try validateEvidenceURL(url)
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o777 == 0o600, info.st_size < 8192 else { throw ProbeFailure("Unsafe evidence file") }
    let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: url))
    guard UUID(uuidString: evidence.sessionID) != nil, UUID(uuidString: evidence.nonce) != nil,
          evidence.sessionName == "常驻验收 " + String(evidence.nonce.prefix(6)), !evidence.cleaned else {
        throw ProbeFailure("Evidence is invalid or already cleaned")
    }
    return evidence
}

private func save(_ evidence: Evidence, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func prepare(socket: URL, evidenceURL: URL) async throws {
    try validateEvidenceURL(evidenceURL)
    guard !FileManager.default.fileExists(atPath: evidenceURL.path) else { throw ProbeFailure("Evidence file already exists") }
    let client = LocalAgentClient(socketURL: socket)
    guard try await client.status().tmuxAvailable else { throw ProbeFailure("tmux is not available") }
    let nonce = UUID().uuidString.lowercased()
    let name = "常驻验收 " + String(nonce.prefix(6))
    let session = try await client.create(name: name)
    do {
        let attachment = try await client.attach(sessionID: session.id)
        let capture = Capture(); let reader = collect(attachment, capture)
        do {
            // Split marker literals so the echoed command cannot satisfy checks.
            let command = "witerm_probe_nonce='\(nonce)'; /bin/sleep 3600 & witerm_probe_worker=$!; printf 'WT_''SHELL=%s\\nWT_''WORKER=%s\\nWT_''NONCE=%s\\nWT_''READY\\n' \"$$\" \"$witerm_probe_worker\" \"$witerm_probe_nonce\"\n"
            try await attachment.send(Data(command.utf8))
            let text = try await waitFor("WT_READY", in: capture)
            guard let shell = Int32(try value("WT_SHELL", in: text)), let worker = Int32(try value("WT_WORKER", in: text)),
                  try value("WT_NONCE", in: text) == nonce else { throw ProbeFailure("Invalid test shell identity") }
            let evidence = Evidence(socketPath: socket.path, sessionID: session.id, sessionName: name, nonce: nonce,
                                    shellPID: shell, workerPID: worker, workerIdentity: try identity(of: worker, shell: shell), passed: ["prepared"])
            try save(evidence, to: evidenceURL)
            await attachment.disconnect(); reader.cancel()
            print("PASS prepared: \(name); shell=\(shell), worker=\(worker)")
        } catch {
            await attachment.disconnect(); reader.cancel(); throw error
        }
    } catch {
        // Only close the new disposable session, never other registered sessions.
        try? await client.close(sessionID: session.id)
        throw error
    }
}

private func verify(_ evidence: Evidence) async throws -> LocalAgentClient {
    guard try identity(of: evidence.workerPID, shell: evidence.shellPID) == evidence.workerIdentity else {
        throw ProbeFailure("Worker was replaced")
    }
    let client = LocalAgentClient(socketURL: URL(fileURLWithPath: evidence.socketPath))
    guard let session = try await client.sessions().first(where: { $0.id == evidence.sessionID }), session.name == evidence.sessionName else {
        throw ProbeFailure("The same test session was not recovered")
    }
    let attachment = try await client.attach(sessionID: evidence.sessionID)
    let capture = Capture(); let reader = collect(attachment, capture)
    do {
        let challenge = UUID().uuidString.lowercased()
        let command = "printf 'WT_''CHECK=%s\\nWT_''SHELL=%s\\nWT_''WORKER=%s\\nWT_''NONCE=%s\\n' '\(challenge)' \"$$\" \"$witerm_probe_worker\" \"$witerm_probe_nonce\"; if kill -0 \"$witerm_probe_worker\" 2>/dev/null; then printf 'WT_''ALIVE=yes\\n'; fi; printf 'WT_''DONE=%s\\n' '\(challenge)'\n"
        try await attachment.send(Data(command.utf8))
        let text = try await waitFor("WT_DONE=" + challenge, in: capture)
        guard let start = text.range(of: "WT_CHECK=" + challenge) else { throw ProbeFailure("Fresh probe challenge missing") }
        let fresh = String(text[start.lowerBound...])
        guard try value("WT_SHELL", in: fresh) == String(evidence.shellPID),
              try value("WT_WORKER", in: fresh) == String(evidence.workerPID),
              try value("WT_NONCE", in: fresh) == evidence.nonce,
              try value("WT_ALIVE", in: fresh) == "yes",
              try identity(of: evidence.workerPID, shell: evidence.shellPID) == evidence.workerIdentity else {
            throw ProbeFailure("Session process or shell state changed")
        }
        await attachment.disconnect(); reader.cancel()
        return client
    } catch {
        await attachment.disconnect(); reader.cancel(); throw error
    }
}

@main private struct RegisteredServiceProbe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw ProbeFailure("Usage: prepare <socket> <evidence> | verify <evidence> <phase> | cleanup <evidence>") }
        switch args[1] {
        case "prepare":
            guard args.count == 4 else { throw ProbeFailure("prepare needs a socket and evidence path") }
            try await prepare(socket: URL(fileURLWithPath: args[2]), evidenceURL: URL(fileURLWithPath: args[3]))
        case "verify":
            // The caller must separately establish that the named lifecycle
            // event occurred. This probe checks process/session continuity only.
            guard args.count == 4, ["app-exit", "app-reopen", "automatic-restart", "service-stop-start", "ios-background", "relay-restart", "control-handoff", "system-sleep"].contains(args[3]) else {
                throw ProbeFailure("Unknown verification phase")
            }
            let url = URL(fileURLWithPath: args[2]); var evidence = try readEvidence(url)
            _ = try await verify(evidence)
            evidence.passed.append(args[3]); try save(evidence, to: url)
            print("PASS \(args[3]): same session, shell PID, shell state and live worker PID")
        case "cleanup":
            guard args.count == 3 else { throw ProbeFailure("cleanup needs an evidence path") }
            let url = URL(fileURLWithPath: args[2]); var evidence = try readEvidence(url)
            let client = try await verify(evidence)
            // The worker identity has just been verified; signal only this test child.
            guard kill(evidence.workerPID, SIGTERM) == 0 else { throw ProbeFailure("Cannot stop test worker") }
            try await client.close(sessionID: evidence.sessionID)
            guard try await !client.sessions().contains(where: { $0.id == evidence.sessionID }) else {
                throw ProbeFailure("Test session was not removed")
            }
            var workerExited = false
            for _ in 0..<30 {
                if kill(evidence.workerPID, 0) != 0, errno == ESRCH { workerExited = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard workerExited else { throw ProbeFailure("Test worker did not exit") }
            evidence.cleaned = true; try save(evidence, to: url)
            print("PASS cleanup: disposable worker and session removed")
        default: throw ProbeFailure("Unknown operation")
        }
    }
}
