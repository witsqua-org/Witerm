import CoreFoundation
import Darwin
import Foundation
import WitermCore

final class AgentBroker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.witerm.agent.state")
    private let state: PrivateState
    private let engine: TmuxEngine
    private var listener: Int32 = -1
    private var active = false
    private var connections: [UUID: AgentConnection] = [:]
    private var controllers: [String: UUID] = [:]
    private var socketIdentity: (dev_t, ino_t)?

    init(configuration: AgentConfiguration) throws {
        state = try PrivateState(directory: configuration.stateDirectory)
        engine = try TmuxEngine(state: state, configuration: configuration)
    }

    func start() throws {
        let boundDescriptor = try queue.sync { () -> Int32 in
            guard !active else { throw AgentFailure() }
            try state.removeStaleSocket()
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw AgentFailure() }
            do {
                try Posix.closeOnExec(fd); try Posix.nonblocking(fd)
                var address = try Posix.address(state.socketURL.path)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard result == 0, chmod(state.socketURL.path, 0o600) == 0, listen(fd, 32) == 0 else { throw AgentFailure() }
                var value = stat()
                guard lstat(state.socketURL.path, &value) == 0 else { throw AgentFailure() }
                socketIdentity = (value.st_dev, value.st_ino)
                listener = fd; active = true
                return fd
            } catch { Darwin.close(fd); throw error }
        }
        Thread.detachNewThread { [self] in acceptLoop(descriptor: boundDescriptor) }
    }

    func stop() {
        queue.sync {
            guard active else { return }
            active = false
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            listener = -1
            for connection in connections.values { connection.child?.stop(); connection.finish(afterFlush: false) }
            connections.removeAll(); controllers.removeAll()
            var value = stat()
            if let identity = socketIdentity, lstat(state.socketURL.path, &value) == 0,
               value.st_dev == identity.0, value.st_ino == identity.1, value.st_uid == geteuid() {
                _ = unlink(state.socketURL.path)
            }
        }
    }

    private func acceptLoop(descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        while true {
            let fd = queue.sync { active ? descriptor : -1 }
            if fd < 0 { return }
            var polled = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&polled, 1, 250)
            if result < 0 && errno == EINTR { continue }
            if result < 0 { return }
            if result == 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            guard Posix.sameUser(client) else { Darwin.close(client); continue }
            queue.sync {
                guard active, connections.count < 32 else { Darwin.close(client); return }
                do {
                    let connection = try AgentConnection(descriptor: client, received: { [weak self] bytes, connection in
                        self?.receive(bytes, on: connection)
                    }, disconnected: { [weak self] connection, final in self?.disconnect(connection, final: final) })
                    connections[connection.token] = connection
                    connection.start()
                } catch { Darwin.close(client) }
            }
        }
    }

    private func disconnect(_ connection: AgentConnection, final: Bool) {
        queue.async { [self] in
            if let sessionID = connection.sessionID, controllers[sessionID] == connection.token { controllers.removeValue(forKey: sessionID) }
            connection.child?.stop()
            connection.child = nil
            connection.mode = nil
            connection.sessionID = nil
            if final { connections.removeValue(forKey: connection.token) }
        }
    }

    private func receive(_ data: Data, on connection: AgentConnection) {
        queue.sync {
            guard active, connections[connection.token] != nil else { return }
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let possibleID = raw?["id"] as? String
            let id = possibleID.flatMap { validSessionID($0) ? $0 : nil }
            if let version = raw?["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue != 1 {
                connection.enqueue(LocalAgentFrame(id: id, kind: .response, ok: false, error: .unsupportedVersion))
                connection.finish(afterFlush: true); return
            }
            guard let raw, let version = raw["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1, id != nil,
                  let request = try? wireDecoder().decode(LocalAgentRequest.self, from: data), validFields(raw, operation: request.operation) else {
                connection.enqueue(LocalAgentFrame(id: id, kind: .response, ok: false, error: .invalidRequest))
                connection.finish(afterFlush: true); return
            }
            do { try handle(request, on: connection) }
            catch {
                let code = (error as? AgentFailure)?.code ?? .unavailable
                connection.enqueue(LocalAgentFrame(id: request.id, kind: .response, ok: false, error: code))
                if code == .backpressure { connection.finish(afterFlush: true, terminalError: code, emitClosed: true) }
            }
        }
    }

    private func validFields(_ raw: [String: Any], operation: LocalAgentOperation) -> Bool {
        var allowed: Set<String> = ["version", "id", "operation"]
        switch operation {
        case .status, .list, .detach: break
        case .create: allowed.formUnion(["name", "columns", "rows"])
        case .close: allowed.insert("session_id")
        case .attach: allowed.formUnion(["session_id", "columns", "rows", "mode"])
        case .input: allowed.insert("data")
        case .resize: allowed.formUnion(["columns", "rows"])
        }
        return Set(raw.keys).isSubset(of: allowed)
    }

    private func handle(_ request: LocalAgentRequest, on connection: AgentConnection) throws {
        func reply(session: LocalSessionInfo? = nil, sessions: [LocalSessionInfo]? = nil, status: LocalAgentStatus? = nil, mode: LocalAttachmentMode? = nil) {
            connection.enqueue(LocalAgentFrame(id: request.id, kind: .response, ok: true, status: status, sessions: sessions, session: session, mode: mode))
        }
        func dimensions() throws -> (Int, Int) {
            guard let columns = request.columns, let rows = request.rows, validDimensions(columns: columns, rows: rows) else { throw AgentFailure(.invalidRequest) }
            return (columns, rows)
        }
        func sessionID() throws -> String {
            guard let id = request.sessionID, validSessionID(id) else { throw AgentFailure(.invalidRequest) }; return id
        }
        switch request.operation {
        case .status: reply(status: LocalAgentStatus(tmuxAvailable: engine.available))
        case .list: reply(sessions: try engine.sessions())
        case .create:
            guard connection.child == nil, let name = request.name, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...64).contains(name.unicodeScalars.count), name.rangeOfCharacter(from: .controlCharacters) == nil else { throw AgentFailure(.invalidRequest) }
            let (columns, rows) = try dimensions()
            reply(session: try engine.create(name: name, columns: columns, rows: rows))
        case .close:
            let id = try sessionID()
            try engine.close(id)
            reply()
            for attached in connections.values where attached.sessionID == id {
                attached.finish(afterFlush: true, emitClosed: true)
            }
        case .attach:
            guard connection.child == nil, let mode = request.mode else { throw AgentFailure(.invalidRequest) }
            let id = try sessionID()
            let (columns, rows) = try dimensions()
            if mode == .control, controllers[id] != nil { throw AgentFailure(.sessionBusy) }
            let previous = try engine.verifiedSession(id)
            let changed = mode == .control && (previous.columns != columns || previous.rows != rows)
            let info = changed ? try resizeSession(previous, columns: columns, rows: rows) : previous
            // A viewer observes the controller's current window, not its stale
            // list/request grid. Its PTY must render that same authoritative size.
            let child = try engine.attach(id, columns: info.columns, rows: info.rows, mode: mode)
            connection.child = child; connection.sessionID = id; connection.mode = mode
            if mode == .control { controllers[id] = connection.token }
            // FIFO delivery guarantees the response precedes the first VT event.
            reply(session: info, mode: mode)
            if changed { connection.enqueue(LocalAgentFrame(kind: .geometry, session: info)) }
            child.start(output: { [weak connection] bytes in connection?.enqueue(LocalAgentFrame(kind: .output, data: bytes)) ?? false }, ended: { [weak connection] in connection?.finish(afterFlush: true, emitClosed: true) })
        case .input:
            guard let child = connection.child, connection.sessionID != nil, let data = request.data, data.count <= 16384 else { throw AgentFailure(.invalidRequest) }
            guard connection.mode == .control else { throw AgentFailure(.readOnly) }
            try child.send(data); reply()
        case .resize:
            guard connection.child != nil, let id = connection.sessionID else { throw AgentFailure(.invalidRequest) }
            guard connection.mode == .control else { throw AgentFailure(.readOnly) }
            let (columns, rows) = try dimensions()
            let previous = try engine.session(id)
            if previous.columns != columns || previous.rows != rows {
                _ = try resizeSession(previous, columns: columns, rows: rows)
            } else {
                // A retried resize still promises that the shell sees this grid.
                try confirmPaneSize(id, columns: columns, rows: rows)
            }
            reply()
        case .detach:
            guard let child = connection.child else { throw AgentFailure(.invalidRequest) }
            // The ACK means another endpoint may acquire control immediately.
            if let id = connection.sessionID, controllers[id] == connection.token {
                controllers.removeValue(forKey: id)
            }
            connection.child = nil
            connection.mode = nil
            connection.sessionID = nil
            reply()
            connection.finish(afterFlush: true)
            child.stop()
        }
    }

    private func resizeSession(_ previous: LocalSessionInfo, columns: Int, rows: Int) throws -> LocalSessionInfo {
        let info = try announceResize(previous, columns: columns, rows: rows)
        // tmux may defer the pane's own PTY resize behind an earlier one. Wait
        // with output flowing: every peer already has the geometry ahead of
        // any new-size repaint, and holding barriers here backs up redraws.
        try confirmPaneSize(previous.id, columns: columns, rows: rows)
        return info
    }

    private func confirmPaneSize(_ id: String, columns: Int, rows: Int) throws {
        do { try engine.waitForPaneSize(id, columns: columns, rows: rows) }
        catch {
            // Peers were told a grid the shell never received. Input typed now
            // would target the wrong one, so close every attachment and record
            // the grid the shell has; reattaching resizes from that truth.
            for connection in connections.values where connection.sessionID == id && connection.child != nil {
                connection.finish(afterFlush: false, terminalError: .unavailable, emitClosed: true)
                connection.child?.stop()
            }
            try? engine.reconcileToPane(id)
            throw error
        }
    }

    private func announceResize(_ previous: LocalSessionInfo, columns: Int, rows: Int) throws -> LocalSessionInfo {
        // The broker owns attachment membership. PTY output never queue.syncs
        // back here, so taking all output barriers cannot deadlock a reader.
        let peers = connections.values.filter { $0.sessionID == previous.id && $0.child != nil }
            .sorted { $0.token.uuidString < $1.token.uuidString }
            .compactMap { connection in connection.child.map { (connection, $0) } }
        for (_, child) in peers { child.pauseOutput() }
        defer { for (_, child) in peers.reversed() { child.resumeOutput() } }
        let info = LocalSessionInfo(id: previous.id, name: previous.name, createdAt: previous.createdAt,
                                    columns: columns, rows: rows)
        var terminals: Set<String> = []
        do {
            for (connection, child) in peers {
                // The existing encoded delivery budget reserves space for this
                // geometry before any new-size output is allowed. Overflow
                // closes that endpoint rather than dropping/reordering VT.
                guard connection.enqueue(LocalAgentFrame(kind: .geometry, session: info)) else {
                    child.stop(); continue
                }
                do {
                    try child.resize(columns: columns, rows: rows)
                    terminals.insert(child.terminalName)
                } catch {
                    connection.finish(afterFlush: false, terminalError: .unavailable, emitClosed: true)
                    child.stop()
                }
            }
            let authoritative = try engine.resize(previous.id, columns: columns, rows: rows)
            try engine.refresh(previous.id, terminals: terminals, columns: columns, rows: rows)
            return authoritative
        } catch {
            // A failed tmux transaction must not leave a peer consuming future
            // output after an unfulfilled geometry announcement.
            for (connection, child) in peers {
                connection.finish(afterFlush: false, terminalError: .unavailable, emitClosed: true)
                child.stop()
            }
            throw error
        }
    }
}
