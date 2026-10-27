import Darwin
import Foundation
import XCTest
import WitermCore
@testable import WitermCLI
@testable import WitermAgent

final class CLIUnitTests: XCTestCase {
    func testParsesCommandsAndRejectsMisplacedOptions() throws {
        XCTAssertEqual(try CLIParser.parse([]).command, .help)
        XCTAssertEqual(try CLIParser.parse(["new", "--share", "--name", "api"]).command, .new(name: "api", share: true, detach: false))
        XCTAssertEqual(try CLIParser.parse(["share", "--wait", "5", "abcd"]).command, .share(session: "abcd", wait: 5))
        XCTAssertEqual(try CLIParser.parse(["attach", "abcd", "--view"]).command, .attach(session: "abcd", view: true))
        XCTAssertEqual(try CLIParser.parse(["ls", "--json"]), CLIInvocation(command: .sessions, json: true))
        XCTAssertEqual(try CLIParser.parse(["attach", "x", "--escape", "none"]).escape, nil)
        XCTAssertEqual(try CLIParser.parse(["attach", "x", "--escape", "^"]).escape, UInt8(ascii: "^"))
        for bad in [["bogus"], ["attach"], ["share", "--view"], ["sessions", "--share"], ["new", "--name"],
                    ["share", "--wait", "0"], ["attach", "x", "--escape", "ab"], ["status", "extra"], ["new", "--frobnicate"]] {
            XCTAssertThrowsError(try CLIParser.parse(bad), "\(bad)") { error in
                XCTAssertEqual((error as? CLIFailure)?.exit, .usage, "\(bad)")
            }
        }
    }

    func testEscapesWorkOnlyAtLineStart() {
        var filter = EscapeFilter(escape: UInt8(ascii: "~"))
        XCTAssertEqual(filter.feed(Array("ls ~/x\r".utf8)), [.send(Data("ls ~/x\r".utf8))])
        XCTAssertEqual(filter.feed(Array("~~".utf8)), [.send(Data("~".utf8))])
        XCTAssertEqual(filter.feed(Array("\r~?".utf8)), [.send(Data("\r".utf8)), .help])
        XCTAssertEqual(filter.feed(Array("~x".utf8)), [.send(Data("~x".utf8))])
        XCTAssertEqual(filter.feed(Array("\r~.ignored".utf8)), [.send(Data("\r".utf8)), .detach])
        var split = EscapeFilter(escape: UInt8(ascii: "~"))
        XCTAssertEqual(split.feed([UInt8(ascii: "~")]), [])
        XCTAssertEqual(split.feed([UInt8(ascii: ".")]), [.detach])
        var off = EscapeFilter(escape: nil)
        XCTAssertEqual(off.feed(Array("~.".utf8)), [.send(Data("~.".utf8))])
    }

