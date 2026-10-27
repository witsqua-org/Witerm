import Darwin
import Foundation
import XCTest
import WitermCore
@testable import WitermAgent

final class TerminalGeometryScreen: @unchecked Sendable {
    private let lock = NSLock()
    private let runner: CommandRunner
    private let base: [String]
    private let target: String
    private let fifo: URL
    private var writer: Int32 = -1

    init(directory: URL, configuration: AgentConfiguration, columns: Int, rows: Int) throws {
        runner = CommandRunner(executable: try XCTUnwrap(configuration.tmuxPath), environment: configuration.environment)
        base = ["-S", directory.appendingPathComponent("tmux.sock").path, "-f", "/dev/null"]
        target = "render-" + UUID().uuidString.lowercased()
        fifo = directory.appendingPathComponent(target + ".fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw AgentFailure() }
        do {
            // The shell text is fixed. The FIFO path is a separately quoted argv
            // parameter; cat reads the FIFO file, never cooked TTY stdin/ECHO.
            let result = try runner.run(base + ["new-session", "-d", "-s", target,
                "-x", String(columns), "-y", String(rows), "--", "/bin/sh", "-c",
                "stty raw -echo; exec /bin/cat \"$1\"", "renderer", fifo.path])
            guard result.status == 0 else { throw AgentFailure() }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            repeat {
                writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if writer >= 0 { break }
                guard errno == ENXIO || errno == EINTR else { throw AgentFailure() }
                usleep(5_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard writer >= 0, fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else { throw AgentFailure() }
            var info = stat()
            guard fstat(writer, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFIFO,
                  info.st_mode & 0o7777 == 0o600 else { throw AgentFailure() }
        } catch {
            if writer >= 0 { Darwin.close(writer); writer = -1 }
            _ = try? runner.run(base + ["kill-session", "-t", target])
            _ = unlink(fifo.path)
            throw error
        }
    }

    func accept(_ event: LocalTerminalEvent) throws {
        try lock.withLock {
            guard writer >= 0 else { throw AgentFailure() }
            switch event {
            case .geometry(let session):
                let result = try runner.run(base + ["resize-window", "-t", target,
                    "-x", String(session.columns), "-y", String(session.rows)])
                guard result.status == 0 else { throw AgentFailure() }
            case .output(let bytes):
                guard Posix.writeAll(writer, data: bytes, timeout: 1) else { throw AgentFailure(.backpressure) }
            }
        }
    }

    func contains(_ marker: String) throws -> Bool {
        guard lock.withLock({ writer >= 0 }) else { throw AgentFailure() }
        let result = try runner.run(base + ["capture-pane", "-p", "-t", target])
        guard result.status == 0 else { throw AgentFailure() }
        // Snapshot inspection must not block the FIFO producer's lock. Only a
        // boolean leaves this method; no screen/VT is persisted or logged.
        return result.output.range(of: Data(marker.utf8)) != nil
    }

    func diagnosticFlags() throws -> String {
        try lock.withLock {
            let result = try runner.run(base + ["capture-pane", "-p", "-t", target])
            let terms = ["GRID_", "GRID_30_100", "宽", "🙂"]
            let text = String(decoding: result.output, as: UTF8.self)
            let range = text.range(of: "GRID_[0-9]+_[0-9]+", options: .regularExpression)
            let grid = range.map { String(text[$0]) } ?? "none"
            let state = try runner.run(base + ["display-message", "-p", "-t", target,
                "#{session_name}|#{pane_width}|#{pane_height}|#{alternate_on}|#{pane_current_command}"])
            let fields = String(decoding: state.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            let shape = fields.count == 5 ? "owned=\(fields[0] == target),cols=\(Int(fields[1]) ?? -1),rows=\(Int(fields[2]) ?? -1),alt=\(fields[3] == "1"),cat=\(fields[4] == "cat")" : "unknown"
            return "grid=\(grid),\(shape)," + terms.enumerated().map { "flag\($0.offset)=\(result.output.range(of: Data($0.element.utf8)) != nil)" }.joined(separator: ",")
        }
    }

    func close() {
        lock.withLock {
            guard writer >= 0 else { return }
            Darwin.close(writer); writer = -1
            _ = try? runner.run(base + ["kill-session", "-t", target])
            _ = unlink(fifo.path)
        }
    }
    deinit { close() }
}

// Shared by the local and real relay tests; both byte storage and geometry
// history are bounded, independently of the producer's own delivery budget.
actor TerminalGeometryCapture {
    private var bytes = Data()
    private var changes: [(LocalSessionInfo, Int)] = []
    private(set) var finished = false
    private var errorTag = "none"
    private var outputEvents = 0
    private let screen: TerminalGeometryScreen?
    private let initialSession: LocalSessionInfo?
    init(screen: TerminalGeometryScreen? = nil, initialSession: LocalSessionInfo? = nil) {
        self.screen = screen; self.initialSession = initialSession
    }
    func append(_ event: LocalTerminalEvent) throws {
        try screen?.accept(event)
        switch event {
        case .output(let data):
            guard bytes.count + data.count <= 262_144 else { throw LocalAgentClientError.backpressure }
            bytes.append(data)
            outputEvents += 1
        case .geometry(let session):
            guard changes.count < 64 else { throw LocalAgentClientError.backpressure }
            changes.append((session, bytes.count))
        }
    }
    func geometries() -> [LocalSessionInfo] { changes.map(\.0) }
    func contains(_ marker: String) -> Bool { bytes.range(of: Data(marker.utf8)) != nil }
    func markerFollowsGeometry(_ marker: String, columns: Int, rows: Int) -> Bool {
        guard let change = changes.last(where: { $0.0.columns == columns && $0.0.rows == rows }),
              let range = bytes.range(of: Data(marker.utf8)) else { return false }
        return range.lowerBound >= change.1
    }
    func rendered(_ marker: String, columns: Int, rows: Int) async throws -> Bool {
        guard let session = changes.last?.0 ?? initialSession,
              session.columns == columns, session.rows == rows,
              bytes.count > (changes.last?.1 ?? 0) else { return false }
        let screen = screen
        // A bounded, one-at-a-time snapshot task lets this actor keep draining
        // real events while the independent tmux renderer answers inspection.
        return try await Task.detached { try screen?.contains(marker) ?? false }.value
    }
    func diagnostics() -> String { "bytes=\(bytes.count), outputs=\(outputEvents), geometries=\(changes.count), failure=\(errorTag), finished=\(finished)" }
    func finish(error: Error? = nil) {
        guard !finished else { return }
        finished = true
        if let error = error as? AgentFailure { errorTag = "sink_" + error.code.rawValue }
        else if let error = error as? LocalAgentClientError { errorTag = String(describing: error) }
        else if error != nil { errorTag = "other" }
    }
}

func geometryScreenInput() -> Data {
    // A real foreground process redraws its alternate screen on SIGWINCH.
    // UTF-8 runs and rapid redraws exercise stream fragments; format placeholders
    // ensure command echo cannot satisfy the GRID_<rows>_<cols> result.
    Data(("/bin/sh -c 'fill=\"\"; i=0; while [ \"$i\" -lt 256 ]; do fill=\"${fill}🙂\"; i=$((i+1)); done; " +
          "draw() { set -- $(stty size); printf \"\\033[2J\\033[H%s\\033[HGRID_%s_%s_宽🙂\\033[3;%sHEDGE_%s_%s\" \"$fill\" \"$1\" \"$2\" \"$(($2-18))\" \"$1\" \"$2\"; }; " +
          "trap draw WINCH; printf \"\\033[?1049h\"; draw; while :; do sleep 0.05; done'\n").utf8)
}

@MainActor
final class AgentTests: XCTestCase {
    private var inbound: [Int32: Data] = [:]
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/witerm-agent-test-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPrivateStateRejectsUnsafeDirectoryAndExclusiveBroker() throws {
        let url = try directory()
        XCTAssertEqual(chmod(url.path, 0o755), 0)
        XCTAssertThrowsError(try PrivateState(directory: url))
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        let state = try PrivateState(directory: url)
        XCTAssertThrowsError(try PrivateState(directory: url))
        withExtendedLifetime(state) {}
        let link = url.deletingLastPathComponent().appendingPathComponent("witerm-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try PrivateState(directory: link))
    }

    func testDimensionsAndUUIDBoundary() {
        XCTAssertTrue(validDimensions(columns: 80, rows: 24))
        XCTAssertFalse(validDimensions(columns: 19, rows: 24))
        XCTAssertFalse(validDimensions(columns: 80, rows: 201))
        XCTAssertTrue(validSessionID(UUID().uuidString.lowercased()))
        XCTAssertFalse(validSessionID("session; kill-server"))
        XCTAssertFalse(validSessionID(UUID().uuidString.uppercased()))
    }

    private func connect(_ socket: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentFailure() }
        var address = try Posix.address(socket.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw AgentFailure() }
        try Posix.nonblocking(fd)
        Posix.noSignalPipe(fd)
        inbound.removeValue(forKey: fd)
        return fd
    }

    private func readFrame(_ fd: Int32) throws -> LocalAgentFrame {
        var bytes = inbound.removeValue(forKey: fd) ?? Data(), buffer = [UInt8](repeating: 0, count: 4096)
        let end = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < end {
            if let line = bytes.firstIndex(of: 10) {
                inbound[fd] = Data(bytes[bytes.index(after: line)...])
                return try wireDecoder().decode(LocalAgentFrame.self, from: Data(bytes[..<line]))
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
            var polled = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&polled, 1, 25)
        }
        throw AgentFailure()
    }

    func testBrokerRejectsMalformedUnknownAndOversizedFrames() throws {
        let url = try directory()
        let broker = try AgentBroker(configuration: AgentConfiguration(stateDirectory: url))
        try broker.start()
        defer { broker.stop() }
        var socketStat = stat()
        XCTAssertEqual(lstat(url.appendingPathComponent("agent.sock").path, &socketStat), 0)
        XCTAssertEqual(socketStat.st_mode & 0o777, 0o600)
        let id = UUID().uuidString.lowercased()
        for (request, expected) in [
            ("{\"version\":2,\"id\":\"\(id)\",\"operation\":\"status\"}\n", LocalAgentErrorCode.unsupportedVersion),
            ("{\"version\":1,\"id\":\"\(id)\",\"operation\":\"status\",\"command\":\"ignored\"}\n", .invalidRequest),
            ("not-json\n", .invalidRequest),
            (String(repeating: "a", count: 65537) + "\n", .invalidRequest)
        ] {
            let fd = try connect(url.appendingPathComponent("agent.sock"))
            defer { Darwin.close(fd) }
            XCTAssertTrue(Posix.sameUser(fd))
            _ = Posix.writeAll(fd, data: Data(request.utf8))
            let frame = try readFrame(fd)
            XCTAssertEqual(frame.ok, false)
            XCTAssertEqual(frame.error, expected)
        }
    }

    func testBoundedDeliveryStopsBeforeDroppingVT() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[1]) }
        let connection = try AgentConnection(descriptor: pair[0], received: { _, _ in }, disconnected: { _, _ in })
        let output = LocalAgentFrame(kind: .output, data: Data(repeating: 65, count: 8192))
        var accepted = 0
        for _ in 0..<100 {
            if connection.enqueue(output) { accepted += 1 }
        }
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertLessThan(accepted, 30)
        connection.start()
        connection.finish(afterFlush: false)
    }

    func testConnectionAndSessionLimits() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment).run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        for index in 0..<16 { _ = try await client.create(name: "Limit \(index)") }
        do { _ = try await client.create(name: "Overflow"); XCTFail("17th session accepted") }
        catch LocalAgentClientError.rejected(.unavailable) { }
        let sessions = try await client.sessions()
        XCTAssertEqual(sessions.count, 16)
        var descriptors: [Int32] = []
        defer { for fd in descriptors { Darwin.close(fd) } }
        // Let the preceding short RPC sockets finish their asynchronous close.
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<32 { descriptors.append(try connect(url.appendingPathComponent("agent.sock"))) }
        let excess = try connect(url.appendingPathComponent("agent.sock"))
        defer { Darwin.close(excess) }
        var closed = false
        for _ in 0..<100 {
            var byte: UInt8 = 0
            if Darwin.read(excess, &byte, 1) == 0 { closed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(closed, "33rd connection was not rejected")
    }

    func testFailedTmuxQueryPreservesMetadataUntilServerIsConfirmedGone() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let proxy = url.appendingPathComponent("tmux-test-proxy")
        let failureMarker = URL(fileURLWithPath: proxy.path + ".fail")
        // A test-only argv-preserving proxy induces list failure while the real
        // tmux server stays alive. No production runner injection is introduced.
        let script = """
        #!/bin/sh
        if [ "$5" = "list-sessions" ] && [ -f "${0}.fail" ]; then
          exit 1
        fi
        exec /opt/homebrew/bin/tmux "$@"
        """
        try Data(script.utf8).write(to: proxy)
        XCTAssertEqual(chmod(proxy.path, 0o700), 0)
        let configuration = try AgentConfiguration(stateDirectory: url, tmuxPath: proxy.path, shellPath: "/bin/sh")
        let state = try PrivateState(directory: url)
        let engine = try TmuxEngine(state: state, configuration: configuration)
        let cleanup = CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
        defer { _ = try? cleanup.run(["-S", state.tmuxSocketURL.path, "kill-server"]) }
        let session = try engine.create(name: "Preserved task", columns: 80, rows: 24)
        let metadataURL = url.appendingPathComponent("sessions.json")
        let originalMetadata = try Data(contentsOf: metadataURL)
        XCTAssertFalse(try state.tmuxServerIsAbsent())

        try Data().write(to: failureMarker)
        XCTAssertThrowsError(try engine.sessions()) { error in
            XCTAssertEqual((error as? AgentFailure)?.code, .unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata)
        XCTAssertEqual(try state.loadMetadata()[session.id], session)
        let reopened = try TmuxEngine(state: state, configuration: configuration)
        XCTAssertThrowsError(try reopened.sessions())
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata)

        try FileManager.default.removeItem(at: failureMarker)
        XCTAssertEqual(try engine.sessions().map(\.id), [session.id])
        XCTAssertEqual(try reopened.sessions().map(\.id), [session.id])
        let result = try cleanup.run(["-S", state.tmuxSocketURL.path, "kill-server"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(try engine.sessions().isEmpty)
        XCTAssertTrue(try state.loadMetadata().isEmpty)
    }

    func testTmuxAbsenceProbeDistinguishesStaleAndLiveSockets() throws {
        let url = try directory()
        let state = try PrivateState(directory: url)
        XCTAssertTrue(try state.tmuxServerIsAbsent())
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = try Posix.address(state.tmuxSocketURL.path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(try state.tmuxServerIsAbsent(), "bound but non-listening socket must be refused")
        XCTAssertEqual(listen(fd, 4), 0)
        XCTAssertFalse(try state.tmuxServerIsAbsent(), "a live listener must not justify metadata deletion")
    }

    private actor Capture {
        var bytes = Data()
        func append(_ data: Data) { if bytes.count + data.count < 262144 { bytes.append(data) } }
        func text() -> String { String(decoding: bytes, as: UTF8.self) }
    }

    private func waitFor(_ text: String, capture: Capture) async throws {
        for _ in 0..<150 {
            if await capture.text().contains(text) { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Expected real PTY result was not received")
        throw AgentFailure()
    }

    func testSharingLimitsPairedDevicesAndSurvivesRestart() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let board = RelayStatusBoard()
        board.set("https://relay.example", .ready)
        var broker: AgentBroker? = try AgentBroker(configuration: configuration, relays: board)
        try broker?.start()
        defer {
            broker?.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let status = try await client.status()
        XCTAssertEqual(status.relays, [LocalRelayStatus(server: "https://relay.example", state: .ready)])
        let shared = try await client.create(name: "Shared", shared: true)
        let hidden = try await client.create(name: "Private")
        XCTAssertEqual(shared.sharing?.shared, true)
        XCTAssertEqual(hidden.sharing?.shared, false)

        // A paired device sees only shared sessions, without local details.
        let phone = LocalRemotePeer(deviceID: UUID().uuidString.lowercased(), name: "Phone")
        let remoteList = try await client.sessions(peer: phone)
        XCTAssertEqual(remoteList.map(\.id), [shared.id])
        XCTAssertNil(remoteList.first?.sharing)
        do {
            let leaked = try await client.attach(sessionID: hidden.id, mode: .view, peer: phone)
            await leaked.disconnect()
            XCTFail("A paired device attached to an unshared session")
        } catch LocalAgentClientError.rejected(.notFound) { }

        // The local list names who is attached and who controls.
        let remote = try await client.attach(sessionID: shared.id, mode: .view, peer: phone)
        let remoteEvents = remote.events
        let remoteCapture = TerminalGeometryCapture()
        let remoteReader = Task.detached {
            do { for try await event in remoteEvents { try await remoteCapture.append(event) } }
            catch { await remoteCapture.finish(error: error); return }
            await remoteCapture.finish()
        }
        defer { remoteReader.cancel() }
        let local = try await client.attach(sessionID: shared.id)
        let localEvents = local.events
        let localCapture = TerminalGeometryCapture()
        let localReader = Task.detached {
            do { for try await event in localEvents { try await localCapture.append(event) } }
            catch { await localCapture.finish(error: error); return }
            await localCapture.finish()
        }
        defer { localReader.cancel() }
        let listed = try await client.sessions().first { $0.id == shared.id }
        XCTAssertEqual(listed?.sharing?.attachments.count, 2)
        XCTAssertEqual(listed?.sharing?.controller, LocalAttachmentInfo(mode: .control, device: nil))
        XCTAssertTrue(listed?.sharing?.attachments.contains(LocalAttachmentInfo(mode: .view, device: phone)) == true)

        // Stopping sharing disconnects the paired device, not this Mac.
        let stopped = try await client.share(sessionID: shared.id, shared: false)
        XCTAssertEqual(stopped.sharing?.shared, false)
        for _ in 0..<100 where !(await remoteCapture.finished) { try await Task.sleep(for: .milliseconds(20)) }
        let remoteEnded = await remoteCapture.finished, localEnded = await localCapture.finished
        XCTAssertTrue(remoteEnded, "The paired device stayed attached after sharing stopped")
        XCTAssertFalse(localEnded, "Stopping sharing disconnected this Mac")
        let afterStop = try await client.sessions(peer: phone)
        XCTAssertTrue(afterStop.isEmpty)
        try await local.send(Data("echo still-here\n".utf8))
        try await local.detach()

        // Sharing is stored with the session and survives a service restart.
        _ = try await client.share(sessionID: hidden.id, shared: true)
        broker?.stop()
        broker = nil
        // The stopped broker releases its exclusive lock once its accept loop exits.
        for _ in 0..<100 where broker == nil {
            broker = try? AgentBroker(configuration: configuration)
            if broker == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        try XCTUnwrap(broker).start()
        let restarted = try await client.sessions()
        XCTAssertEqual(restarted.first { $0.id == hidden.id }?.sharing?.shared, true)
        XCTAssertEqual(restarted.first { $0.id == shared.id }?.sharing?.shared, false)
        let noRelays = try await client.status()
        XCTAssertEqual(noRelays.relays, [])
        try await client.close(sessionID: shared.id)
        try await client.close(sessionID: hidden.id)
    }

    func testCreateStartsInDirectoryAndNamesItsSession() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let workspace = url.appendingPathComponent("work space", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let file = url.appendingPathComponent("plain-file")
        try Data().write(to: file)
        for (path, expected) in [(url.appendingPathComponent("missing").path, LocalAgentErrorCode.notFound),
                                 (file.path, .invalidRequest)] {
            do { _ = try await client.create(name: "Bad", cwd: path); XCTFail("Accepted start directory \(path)") }
            catch LocalAgentClientError.rejected(let code) { XCTAssertEqual(code, expected) }
        }
        for path in ["relative/dir", url.path + "/../x"] {
            do { _ = try await client.create(name: "Bad", cwd: path); XCTFail("Accepted start directory \(path)") }
            catch LocalAgentClientError.rejected(.invalidRequest) { }
        }
        let session = try await client.create(name: "In directory", cwd: workspace.path)
        let attachment = try await client.attach(sessionID: session.id)
        let events = attachment.events
        let output = TerminalGeometryCapture()
        let reader = Task.detached {
            do { for try await event in events { try await output.append(event) } } catch { }
            await output.finish()
        }
        defer { reader.cancel() }
        try await attachment.send(Data("printf 'WHERE_''%s|%s\\n' \"$(pwd -P)\" \"$WITERM_SESSION_ID\"\n".utf8))
        // Foundation's symlink resolution drops /private; the shell's does not.
        let real = try XCTUnwrap(realpath(workspace.path, nil).map { defer { free($0) }; return String(cString: $0) })
        for _ in 0..<200 where !(await output.contains("|\(session.id)")) { try await Task.sleep(for: .milliseconds(25)) }
        let matched = await output.contains("WHERE_\(real)|\(session.id)")
        XCTAssertTrue(matched, "The shell did not start in the requested directory with its session ID")
        try await attachment.detach()
        try await client.close(sessionID: session.id)
    }

    func testDetachAcknowledgementAllowsImmediateControllerHandoff() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await client.create(name: "Handoff")
        let viewer = try await client.attach(sessionID: session.id, mode: .view)
        for _ in 0..<4 {
            let first = try await client.attach(sessionID: session.id)
            try await first.detach()
            // No output-drain wait, retry or sleep is needed after the ACK.
            let next = try await client.attach(sessionID: session.id)
            do { try await viewer.send(Data("forbidden".utf8)); XCTFail("Viewer gained input during handoff") }
            catch LocalAgentClientError.rejected(.readOnly) { }
            try await next.detach()
        }
        try await viewer.detach()
        try await client.close(sessionID: session.id)
    }

    func testRealPTYInputResizeReadOnlyAndRepaint() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment).run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let created = try await client.create(name: "Quoted ; session", columns: 80, rows: 24)
        let control = try await client.attach(sessionID: created.id)
        let capture = Capture()
        let reader = Task { for try await data in control.output { await capture.append(data) } }
        defer { reader.cancel() }
        try await control.send(Data("printf 'AGENT_''READY\\n'\n".utf8))
        try await waitFor("AGENT_READY", capture: capture)
        do {
            let second = try await client.attach(sessionID: created.id)
            await second.disconnect()
            XCTFail("second controller was accepted")
        } catch LocalAgentClientError.rejected(.sessionBusy) { }
        let observer = try await client.attach(sessionID: created.id, columns: 91, rows: 31, mode: .view)
        let observerCapture = Capture()
        let observerReader = Task { for try await data in observer.output { await observerCapture.append(data) } }
        defer { observerReader.cancel() }
        try await waitFor("AGENT_READY", capture: observerCapture)
        do { try await observer.send(Data("ignored".utf8)); XCTFail("read-only input accepted") }
        catch LocalAgentClientError.rejected(.readOnly) { }
        // Bypass the public client's own view-mode checks and exercise the
        // broker's authorization with direct, valid wire frames.
        let rawObserver = try connect(url.appendingPathComponent("agent.sock"))
        defer { Darwin.close(rawObserver) }
        var attach = try wireEncoder().encode(LocalAgentRequest(operation: .attach, sessionID: created.id, columns: 91, rows: 31, mode: .view))
        attach.append(10)
        XCTAssertTrue(Posix.writeAll(rawObserver, data: attach))
        let attached = try readFrame(rawObserver)
        XCTAssertEqual(attached.ok, true)
        for request in [LocalAgentRequest(operation: .input, data: Data("ignored".utf8)), LocalAgentRequest(operation: .resize, columns: 91, rows: 31)] {
            var bytes = try wireEncoder().encode(request)
            bytes.append(10)
            XCTAssertTrue(Posix.writeAll(rawObserver, data: bytes))
            var response = try readFrame(rawObserver)
            while response.id != request.id { response = try readFrame(rawObserver) }
            XCTAssertEqual(response.error, .readOnly)
        }
        do { try await observer.resize(columns: 91, rows: 31); XCTFail("read-only resize accepted") }
        catch LocalAgentClientError.rejected(.readOnly) { }
        try await control.resize(columns: 111, rows: 39)
        try await control.send(Data("printf 'ACTUAL_''SIZE:%s\\n' \"$(stty size)\"\n".utf8))
        try await waitFor("ACTUAL_SIZE:39 111", capture: capture)
        await observer.disconnect()
        await control.disconnect()
        let reattached = try await client.attach(sessionID: created.id, columns: 111, rows: 39)
        let repaint = Capture()
        let repaintReader = Task { for try await data in reattached.output { await repaint.append(data) } }
        defer { repaintReader.cancel() }
        try await waitFor("ACTUAL_SIZE:39 111", capture: repaint)
        await reattached.disconnect()
        try await client.close(sessionID: created.id)
        let sessions = try await client.sessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testRawViewInitialPTYUsesAuthoritativeWindowSize() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment).run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let created = try await client.create(name: "Wide window", columns: 80, rows: 24)
        let control = try await client.attach(sessionID: created.id)
        let capture = Capture()
        let reader = Task { for try await data in control.output { await capture.append(data) } }
        defer { reader.cancel() }
        try await control.resize(columns: 103, rows: 37)
        // Split shell literals prevent command echo from satisfying the result.
        // The marker starts beyond column 90, outside the observer's requested
        // 20-column grid; only a correctly sized PTY can repaint this row.
        try await control.send(Data("printf '%090dVIEW_''EDGE\\n' 0\n".utf8))
        try await waitFor("VIEW_EDGE", capture: capture)

        let observer = try connect(url.appendingPathComponent("agent.sock"))
        defer { Darwin.close(observer) }
        var request = try wireEncoder().encode(LocalAgentRequest(operation: .attach, sessionID: created.id, columns: 20, rows: 5, mode: .view))
        request.append(10)
        XCTAssertTrue(Posix.writeAll(observer, data: request))
        let response = try readFrame(observer)
        XCTAssertEqual(response.kind, .response)
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.mode, .view)
        XCTAssertEqual(response.session?.columns, 103)
        XCTAssertEqual(response.session?.rows, 37)
        var repaint = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !String(decoding: repaint, as: UTF8.self).contains("VIEW_EDGE") {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Observer repaint was cropped to its stale requested size")
                throw AgentFailure()
            }
            let frame = try readFrame(observer)
            if frame.kind == .output, let data = frame.data { repaint.append(data) }
        }
        try await control.send(Data("printf 'OBSERVER_''SIZE:%s\\n' \"$(stty size)\"\n".utf8))
        try await waitFor("OBSERVER_SIZE:37 103", capture: capture)
        await control.disconnect()
        try await client.close(sessionID: created.id)
    }

    func testGeometryBroadcastOrdersRapidUTF8AlternateScreenRepaint() async throws {
        var currentStage = "setup"
        var tracked: [TerminalGeometryCapture] = []
        func phase(_ name: String) {
            currentStage = name
        }
        defer { print("Geometry local last stage: \(currentStage)") }
        phase("setup")
        do {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let local = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await local.create(name: "Geometry observers", columns: 80, rows: 24)
        // Renderers start before each attach and every stream is selected as
        // soon as it exists: an unselected attachment retains only 64 events.
        let firstScreen = try TerminalGeometryScreen(directory: url, configuration: configuration, columns: 80, rows: 24)
        let secondScreen = try TerminalGeometryScreen(directory: url, configuration: configuration, columns: 80, rows: 24)
        let controlScreen = try TerminalGeometryScreen(directory: url, configuration: configuration, columns: 100, rows: 30)
        defer { firstScreen.close(); secondScreen.close(); controlScreen.close() }
        phase("view attach")
        let first = try await local.attach(sessionID: session.id, mode: .view)
        let firstEvents = first.events
        let second = try await local.attach(sessionID: session.id, mode: .view)
        let secondEvents = second.events
        let firstCapture = TerminalGeometryCapture(screen: firstScreen), secondCapture = TerminalGeometryCapture(screen: secondScreen)
        tracked = [firstCapture, secondCapture]
        let firstReader = Task.detached {
            do { for try await event in firstEvents { try await firstCapture.append(event) } }
            catch { await firstCapture.finish(error: error); return }
            await firstCapture.finish()
        }
        let secondReader = Task.detached {
            do { for try await event in secondEvents { try await secondCapture.append(event) } }
            catch { await secondCapture.finish(error: error); return }
            await secondCapture.finish()
        }
        defer { firstReader.cancel(); secondReader.cancel() }
        // The controller's initial attach changes the window while the existing
        // viewers remain connected. Their PTYs and event grids must follow it.
        let controller = try await local.attach(sessionID: session.id, columns: 100, rows: 30)
        let controlEvents = controller.events
        phase("controller attached")
        let controlCapture = TerminalGeometryCapture(screen: controlScreen)
        tracked.append(controlCapture)
        let controlReader = Task.detached {
            do { for try await event in controlEvents { try await controlCapture.append(event) } }
            catch { await controlCapture.finish(error: error); return }
            await controlCapture.finish()
        }
        defer { controlReader.cancel() }
        try await controller.send(geometryScreenInput())
        phase("foreground alternate screen")
        for _ in 0..<200 {
            if try await firstCapture.rendered("GRID_30_100_宽🙂", columns: 100, rows: 30),
               try await secondCapture.rendered("GRID_30_100_宽🙂", columns: 100, rows: 30) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let initialFirst = try await firstCapture.rendered("GRID_30_100_宽🙂", columns: 100, rows: 30)
        let initialSecond = try await secondCapture.rendered("GRID_30_100_宽🙂", columns: 100, rows: 30)
        let firstDiagnostics = await firstCapture.diagnostics(), secondDiagnostics = await secondCapture.diagnostics()
        let rawFirst = await firstCapture.contains("GRID_30_100_宽🙂")
        let screenFlags = try firstScreen.diagnosticFlags()
        let geometryRunner = CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
        let clientGridData = try geometryRunner.run(["-S", url.appendingPathComponent("tmux.sock").path,
            "list-clients", "-t", "witerm-" + session.id, "-F", "#{client_width}x#{client_height}"])
        let clientGrids = String(decoding: clientGridData.output, as: UTF8.self).split(separator: "\n")
        XCTAssertTrue(clientGrids.allSatisfy { $0 == "100x30" }, "tmux clients retained stale grids: \(clientGrids)")
        XCTAssertTrue(initialFirst && initialSecond, "Existing viewers did not repaint: \(firstDiagnostics); \(secondDiagnostics); raw=\(rawFirst); \(screenFlags)")
        guard initialFirst && initialSecond else { throw AgentFailure() }
        let sizes = [(103, 37), (91, 29), (120, 40), (104, 32)]
        // No sleeps between size requests: old UTF-8/VT fragments must remain
        // ordered, and every new-size repaint must follow its geometry event.
        for (columns, rows) in sizes { phase("resize \(columns)x\(rows)"); try await controller.resize(columns: columns, rows: rows) }
        phase("final renderer check")
        for _ in 0..<200 {
            if try await firstCapture.rendered("GRID_32_104_宽🙂", columns: 104, rows: 32),
               try await secondCapture.rendered("GRID_32_104_宽🙂", columns: 104, rows: 32),
               try await controlCapture.rendered("GRID_32_104_宽🙂", columns: 104, rows: 32) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        for captured in [firstCapture, secondCapture, controlCapture] {
            let changes = await captured.geometries()
            XCTAssertEqual(changes.map { "\($0.columns)x\($0.rows)" }, ["100x30", "103x37", "91x29", "120x40", "104x32"])
            XCTAssertTrue(changes.allSatisfy { $0.id == session.id && $0.name == session.name && $0.createdAt == session.createdAt })
            let ordered = try await captured.rendered("GRID_32_104_宽🙂", columns: 104, rows: 32)
            XCTAssertTrue(ordered, "New-size UTF-8 redraw preceded the geometry event or was cropped")
            let edge = try await captured.rendered("EDGE_32_104", columns: 104, rows: 32)
            XCTAssertTrue(edge, "The wider viewport was cropped to an old PTY width")
        }
        do { try await first.resize(columns: 80, rows: 24); XCTFail("A viewer resized the shared window") }
        catch LocalAgentClientError.rejected(.readOnly) { }
        do {
            let conflict = try await local.attach(sessionID: session.id, columns: 80, rows: 24)
            await conflict.disconnect(); XCTFail("A second controller forced takeover")
        } catch LocalAgentClientError.rejected(.sessionBusy) { }
        let runner = CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
        let alternate = try runner.run(["-S", url.appendingPathComponent("tmux.sock").path,
            "display-message", "-p", "-t", "witerm-" + session.id, "#{alternate_on}"])
        XCTAssertEqual(String(decoding: alternate.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let unchanged = try await local.sessions().first(where: { $0.id == session.id })
        XCTAssertEqual(unchanged?.columns, 104)
        XCTAssertEqual(unchanged?.rows, 32)
        try await controller.detach()
        phase("replacement controller")
        let next = try await local.attach(sessionID: session.id, columns: 117, rows: 33)
        for _ in 0..<200 {
            if try await firstCapture.rendered("GRID_33_117_宽🙂", columns: 117, rows: 33),
               try await secondCapture.rendered("GRID_33_117_宽🙂", columns: 117, rows: 33) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let firstReattached = try await firstCapture.rendered("GRID_33_117_宽🙂", columns: 117, rows: 33)
        let secondReattached = try await secondCapture.rendered("GRID_33_117_宽🙂", columns: 117, rows: 33)
        let finalGeometries = await firstCapture.geometries()
        XCTAssertEqual(finalGeometries.last?.columns, 117)
        XCTAssertEqual(finalGeometries.last?.rows, 33)
        let viewerFinished = await firstCapture.finished
        XCTAssertFalse(viewerFinished, "Viewer closed during replacement controller resize")
        XCTAssertTrue(firstReattached && secondReattached, "Existing viewers missed replacement controller geometry")
        try await next.detach(); try await first.detach(); try await second.detach()
        try await local.close(sessionID: session.id)
        phase("complete")
        } catch {
            for capture in tracked {
                let diagnostic = await capture.diagnostics()
                FileHandle.standardError.write(Data(("Geometry failure metadata: " + diagnostic + "\n").utf8))
            }
            throw error
        }
    }

    func testResizeAcknowledgementFollowsShellPTYAfterRapidResizes() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let local = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await local.create(name: "Resize ACK", columns: 111, rows: 39)
        let viewer = try await local.attach(sessionID: session.id, mode: .view)
        let controller = try await local.attach(sessionID: session.id, columns: 111, rows: 39)
        let events = controller.events
        let output = TerminalGeometryCapture()
        let reader = Task.detached {
            do { for try await event in events { try await output.append(event) } }
            catch { await output.finish(error: error); return }
            await output.finish()
        }
        defer { reader.cancel() }
        try await controller.send(geometryScreenInput())
        for (columns, rows) in [(103, 37), (91, 29), (120, 40), (104, 32)] {
            try await controller.resize(columns: columns, rows: rows)
        }
        for _ in 0..<200 where !(await output.contains("GRID_32_104")) { try await Task.sleep(for: .milliseconds(25)) }
        let rapidRendered = await output.contains("GRID_32_104")
        XCTAssertTrue(rapidRendered, "The foreground process missed the final rapid resize")
        try await controller.send(Data([3]))
        try await controller.send(Data("printf '\\033[?1049l'; printf 'ACK_''EXIT\\n'\n".utf8))
        for _ in 0..<200 where !(await output.contains("ACK_EXIT")) { try await Task.sleep(for: .milliseconds(25)) }
        // The resize ACK is the controller's proof that the shell sees the new
        // grid. No sleep or retry may hide a pane PTY that tmux applies later.
        try await controller.resize(columns: 111, rows: 39)
        try await controller.send(Data("printf 'ACK_''SIZE:%s\\n' \"$(stty size)\"\n".utf8))
        for _ in 0..<200 where !(await output.contains("ACK_SIZE:")) { try await Task.sleep(for: .milliseconds(25)) }
        let applied = await output.contains("ACK_SIZE:39 111")
        let stale = await output.contains("ACK_SIZE:32 104")
        XCTAssertTrue(applied && !stale, "The resize was acknowledged before the shell PTY changed")
        try await controller.detach(); try await viewer.detach()
        try await local.close(sessionID: session.id)
    }

    func testGeometryRenderSinkUsesFIFOAndRawOutput() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let screen = try TerminalGeometryScreen(directory: url, configuration: configuration, columns: 80, rows: 24)
        defer {
            screen.close()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        try screen.accept(.output(Data("\u{1b}[?1049h\u{1b}[2J\u{1b}[HRENDER_宽🙂".utf8)))
        for _ in 0..<100 {
            if try screen.contains("RENDER_宽🙂") { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Independent tmux renderer did not consume FIFO bytes")
    }

    func testUnappliedPaneResizeClosesPeersAndRecordsShellGrid() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let proxy = url.appendingPathComponent("noop-resize-proxy")
        let marker = URL(fileURLWithPath: proxy.path + ".noop")
        // tmux reports success but the window and pane keep their old size.
        let script = """
        #!/bin/sh
        if [ "$5" = "resize-window" ] && [ -f "${0}.noop" ]; then exit 0; fi
        exec /opt/homebrew/bin/tmux "$@"
        """
        try Data(script.utf8).write(to: proxy)
        XCTAssertEqual(chmod(proxy.path, 0o700), 0)
        let configuration = try AgentConfiguration(stateDirectory: url, tmuxPath: proxy.path, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let local = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await local.create(name: "Unapplied geometry", columns: 80, rows: 24)
        let controller = try await local.attach(sessionID: session.id, columns: 80, rows: 24)
        let controlEvents = controller.events
        let viewer = try await local.attach(sessionID: session.id, mode: .view)
        let viewEvents = viewer.events
        let controlCapture = TerminalGeometryCapture(), viewCapture = TerminalGeometryCapture()
        let readers = [Task.detached {
            do { for try await event in controlEvents { try await controlCapture.append(event) } } catch { }
            await controlCapture.finish()
        }, Task.detached {
            do { for try await event in viewEvents { try await viewCapture.append(event) } } catch { }
            await viewCapture.finish()
        }]
        defer { readers.forEach { $0.cancel() } }
        try Data().write(to: marker)
        do { try await controller.resize(columns: 103, rows: 37); XCTFail("An unapplied pane resize was acknowledged") }
        catch { }
        for _ in 0..<100 {
            if await controlCapture.finished, await viewCapture.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let endedController = await controlCapture.finished, endedView = await viewCapture.finished
        XCTAssertTrue(endedController && endedView, "Peers kept a grid the shell never received")
        do { try await controller.send(Data("true\n".utf8)); XCTFail("The stale controller accepted input") }
        catch { }
        let recorded = try await local.sessions().first(where: { $0.id == session.id })
        XCTAssertEqual(recorded.map { "\($0.columns)x\($0.rows)" }, "80x24", "Metadata kept the announced grid")
        // From the recorded truth, a new controller resizes for real.
        try FileManager.default.removeItem(at: marker)
        let next = try await local.attach(sessionID: session.id, columns: 103, rows: 37)
        let nextEvents = next.events
        let output = TerminalGeometryCapture()
        let reader = Task.detached {
            do { for try await event in nextEvents { try await output.append(event) } } catch { }
            await output.finish()
        }
        defer { reader.cancel() }
        try await next.send(Data("printf 'GRID_''NOW:%s\\n' \"$(stty size)\"\n".utf8))
        for _ in 0..<200 where !(await output.contains("GRID_NOW:")) { try await Task.sleep(for: .milliseconds(25)) }
        let applied = await output.contains("GRID_NOW:37 103")
        XCTAssertTrue(applied, "Reattaching did not resize the shell from the recorded grid")
        try await next.detach()
        try await local.close(sessionID: session.id)
    }

    func testAttachRevalidatesGridAfterFailedReconciliation() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let proxy = url.appendingPathComponent("stale-grid-proxy")
        let markers = ["noop", "blind", "seen"].map { URL(fileURLWithPath: proxy.path + "." + $0) }
        // resize-window succeeds without effect; after the confirmation's pane
        // lookup, the reconciliation's lookup fails, leaving the stale record.
        let script = """
        #!/bin/sh
        if [ "$5" = "resize-window" ] && [ -f "${0}.noop" ]; then exit 0; fi
        if [ "$5" = "display-message" ] && [ -f "${0}.blind" ]; then
            if [ -f "${0}.seen" ]; then exit 1; fi
            : > "${0}.seen"
        fi
        exec /opt/homebrew/bin/tmux "$@"
        """
        try Data(script.utf8).write(to: proxy)
        XCTAssertEqual(chmod(proxy.path, 0o700), 0)
        let configuration = try AgentConfiguration(stateDirectory: url, tmuxPath: proxy.path, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let local = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await local.create(name: "Stale geometry", columns: 80, rows: 24)
        let controller = try await local.attach(sessionID: session.id, columns: 80, rows: 24)
        let controlEvents = controller.events
        let drain = Task.detached { do { for try await _ in controlEvents {} } catch {} }
        defer { drain.cancel() }
        try Data().write(to: markers[0]); try Data().write(to: markers[1])
        do { try await controller.resize(columns: 103, rows: 37); XCTFail("An unapplied pane resize was acknowledged") }
        catch { }
        let stale = try await local.sessions().first(where: { $0.id == session.id })
        XCTAssertEqual(stale.map { "\($0.columns)x\($0.rows)" }, "103x37", "The fault did not leave a stale record")
        for marker in markers { try? FileManager.default.removeItem(at: marker) }
        // Attachments start from the shell's grid, not the stale record.
        let viewer = try await local.attach(sessionID: session.id, columns: 103, rows: 37, mode: .view)
        XCTAssertEqual("\(viewer.session.columns)x\(viewer.session.rows)", "80x24")
        var next: LocalTerminalAttachment?
        for _ in 0..<100 {
            do { next = try await local.attach(sessionID: session.id, columns: 103, rows: 37); break }
            catch LocalAgentClientError.rejected(.sessionBusy) { try await Task.sleep(for: .milliseconds(20)) }
        }
        let resumed = try XCTUnwrap(next, "The closed controller never released control")
        XCTAssertEqual("\(resumed.session.columns)x\(resumed.session.rows)", "103x37")
        let events = resumed.events
        let output = TerminalGeometryCapture()
        let reader = Task.detached {
            do { for try await event in events { try await output.append(event) } } catch { }
            await output.finish()
        }
        defer { reader.cancel() }
        try await resumed.send(Data("printf 'GRID_''NOW:%s\\n' \"$(stty size)\"\n".utf8))
        for _ in 0..<200 where !(await output.contains("GRID_NOW:")) { try await Task.sleep(for: .milliseconds(25)) }
        let applied = await output.contains("GRID_NOW:37 103")
        XCTAssertTrue(applied, "A matching stale record let attach skip the real resize")
        try await resumed.detach(); try await viewer.detach()
        try await local.close(sessionID: session.id)
    }

    func testFailedResizeClosesPeersRatherThanContinuingAfterGeometry() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let proxy = url.appendingPathComponent("resize-test-proxy")
        let marker = URL(fileURLWithPath: proxy.path + ".fail")
        let script = """
        #!/bin/sh
        if [ "$5" = "resize-window" ] && [ -f "${0}.fail" ]; then exit 1; fi
        exec /opt/homebrew/bin/tmux "$@"
        """
        try Data(script.utf8).write(to: proxy)
        XCTAssertEqual(chmod(proxy.path, 0o700), 0)
        let configuration = try AgentConfiguration(stateDirectory: url, tmuxPath: proxy.path, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        defer {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
        }
        let local = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await local.create(name: "Failed geometry")
        let controller = try await local.attach(sessionID: session.id)
        let viewer = try await local.attach(sessionID: session.id, mode: .view)
        let controlCapture = TerminalGeometryCapture(), viewCapture = TerminalGeometryCapture()
        let controlReader = Task {
            do { for try await event in controller.events { try await controlCapture.append(event) } }
            catch { }
            await controlCapture.finish()
        }
        let viewReader = Task {
            do { for try await event in viewer.events { try await viewCapture.append(event) } }
            catch { }
            await viewCapture.finish()
        }
        defer { controlReader.cancel(); viewReader.cancel() }
        try Data().write(to: marker)
        do { try await controller.resize(columns: 103, rows: 37); XCTFail("Failed tmux resize was acknowledged") }
        catch { }
        for _ in 0..<100 {
            if await controlCapture.finished, await viewCapture.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let endedController = await controlCapture.finished, endedView = await viewCapture.finished
        XCTAssertTrue(endedController && endedView, "Peers continued consuming bytes after a failed geometry transaction")
        let retained = try await local.sessions().first(where: { $0.id == session.id })
        XCTAssertEqual(retained?.columns, 80)
        XCTAssertEqual(retained?.rows, 24)
        try FileManager.default.removeItem(at: marker)
        let recovered = try await local.attach(sessionID: session.id, columns: 103, rows: 37)
        XCTAssertEqual(recovered.session.columns, 103)
        try await recovered.detach()
        try await local.close(sessionID: session.id)
    }
}
