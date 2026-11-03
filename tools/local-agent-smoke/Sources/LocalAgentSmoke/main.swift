import Darwin
import Foundation
import WitermCore

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

actor Capture {
    private var bytes = Data()
    func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > 1_048_576 { bytes.removeFirst(bytes.count - 1_048_576) }
    }
    func text() -> String { String(decoding: bytes, as: UTF8.self) }
    func clear() { bytes.removeAll(keepingCapacity: true) }
}

func collect(_ attachment: LocalTerminalAttachment, into capture: Capture) -> Task<Void, Never> {
    Task {
        do { for try await data in attachment.output { await capture.append(data) } }
        catch { /* A deliberate agent restart ends the old stream. */ }
    }
}

func waitFor(_ needle: String, in capture: Capture) async throws {
    for _ in 0..<100 {
        if await capture.text().contains(needle) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw SmokeFailure("Expected terminal result was not received")
}

func shellPID(_ capture: Capture) async throws -> String {
    let text = await capture.text()
    let regex = try NSRegularExpression(pattern: "WT_PID=([0-9]+)")
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { throw SmokeFailure("Shell PID was missing") }
    return String(text[range])
}

/// Runs `seq 1 count` on an attachment read like the Mac window reads it
/// (events, with scrollback) by a deliberately slow renderer, and returns
/// the seconds until the shell's marker after the last line arrives. The
/// attachment must stay open throughout: nothing may end it for being slow.
func burst(_ attachment: LocalTerminalAttachment, lines count: Int, marker: Int) async throws -> Double {
    let started = Date()
    let reader = Task { () throws -> String in
        var tail = ""
        var events = 0
        for try await event in attachment.events {
            guard case .output(let data) = event else { continue }
            events += 1
            tail = String((tail + String(decoding: data, as: UTF8.self)).suffix(8192))
            if tail.contains("WT_BURST_\(marker)") { return tail }
            if events.isMultiple(of: 16) { try await Task.sleep(for: .milliseconds(5)) }
            if Date().timeIntervalSince(started) > 600 { throw SmokeFailure("A burst of \(count) lines didn't finish") }
        }
        throw SmokeFailure("The attachment ended during a burst of \(count) lines")
    }
    try await Task.sleep(for: .milliseconds(300))
    // macOS seq writes 1000000 as 1e+06 without a format.
    try await attachment.send(Data("seq -f '%.0f' 1 \(count); printf 'WT_''BURST_%s\\n' \(marker)\n".utf8))
    let tail = try await reader.value
    // The last line comes right before the marker: nothing at the end was lost.
    guard let end = tail.range(of: "WT_BURST_\(marker)"), tail[..<end.lowerBound].contains("\(count)")
    else { throw SmokeFailure("The last line of a burst of \(count) lines was missing") }
    return Date().timeIntervalSince(started)
}

func startAgent(executable: URL, state: URL) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--state-directory", state.path, "--shell-path", "/bin/sh"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func waitForAgent(_ client: LocalAgentClient) async throws {
    for _ in 0..<60 {
        if let status = try? await client.status(), status.tmuxAvailable { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw SmokeFailure("Local agent did not become ready")
}

@main struct Smoke {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw SmokeFailure("Usage: LocalAgentSmoke /absolute/path/to/witerm-agent") }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let state = URL(fileURLWithPath: "/tmp/wt-smoke-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var agent: Process?
        defer {
            if let agent, agent.isRunning { agent.terminate(); agent.waitUntilExit() }
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
            cleanup.arguments = ["-S", state.appendingPathComponent("tmux.sock").path, "kill-server"]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
            try? FileManager.default.removeItem(at: state)
        }
        agent = try startAgent(executable: executable, state: state)
        let client = LocalAgentClient(socketURL: state.appendingPathComponent("agent.sock"))
        try await waitForAgent(client)
        let session = try await client.create(name: "Smoke", columns: 80, rows: 24)
        let first = try await client.attach(sessionID: session.id)
        let capture = Capture()
        var reader = collect(first, into: capture)
        try await first.send(Data("printf 'WT_''PID=%s\\n' \"$$\"; printf 'WT_''READY\\n'\n".utf8))
        try await waitFor("WT_READY", in: capture)
        let originalPID = try await shellPID(capture)
        // This Mac's own clients type together; the second keeps the first's grid.
        let second = try await client.attach(sessionID: session.id, columns: 100, rows: 30)
        guard second.session.columns == 80 else { throw SmokeFailure("A joining writer took over the grid") }
        try await second.send(Data("printf 'WT_''SECOND\\n'\n".utf8))
        try await waitFor("WT_SECOND", in: capture)
        try await second.detach()
        // A paired device not allowed to type alongside is refused, never takes over.
        let phone = LocalRemotePeer(deviceID: UUID().uuidString.lowercased(), name: "Smoke phone")
        _ = try await client.deviceAccess(LocalDeviceAccess(deviceID: phone.deviceID, scope: .all, permission: .control, coTyping: false))
        do {
            let unexpected = try await client.attach(sessionID: session.id, peer: phone)
            await unexpected.disconnect()
            throw SmokeFailure("A device without shared typing took control")
        } catch LocalAgentClientError.rejected(.sessionBusy) { }
        let observer = try await client.attach(sessionID: session.id, mode: .view)
        do { try await observer.send(Data("invalid\n".utf8)); throw SmokeFailure("Observer input accepted") }
        catch LocalAgentClientError.rejected(.readOnly) { }
        do { try await observer.resize(columns: 90, rows: 30); throw SmokeFailure("Observer resize accepted") }
        catch LocalAgentClientError.rejected(.readOnly) { }
        await observer.disconnect()
        try await first.resize(columns: 103, rows: 37)
        await capture.clear()
        try await first.send(Data("stty size; printf 'WT_''SIZE\\n'\n".utf8))
        try await waitFor("WT_SIZE", in: capture)
        guard await capture.text().contains("37 103") else { throw SmokeFailure("Shell size did not follow resize") }
        try await first.send(Data("printf '\\033[?1049h\\033[2J\\033[HWT_''ALT\\n'\n".utf8))
        try await waitFor("WT_ALT", in: capture)
        await first.disconnect(); reader.cancel()
        let reattached = try await client.attach(sessionID: session.id, columns: 103, rows: 37)
        await capture.clear(); reader = collect(reattached, into: capture)
        try await waitFor("WT_ALT", in: capture)
        try await reattached.send(Data("printf '\\033[?1049l'\n".utf8))
        await capture.clear()
        try await reattached.send(Data("printf 'WT_''PID=%s\\n' \"$$\"; printf 'WT_''AGAIN\\n'\n".utf8))
        try await waitFor("WT_AGAIN", in: capture)
        guard try await shellPID(capture) == originalPID else { throw SmokeFailure("Shell changed on reconnect") }
        agent?.terminate(); agent?.waitUntilExit(); reader.cancel()
        agent = try startAgent(executable: executable, state: state)
        try await waitForAgent(client)
        guard try await client.sessions().contains(where: { $0.id == session.id }) else { throw SmokeFailure("Session missing after restart") }
        let restarted = try await client.attach(sessionID: session.id, columns: 103, rows: 37)
        await capture.clear(); reader = collect(restarted, into: capture)
        try await restarted.send(Data("printf 'WT_''PID=%s\\n' \"$$\"; printf 'WT_''RESTART\\n'\n".utf8))
        try await waitFor("WT_RESTART", in: capture)
        guard try await shellPID(capture) == originalPID else { throw SmokeFailure("Shell changed after agent restart") }
        // Renaming while attached changes only metadata; the same shell keeps running.
        let renamed = try await client.rename(sessionID: session.id, to: "Smoke renamed")
        guard renamed.name == "Smoke renamed",
              try await client.sessions().first(where: { $0.id == session.id })?.name == "Smoke renamed"
        else { throw SmokeFailure("Rename was not stored") }
        await capture.clear()
        try await restarted.send(Data("printf 'WT_''PID=%s\\n' \"$$\"; printf 'WT_''RENAMED\\n'\n".utf8))
        try await waitFor("WT_RENAMED", in: capture)
        guard try await shellPID(capture) == originalPID else { throw SmokeFailure("Shell changed after rename") }
        await restarted.disconnect(); reader.cancel()
        // Bursts far bigger than any queue, read slowly: the window's reader
        // waits, the agent stops reading the pane meanwhile, tmux coalesces
        // the screen, and the attachment stays open.
        var timings: [String] = []
        for (index, lines) in [100_000, 1_000_000].enumerated() {
            let slow = try await client.attach(sessionID: session.id, columns: 103, rows: 37, history: true)
            let seconds = try await burst(slow, lines: lines, marker: 70 + index)
            timings.append("\(lines) lines \(String(format: "%.1f", seconds)) s")
            await slow.disconnect()
        }
        try await client.close(sessionID: session.id)
        guard try await client.sessions().isEmpty else { throw SmokeFailure("Close left a session") }
        print("PASS: real PTY input, resize, shared typing with a refused paired writer, read-only, alternate-screen repaint, reconnect, agent restart, rename, bursts to a slow renderer (\(timings.joined(separator: ", "))) and explicit close")
    }
}