    func testResolvesSessionsByIDPrefixAndName() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = LocalSessionInfo(id: "aaaa1111-0000-4000-8000-000000000001", name: "api", createdAt: date, columns: 80, rows: 24)
        let b = LocalSessionInfo(id: "aaaa2222-0000-4000-8000-000000000002", name: "web", createdAt: date, columns: 80, rows: 24)
        let c = LocalSessionInfo(id: "bbbb3333-0000-4000-8000-000000000003", name: "web", createdAt: date, columns: 80, rows: 24)
        let all = [a, b, c]
        XCTAssertEqual(try CLIRunner.resolve(a.id, in: all), a)
        XCTAssertEqual(try CLIRunner.resolve("api", in: all), a)
        XCTAssertEqual(try CLIRunner.resolve("AAAA1", in: all), a)
        XCTAssertEqual(try CLIRunner.resolve("bbbb", in: all), c)
        XCTAssertEqual((try? CLIRunner.resolve("aaaa", in: all)).map(\.id), nil, "An ambiguous prefix resolved")
        XCTAssertThrowsError(try CLIRunner.resolve("web", in: all)) { XCTAssertEqual(($0 as? CLIFailure)?.exit, .usage) }
        XCTAssertThrowsError(try CLIRunner.resolve("nope", in: all)) { XCTAssertEqual(($0 as? CLIFailure)?.exit, .notFound) }
    }

    func testNamesSessionsAfterTheirFolder() throws {
        XCTAssertEqual(try CLIRunner.sessionName(nil, directory: "/Users/me/projects/witerm"), "witerm")
        XCTAssertEqual(try CLIRunner.sessionName(nil, directory: "/"), "Terminal")
        XCTAssertEqual(try CLIRunner.sessionName(nil, directory: "/x/" + String(repeating: "a", count: 80)).count, 64)
        XCTAssertEqual(try CLIRunner.sessionName("  api  ", directory: "/x"), "api")
        XCTAssertThrowsError(try CLIRunner.sessionName("bad\u{7}", directory: "/x"))
    }

    func testRemoteStateIsOnlyReadyWhenAServerAccepted() {
        XCTAssertEqual(RemoteState([]), .off)
        XCTAssertEqual(RemoteState([LocalRelayStatus(server: "https://a.example", state: .connecting)]), .waiting)
        XCTAssertEqual(RemoteState([LocalRelayStatus(server: "https://a.example", state: .connecting),
                                    LocalRelayStatus(server: "https://b.example", state: .ready)]), .ready)
        XCTAssertEqual(CLIRunner.hosts([LocalRelayStatus(server: "http://localhost:8080", state: .ready)]), "localhost:8080")
    }

    func testFindsTheAppItIsInstalledFrom() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("witerm-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let helpers = root.appendingPathComponent("Witerm.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let plist: NSDictionary = ["WitermAppGroup": "group.com.witerm.TEAM123", "CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]
        XCTAssertTrue(plist.write(to: helpers.deletingLastPathComponent().appendingPathComponent("Info.plist"), atomically: true))
        let binary = helpers.appendingPathComponent("witerm")
        try Data().write(to: binary)
        let link = root.appendingPathComponent("bin/witerm")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let app = try XCTUnwrap(AgentLocator.containingApp(executable: link.path))
        XCTAssertEqual(app.appGroup, "group.com.witerm.TEAM123")
        XCTAssertEqual(app.version, "1.2 (34)")
        XCTAssertTrue(AgentLocator.socketURL(appGroup: app.appGroup).path
            .hasSuffix("/Library/Group Containers/group.com.witerm.TEAM123/local/agent.sock"))
        XCTAssertNil(AgentLocator.containingApp(executable: root.appendingPathComponent("elsewhere").path))
        XCTAssertFalse(AgentLocator.validGroup("group.$(TEAM)"))
    }
}

/// Runs the real `witerm` binary against a real broker and tmux.
@MainActor
final class CLIIntegrationTests: XCTestCase {
    private struct Result { let status: Int32; let output: String; let error: String }

