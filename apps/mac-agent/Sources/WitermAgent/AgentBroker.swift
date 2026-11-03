import CoreFoundation
import Darwin
import Foundation
import WitermCore

final class AgentBroker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.witerm.agent.state")
    private let state: PrivateState
    private let engine: TmuxEngine
    private let relays: RelayStatusBoard?
    private var listener: Int32 = -1
    private var active = false
    private var connections: [UUID: AgentConnection] = [:]
    /// Attachments that may type, per session. Several can: typing is shared
    /// when every one of them allows it.
    private var writers: [String: Set<UUID>] = [:]
    /// The writer whose grid the session uses: the last one that typed, or
    /// the first to attach. Others see that grid until they type.
    private var sizeOwners: [String: UUID] = [:]
    /// Each writer's own grid, applied when it becomes the size owner.
    private var preferred: [UUID: (columns: Int, rows: Int)] = [:]
    /// When each writer last typed, so the grid changes hands only once its
    /// owner pauses rather than on every interleaved keystroke.
    private var lastInput: [UUID: TimeInterval] = [:]
    /// How long the grid's owner must be idle before another typist takes it.
    static let ownerHold: TimeInterval = 2
    /// Sessions whose paired devices are view only for now. Kept in memory:
    /// restarting the service ends the pause.
    private var remoteTypingPaused: Set<String> = []
    /// This Mac's policy per paired device.
    private var accessPolicies: [String: LocalDeviceAccess]
    /// Invitations to single sessions, keyed by pairing. A grant from one of
    /// these pairings reaches only its session, once redeemed and until it expires.
    private var guests: [String: LocalGuestInvite]
    private var expiryTimer: DispatchSourceTimer?
    private var socketIdentity: (dev_t, ino_t)?

    init(configuration: AgentConfiguration, relays: RelayStatusBoard? = nil) throws {
        state = try PrivateState(directory: configuration.stateDirectory)
        engine = try TmuxEngine(state: state, configuration: configuration)
        // An unreadable policy file falls back to shared sessions only.
        accessPolicies = (try? state.loadDeviceAccess()) ?? [:]
        // An unreadable invitation file loses the invitations, never widens them:
        // their grants then reach only what an unknown device would.
        guests = (try? state.loadGuests()) ?? [:]
        self.relays = relays
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
                // Invitations end at their time even while nobody sends a request.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 2, repeating: 2)
                timer.setEventHandler { [weak self] in
                    guard let self, self.active, !self.guests.isEmpty else { return }
                    self.enforceRemoteAccess()
                }
                timer.resume()
                expiryTimer = timer
                return fd
            } catch { Darwin.close(fd); throw error }
        }
        Thread.detachNewThread { [self] in acceptLoop(descriptor: boundDescriptor) }
    }

    func stop() {
        queue.sync {
            guard active else { return }
            active = false
            expiryTimer?.cancel(); expiryTimer = nil
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            listener = -1
            for connection in connections.values { connection.child?.stop(); connection.finish(afterFlush: false) }
            connections.removeAll(); writers.removeAll(); sizeOwners.removeAll(); preferred.removeAll(); lastInput.removeAll()
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
            releaseWriter(connection)
            connection.child?.stop()
            connection.child = nil
            connection.mode = nil
            connection.sessionID = nil
            connection.peer = nil
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

    private func validDisplayName(_ name: String) -> Bool {
        name == name.trimmingCharacters(in: .whitespacesAndNewlines) && (1...64).contains(name.unicodeScalars.count)
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func validFields(_ raw: [String: Any], operation: LocalAgentOperation) -> Bool {
        var allowed: Set<String> = ["version", "id", "operation"]
        switch operation {
        case .status, .detach: break
        case .list: allowed.insert("peer")
        case .create: allowed.formUnion(["name", "columns", "rows", "cwd", "shared"])
        case .close: allowed.insert("session_id")
        case .share: allowed.formUnion(["session_id", "shared", "keep_private", "remote_typing"])
        case .access: allowed.insert("access")
        case .guest: allowed.formUnion(["guest", "pairing_id"])
        case .redeem: allowed.formUnion(["proof", "peer"])
        case .rename: allowed.formUnion(["session_id", "name"])
        case .attach: allowed.formUnion(["session_id", "columns", "rows", "mode", "history", "peer"])
        case .input: allowed.formUnion(["data", "automatic"])
        case .resize: allowed.formUnion(["columns", "rows"])
        }
        return Set(raw.keys).isSubset(of: allowed)
    }

    private func handle(_ request: LocalAgentRequest, on connection: AgentConnection) throws {
        func reply(session: LocalSessionInfo? = nil, sessions: [LocalSessionInfo]? = nil, status: LocalAgentStatus? = nil,
                   mode: LocalAttachmentMode? = nil, accesses: [LocalDeviceAccess]? = nil, guests: [LocalGuestInvite]? = nil) {
            connection.enqueue(LocalAgentFrame(id: request.id, kind: .response, ok: true, status: status, sessions: sessions,
                                               session: session, mode: mode, accesses: accesses, guests: guests))
        }
        func dimensions() throws -> (Int, Int) {
            guard let columns = request.columns, let rows = request.rows, validDimensions(columns: columns, rows: rows) else { throw AgentFailure(.invalidRequest) }
            return (columns, rows)
        }
        func sessionID() throws -> String {
            guard let id = request.sessionID, validSessionID(id) else { throw AgentFailure(.invalidRequest) }; return id
        }
        func peer() throws -> LocalRemotePeer? {
            guard let peer = request.peer else { return nil }
            guard validSessionID(peer.deviceID), (1...64).contains(peer.name.unicodeScalars.count),
                  peer.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  peer.pairingID.map(validSessionID) ?? true else { throw AgentFailure(.invalidRequest) }
            return peer
        }
        switch request.operation {
        case .status: reply(status: LocalAgentStatus(tmuxAvailable: engine.available, relays: relays?.snapshot() ?? []))
        case .list:
            let sessions = try engine.sessions()
            try forgetEndedSessions(live: Set(sessions.map(\.id)))
            if let remote = try peer() {
                // A paired device sees only the sessions it may reach and what
                // it may do there. A device paired with this Mac also learns
                // who else can type, by name only; an invitation's guest doesn't.
                let guest = invite(remote) != nil
                reply(sessions: sessions.filter { reachable($0.id, by: remote) }
                    .map { $0.forPeer(access: remoteAccess($0.id, for: remote),
                                      writers: guest ? nil : otherWriters($0.id, excluding: remote)) })
            } else {
                reply(sessions: sessions.map { withSharing($0) })
            }
        case .create:
            guard connection.child == nil, let name = request.name, validDisplayName(name) else { throw AgentFailure(.invalidRequest) }
            let (columns, rows) = try dimensions()
            let session = try engine.create(name: name, columns: columns, rows: rows, cwd: request.cwd, shared: request.shared == true)
            reply(session: withSharing(session))
        case .share:
            guard connection.child == nil, request.peer == nil,
                  request.shared != nil || request.keepPrivate != nil || request.remoteTyping != nil,
                  !(request.shared == true && request.keepPrivate == true) else { throw AgentFailure(.invalidRequest) }
            let id = try sessionID()
            if let keepPrivate = request.keepPrivate { try engine.setPrivate(id, keepPrivate) }
            if let shared = request.shared { try engine.setShared(id, shared) }
            if let typing = request.remoteTyping {
                if typing { remoteTypingPaused.remove(id) } else { remoteTypingPaused.insert(id) }
            }
            // Narrowing access disconnects only the paired devices it affects;
            // the shell keeps running.
            enforceRemoteAccess()
            reply(session: withSharing(try engine.session(id)))
        case .access:
            guard connection.child == nil, request.peer == nil else { throw AgentFailure(.invalidRequest) }
            if let access = request.access {
                guard validSessionID(access.deviceID), access.sessionIDs.count <= 64,
                      Set(access.sessionIDs).count == access.sessionIDs.count else { throw AgentFailure(.invalidRequest) }
                // Only live sessions can be listed, so access never waits for
                // a session that doesn't exist yet.
                let live = Set(try engine.sessions().map(\.id))
                guard access.sessionIDs.allSatisfy(live.contains) else { throw AgentFailure(.invalidRequest) }
                var next = accessPolicies
                next[access.deviceID] = access
                guard next.count <= 64 else { throw AgentFailure(.invalidRequest) }
                try state.saveDeviceAccess(next)
                accessPolicies = next
                enforceRemoteAccess()
            }
            reply(accesses: accessPolicies.values.sorted { $0.deviceID < $1.deviceID })
        case .guest:
            guard connection.child == nil, request.peer == nil else { throw AgentFailure(.invalidRequest) }
            var next = guests
            if let invite = request.guest {
                let now = Date()
                guard validSessionID(invite.pairingID), next[invite.pairingID] == nil, invite.key?.count == 32, !invite.redeemed,
                      invite.expiresAt > now, invite.expiresAt.timeIntervalSince(now) <= SessionInvitation.longestAccess + 60 else { throw AgentFailure(.invalidRequest) }
                _ = try engine.session(invite.sessionID)
                next[invite.pairingID] = invite
                guard next.values.filter({ $0.expiresAt != LocalGuestInvite.ended }).count <= 32 else { throw AgentFailure(.invalidRequest) }
            }
            if let removing = request.pairingID {
                guard validSessionID(removing), let old = next[removing] else { throw AgentFailure(.invalidRequest) }
                // A forgotten invitation's grant still reaches nothing, even if
                // revoking it on the server failed or raced an approval.
                next[removing] = LocalGuestInvite(pairingID: removing, sessionID: old.sessionID, permission: .view,
                                                  expiresAt: LocalGuestInvite.ended, redeemed: false)
                let ended = next.values.filter { $0.expiresAt == LocalGuestInvite.ended }
                for stale in ended.dropFirst(64) { next.removeValue(forKey: stale.pairingID) }
            }
            if next != guests {
                try state.saveGuests(next)
                guests = next
                enforceRemoteAccess()
            }
            reply(guests: guests.values.filter { $0.expiresAt != LocalGuestInvite.ended }.sorted { $0.pairingID < $1.pairingID }.map {
                LocalGuestInvite(pairingID: $0.pairingID, sessionID: $0.sessionID, permission: $0.permission,
                                 expiresAt: $0.expiresAt, redeemed: $0.redeemed)
            })
        case .redeem:
            // Unknown, used, expired and wrong proofs all look the same.
            guard connection.child == nil, let remote = try peer(), let pairingID = remote.pairingID,
                  let publicKey = remote.publicKey, let proof = request.proof else { throw AgentFailure(.invalidRequest) }
            guard let invite = guests[pairingID], !invite.redeemed, let key = invite.key, invite.expiresAt > Date(),
                  SessionInvitation.verify(proof: proof, key: key, pairingID: pairingID, clientPublicKey: publicKey) else { throw AgentFailure(.notFound) }
            var next = guests
            // Once redeemed the key has done its job; it isn't kept.
            next[pairingID] = LocalGuestInvite(pairingID: pairingID, sessionID: invite.sessionID, permission: invite.permission,
                                               expiresAt: invite.expiresAt, redeemed: true)
            try state.saveGuests(next)
            guests = next
            reply()
        case .rename:
            guard connection.child == nil, let name = request.name, validDisplayName(name) else { throw AgentFailure(.invalidRequest) }
            reply(session: withSharing(try engine.rename(try sessionID(), to: name)))
        case .close:
            let id = try sessionID()
            try engine.close(id)
            remoteTypingPaused.remove(id)
            try forgetEndedSessions(live: Set(try engine.sessions().map(\.id)))
            reply()
            for attached in connections.values where attached.sessionID == id {
                attached.finish(afterFlush: true, emitClosed: true)
            }
        case .attach:
            guard connection.child == nil, let mode = request.mode else { throw AgentFailure(.invalidRequest) }
            let id = try sessionID()
            let (columns, rows) = try dimensions()
            let remote = try peer()
            if let remote {
                // A session a paired device may not reach does not exist for it.
                guard reachable(id, by: remote) else { throw AgentFailure(.notFound) }
                if mode == .control, remoteAccess(id, for: remote) != .control { throw AgentFailure(.readOnly) }
            }
            let others = writers[id] ?? []
            if mode == .control, !others.isEmpty {
                // Typing is shared only when everyone who may type allows it.
                guard coTypes(remote), others.allSatisfy({ coTypes(connections[$0]?.peer) }) else { throw AgentFailure(.sessionBusy) }
            }
            let previous = try engine.verifiedSession(id)
            // Joining others who type keeps their grid until this one types.
            let changed = mode == .control && others.isEmpty && (previous.columns != columns || previous.rows != rows)
            let info = changed ? try resizeSession(previous, columns: columns, rows: rows) : previous
            // A viewer observes the controller's current window, not its stale
            // list/request grid. Its PTY must render that same authoritative size.
            let child = try engine.attach(id, columns: info.columns, rows: info.rows, mode: mode)
            connection.child = child; connection.sessionID = id; connection.mode = mode; connection.peer = remote
            if mode == .control {
                writers[id, default: []].insert(connection.token)
                preferred[connection.token] = (columns, rows)
                if others.isEmpty { sizeOwners[id] = connection.token }
            }
            // FIFO delivery guarantees the response precedes the first VT event.
            reply(session: info, mode: mode)
            if changed { connection.enqueue(LocalAgentFrame(kind: .geometry, session: info)) }
            // A renderer with its own scrollback gets earlier output first, then
            // tmux's redraw of the live screen. Its stream never switches to the
            // alternate screen, so new output scrolls into that scrollback.
            let screen = request.history == true ? AlternateScreenFilter() : nil
            if screen != nil, let earlier = try? engine.history(id, rows: info.rows) {
                for offset in stride(from: 0, to: earlier.count, by: 8192) {
                    guard connection.enqueue(LocalAgentFrame(kind: .output, data: earlier.subdata(in: offset..<min(offset + 8192, earlier.count)))) else { break }
                }
            }
            child.start(output: { [weak connection] bytes in
                let visible = screen?.filter(bytes) ?? bytes
                return visible.isEmpty ? true : connection?.enqueue(LocalAgentFrame(kind: .output, data: visible)) ?? false
            }, room: { [weak connection] in
                // A slow client slows this pane's reader; tmux coalesces meanwhile.
                connection?.waitForRoom() ?? false
            }, ended: { [weak connection] in connection?.finish(afterFlush: true, emitClosed: true) })
        case .input:
            guard let child = connection.child, let id = connection.sessionID, let data = request.data, data.count <= 16384 else { throw AgentFailure(.invalidRequest) }
            guard connection.mode == .control else { throw AgentFailure(.readOnly) }
            if let remote = connection.peer, remoteAccess(id, for: remote) != .control { throw AgentFailure(.readOnly) }
            // A terminal's automatic answers (to tmux's queries on attach, for
            // example) aren't typing: they never take the grid.
            guard request.automatic != true else { try child.send(data); reply(); return }
            let now = ProcessInfo.processInfo.systemUptime
            defer { lastInput[connection.token] = now }
            let owner = sizeOwners[id]
            let ownerTyping = owner.map { writers[id]?.contains($0) == true && now - (lastInput[$0] ?? -.infinity) < Self.ownerHold } ?? false
            if owner != connection.token, !ownerTyping {
                // Typing makes this writer's grid the session's, before its
                // input arrives, once the previous owner has paused.
                sizeOwners[id] = connection.token
                if let size = preferred[connection.token] {
                    let current = try engine.session(id)
                    if current.columns != size.columns || current.rows != size.rows {
                        _ = try resizeSession(current, columns: size.columns, rows: size.rows)
                    }
                }
            }
            try child.send(data); reply()
        case .resize:
            guard let child = connection.child, let id = connection.sessionID else { throw AgentFailure(.invalidRequest) }
            guard connection.mode == .control else { throw AgentFailure(.readOnly) }
            let (columns, rows) = try dimensions()
            preferred[connection.token] = (columns, rows)
            if let owner = sizeOwners[id], owner != connection.token, writers[id]?.contains(owner) == true {
                // Another writer's grid is in use. Remember this one for when
                // it types, and show it the grid it must render meanwhile.
                let current = try engine.session(id)
                if current.columns != columns || current.rows != rows {
                    guard connection.enqueue(LocalAgentFrame(kind: .geometry, session: current)) else { throw AgentFailure(.backpressure) }
                    try? engine.refresh(id, terminals: [child.terminalName], columns: current.columns, rows: current.rows)
                }
                reply()
                return
            }
            sizeOwners[id] = connection.token
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
            releaseWriter(connection)
            connection.child = nil
            connection.mode = nil
            connection.sessionID = nil
            connection.peer = nil
            reply()
            connection.finish(afterFlush: true)
            child.stop()
        }
    }

    /// Who else can type in a session now, as a paired device may see it: each
    /// other device once by name, and this Mac (its app, another window, or
    /// `witerm`) once as a nil name. Never the requesting device itself.
    private func otherWriters(_ id: String, excluding peer: LocalRemotePeer) -> [LocalWriterInfo] {
        var seen = Set<String>()
        return connections.values
            .filter { $0.sessionID == id && $0.child != nil && $0.mode == .control && $0.peer?.deviceID != peer.deviceID }
            .sorted { $0.token.uuidString < $1.token.uuidString }
            .compactMap { connection in
                let name = connection.peer?.name
                return seen.insert(connection.peer?.deviceID ?? "").inserted ? LocalWriterInfo(name: name) : nil
            }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    /// The session with who may reach it and who is attached to it.
    private func withSharing(_ session: LocalSessionInfo) -> LocalSessionInfo {
        let attachments = connections.values
            .filter { $0.sessionID == session.id && $0.child != nil && $0.mode != nil }
            .sorted { $0.token.uuidString < $1.token.uuidString }
            .map { LocalAttachmentInfo(mode: $0.mode!, device: $0.peer?.identity) }
        return LocalSessionInfo(id: session.id, name: session.name, createdAt: session.createdAt,
                                columns: session.columns, rows: session.rows,
                                sharing: LocalSessionSharing(shared: engine.shared.contains(session.id),
                                                             keepPrivate: engine.keptPrivate.contains(session.id),
                                                             remoteTyping: !remoteTypingPaused.contains(session.id),
                                                             attachments: attachments))
    }

    // MARK: Remote access

    private func policy(_ peer: LocalRemotePeer) -> LocalDeviceAccess {
        accessPolicies[peer.deviceID] ?? .default(for: peer.deviceID)
    }

    /// The invitation a request's grant came from, if any.
    private func invite(_ peer: LocalRemotePeer) -> LocalGuestInvite? {
        peer.pairingID.flatMap { guests[$0] }
    }

    /// Whether a paired device may list and attach to a session at all. An
    /// invitation's grant reaches its one session, once redeemed and until it expires.
    private func reachable(_ id: String, by peer: LocalRemotePeer) -> Bool {
        guard !engine.keptPrivate.contains(id) else { return false }
        if let invite = invite(peer) { return invite.redeemed && invite.sessionID == id && invite.expiresAt > Date() }
        return engine.shared.contains(id) || policy(peer).lists(id)
    }

    /// Removes ended sessions from every device's list, so a later session
    /// can never inherit access meant for one that is gone.
    private func forgetEndedSessions(live: Set<String>) throws {
        var next = accessPolicies
        for (device, access) in accessPolicies where access.sessionIDs.contains(where: { !live.contains($0) }) {
            next[device] = access.reaching(access.scope, sessions: access.sessionIDs.filter(live.contains))
        }
        guard next != accessPolicies else { return }
        try state.saveDeviceAccess(next)
        accessPolicies = next
    }

    /// The most a paired device may do in a session under this Mac's policy.
    /// The relay endpoint further limits it to the device's signed grant.
    private func remoteAccess(_ id: String, for peer: LocalRemotePeer) -> LocalAttachmentMode {
        let permission = invite(peer)?.permission ?? policy(peer).permission
        return permission == .control && !remoteTypingPaused.contains(id) ? .control : .view
    }

    /// This Mac always types alongside others, and so does someone it invited
    /// to type; a paired device only when allowed.
    private func coTypes(_ peer: LocalRemotePeer?) -> Bool {
        guard let peer else { return true }
        return invite(peer) != nil || policy(peer).coTyping
    }

    private func releaseWriter(_ connection: AgentConnection) {
        preferred.removeValue(forKey: connection.token)
        lastInput.removeValue(forKey: connection.token)
        guard let id = connection.sessionID else { return }
        writers[id]?.remove(connection.token)
        if writers[id]?.isEmpty == true { writers.removeValue(forKey: id) }
        if sizeOwners[id] == connection.token { sizeOwners.removeValue(forKey: id) }
    }

    /// Closes paired-device attachments a narrowed policy no longer allows:
    /// unreachable sessions close as `not_found`, lost typing as `read_only`.
    /// Local attachments and shells are never touched.
    private func enforceRemoteAccess() {
        for attached in connections.values {
            guard let remote = attached.peer, let id = attached.sessionID, attached.child != nil else { continue }
            let code: LocalAgentErrorCode
            if !reachable(id, by: remote) { code = .notFound }
            else if attached.mode == .control, remoteAccess(id, for: remote) != .control { code = .readOnly }
            else if attached.mode == .control, (writers[id]?.count ?? 0) > 1, !coTypes(remote) { code = .sessionBusy }
            else { continue }
            releaseWriter(attached)
            attached.finish(afterFlush: true, terminalError: code, emitClosed: true)
            attached.child?.stop()
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

/// Removes tmux's switch to and from the outer alternate screen, which it
/// sends when a client starts and stops. Programs inside a pane never reach
/// the outer terminal's alternate screen; tmux draws them itself. Without the
/// switch, a renderer's own scrollback keeps what scrolls off its screen.
/// Used only from one PTY reader thread.
final class AlternateScreenFilter: @unchecked Sendable {
    private static let switches = [Data("\u{1b}[?1049h".utf8), Data("\u{1b}[?1049l".utf8)]
    private var pending = Data()

    func filter(_ bytes: Data) -> Data {
        var input = pending + bytes
        pending.removeAll()
        for sequence in Self.switches {
            while let range = input.range(of: sequence) { input.removeSubrange(range) }
        }
        // Hold back only a tail that could still become a switch.
        if let escape = input.lastIndex(of: 0x1b), input.distance(from: escape, to: input.endIndex) < Self.switches[0].count {
            let tail = input[escape...]
            if Self.switches.contains(where: { $0.starts(with: tail) }) {
                pending = Data(tail)
                input.removeSubrange(escape...)
            }
        }
        return input
    }
}