    private var binary: URL {
        Bundle(for: CLIIntegrationTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("witerm")
    }

    private func witerm(_ arguments: [String], socket: URL, directory: URL? = nil, environment: [String: String] = [:]) throws -> Result {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["WITERM_AGENT_SOCKET": socket.path, "PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
                      error: String(decoding: error, as: UTF8.self))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func startBroker() throws -> (URL, AgentConfiguration, AgentBroker) {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build the witerm product first") }
        let url = URL(fileURLWithPath: "/private/tmp/witerm-cli-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        addTeardownBlock {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: url)
        }
        return (url, configuration, broker)
    }

    func testCommandsReportExactStateAndStableExitCodes() async throws {
        let (url, configuration, _) = try startBroker()
        let socket = url.appendingPathComponent("agent.sock")
        let work = url.appendingPathComponent("project dir", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)

        let status = try witerm(["status", "--json"], socket: socket)
        XCTAssertEqual(status.status, 0, status.error)
        let statusBody = try json(status.output)
        XCTAssertEqual(statusBody["service"] as? String, "running")
        XCTAssertEqual((statusBody["remote"] as? [String: Any])?["state"] as? String, "off")

        let created = try witerm(["new", "--share", "--json"], socket: socket, directory: work)
        XCTAssertEqual(created.status, 0, created.error)
        let createdBody = try json(created.output)
        let session = try XCTUnwrap(createdBody["session"] as? [String: Any])
        let id = try XCTUnwrap(session["id"] as? String)
        XCTAssertEqual(session["name"] as? String, "project dir")
        XCTAssertEqual(session["shared"] as? Bool, true)
        XCTAssertEqual((createdBody["remote"] as? [String: Any])?["state"] as? String, "off",
                       "Sharing must not claim remote access is ready")
        let pane = try CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
            .run(["-S", url.appendingPathComponent("tmux.sock").path, "display-message", "-p", "-t", "witerm-" + id, "#{pane_current_path}"])
        let real = try XCTUnwrap(realpath(work.path, nil).map { defer { free($0) }; return String(cString: $0) })
        XCTAssertEqual(String(decoding: pane.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), real)

        let human = try witerm(["new", "--detach", "--name", "second"], socket: socket, directory: work)
        XCTAssertEqual(human.status, 0, human.error)
        XCTAssertTrue(human.output.contains("Created “second”"), human.output)

        let unshared = try witerm(["unshare", String(id.prefix(6)), "--json"], socket: socket)
        XCTAssertEqual(unshared.status, 0, unshared.error)
        XCTAssertEqual((try json(unshared.output)["session"] as? [String: Any])?["shared"] as? Bool, false)

        // Inside a session, share needs no argument.
        let inside = try witerm(["share"], socket: socket, environment: ["WITERM_SESSION_ID": id])
        XCTAssertEqual(inside.status, 0, inside.error)
        XCTAssertTrue(inside.output.contains("Remote access is off"), inside.output)

        let listed = try witerm(["sessions", "--json"], socket: socket)
        let sessions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first { $0["id"] as? String == id }?["shared"] as? Bool, true)

        let waited = try witerm(["share", id, "--wait", "1"], socket: socket)
        XCTAssertEqual(waited.status, CLIExit.remoteNotReady.rawValue, "Waiting must fail while remote access is off")

        let missing = try witerm(["share", "nosuch", "--json"], socket: socket)
        XCTAssertEqual(missing.status, CLIExit.notFound.rawValue)
        XCTAssertEqual((try json(missing.error)["error"] as? [String: Any])?["code"] as? String, "not_found")
        XCTAssertEqual(try witerm(["share"], socket: socket).status, CLIExit.usage.rawValue)
        XCTAssertEqual(try witerm(["bogus"], socket: socket).status, CLIExit.usage.rawValue)
        XCTAssertEqual(try witerm(["attach", id], socket: socket).status, CLIExit.usage.rawValue, "attach without a terminal")
        let down = try witerm(["status"], socket: url.appendingPathComponent("missing/agent.sock"))
        XCTAssertEqual(down.status, CLIExit.serviceUnavailable.rawValue)
        XCTAssertTrue(down.error.contains("background service"), down.error)
    }

    func testAttachDrivesARealTerminalAndDetachesCleanly() async throws {
        let (url, _, _) = try startBroker()
        let socket = url.appendingPathComponent("agent.sock")
        let client = LocalAgentClient(socketURL: socket)
        let session = try await client.create(name: "Attach", cwd: url.path)
        let output = PTYCapture()
        let terminal = try PTYChild(executable: binary.path, arguments: ["attach", String(session.id.prefix(8))],
                                    environment: ["WITERM_AGENT_SOCKET": socket.path, "TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
                                    columns: 100, rows: 30)
        let ended = PTYCapture()
        terminal.start(output: { output.append($0); return true }, ended: { ended.append(Data([1])) })
        defer { terminal.stop() }
        try await eventually("witerm did not attach") { output.contains("attached to") }
        try terminal.send(Data("printf 'PTY_''%s\\n' \"$(stty size)\"\r".utf8))
        try await eventually("Input did not reach the session at the terminal's size") { output.contains("PTY_30 100") }

        // The terminal's size becomes the session grid.
        try terminal.resize(columns: 120, rows: 40)
        try await eventually("Resizing the terminal did not resize the session") {
            (try? await client.sessions().first { $0.id == session.id }).map { $0.columns == 120 && $0.rows == 40 } ?? false
        }
        let listed = try await client.sessions().first { $0.id == session.id }
        XCTAssertEqual(listed?.sharing?.controller, LocalAttachmentInfo(mode: .control, device: nil))

        // ~. detaches, restores the terminal, and releases control at once.
        try terminal.send(Data("\r~.".utf8))
        try await eventually("~. did not end witerm") { !ended.isEmpty }
        XCTAssertTrue(output.contains("detached"), "No detach message")
        XCTAssertTrue(output.contains("\u{1B}[?1049l"), "The terminal was not restored")
        let next = try await client.attach(sessionID: session.id)
        try await next.detach()
        let after = try await client.sessions().first { $0.id == session.id }
        XCTAssertEqual(after?.sharing?.attachments, [])
    }

    private func eventually(_ message: String, seconds: Double = 8, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail(message)
        throw CLIFailure(exit: .failure, code: "timeout", message: message)
    }
}

private final class PTYCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    func contains(_ marker: String) -> Bool { lock.withLock { bytes.range(of: Data(marker.utf8)) != nil } }
    var isEmpty: Bool { lock.withLock { bytes.isEmpty } }
}
