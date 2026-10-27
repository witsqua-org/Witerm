import Foundation
import WitermCore

/// What remote access currently looks like, for the broker's `status` reply.
/// Ready means the server accepted this Mac's relay connection.
final class RelayStatusBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: LocalRelayStatus.State] = [:]

    func set(_ server: String, _ state: LocalRelayStatus.State?) {
        lock.withLock { states[server] = state }
    }

    func snapshot() -> [LocalRelayStatus] {
        lock.withLock { states.map { LocalRelayStatus(server: $0.key, state: $0.value) } }
            .sorted { $0.server < $1.server }
    }
}

/// Owns network connections only. tmux and its shells belong to the local broker.
/// Keeps one relay listener per enabled server; each server's listener,
/// tunnels and bridges start and stop independently of the others.
actor RelayHostCoordinator {
    /// Concurrent remote tunnels across all servers.
    static let tunnelLimit = 8

    private struct Link {
        let configuration: RelayHostConfiguration
        let generation: Int
        var task: Task<Void, Never>?
        var listener: RelayHostConnection?
        var tunnels: [String: Task<Void, Never>] = [:]
        var bridges: [String: RelayTerminalBridge] = [:]
    }

    private let settings: RelayHostConfigurationStore
    private let socketURL: URL
    private let board: RelayStatusBoard
    private let pairingOverride: PairingClient?
    /// Test-supplied clients keyed by normalized server address.
    private let pairingOverrides: [String: PairingClient]
    private var monitor: Task<Void, Never>?
    private var current: [RelayHostConfiguration]?
    /// Keyed by normalized server address, which the settings store guarantees.
    private var links: [String: Link] = [:]
    private var generation = 0
    private var sleeping = false

    init(stateDirectory: URL, pairing: PairingClient? = nil, pairings: [String: PairingClient] = [:],
         board: RelayStatusBoard = RelayStatusBoard()) {
        self.board = board
        pairingOverride = pairing
        pairingOverrides = pairings
        settings = RelayHostConfigurationStore(stateDirectory: stateDirectory)
        socketURL = stateDirectory.appendingPathComponent("agent.sock")
    }

    func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSettings()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop() async {
        monitor?.cancel(); monitor = nil
        current = nil
        await stopAll()
    }

    func prepareForSleep() async {
        sleeping = true
        current = nil
        await stopAll()
    }

    func resumeAfterWake() async {
        sleeping = false
        current = nil
        await refreshSettings()
    }

    private func refreshSettings() async {
        guard !sleeping, monitor != nil else { return }
        // Invalid/missing settings disable remote access rather than retain old access.
        let next = ((try? settings.readAll()) ?? []).filter(\.enabled)
        guard next != current else { return }
        current = next
        let desired = Dictionary(uniqueKeysWithValues: next.map { ($0.serverAddress, $0) })
        // A changed entry (such as a new device name) restarts only its server.
        for (server, link) in links where desired[server] != link.configuration {
            await stopLink(server)
            guard current == next else { return }
        }
        guard !Task.isCancelled, !sleeping, monitor != nil, current == next else { return }
        for (server, configuration) in desired where links[server] == nil {
            generation += 1
            let expected = generation
            links[server] = Link(configuration: configuration, generation: expected)
            board.set(server, .connecting)
            links[server]?.task = Task { [weak self] in
                await self?.listen(server: server, configuration: configuration, expected: expected)
            }
        }
    }

    private func stopAll() async {
        for server in Array(links.keys) { await stopLink(server) }
    }

    private func stopLink(_ server: String) async {
        guard let link = links.removeValue(forKey: server) else { return }
        board.set(server, nil)
        link.task?.cancel()
        for task in link.tunnels.values { task.cancel() }
        await link.listener?.disconnect()
        for bridge in link.bridges.values { await bridge.close() }
    }

    private func isCurrent(_ server: String, _ expected: Int) -> Bool {
        links[server]?.generation == expected
    }

    /// Drops one server's listener, tunnels and bridges after a failure,
    /// keeping its entry so the listener reconnects.
    private func resetLink(_ server: String, _ expected: Int) async {
        guard isCurrent(server, expected), var link = links[server] else { return }
        let old = link.listener, tunnels = link.tunnels, bridges = link.bridges
        link.listener = nil; link.tunnels = [:]; link.bridges = [:]
        links[server] = link
        board.set(server, .connecting)
        for task in tunnels.values { task.cancel() }
        await old?.disconnect()
        for bridge in bridges.values { await bridge.close() }
    }

    private func listen(server: String, configuration: RelayHostConfiguration, expected: Int) async {
        var delay = 1
        while !Task.isCancelled, isCurrent(server, expected) {
            let began = ContinuousClock.now
            do {
                let pairing = try pairingOverrides[server] ?? pairingOverride ?? PairingClient(serverAddress: configuration.serverAddress,
                                                deviceName: configuration.deviceName, platform: .macos)
                _ = try await pairing.relayCredentials(forceRefresh: true)
                let connection = try await RelayHostConnection.connect(pairing: pairing)
                guard !Task.isCancelled, isCurrent(server, expected) else {
                    await connection.disconnect(); return
                }
                links[server]?.listener = connection
                board.set(server, .ready)
                for try await offer in connection.offers {
                    try Task.checkCancellation()
                    guard isCurrent(server, expected) else { break }
                    admit(offer, server: server, pairing: pairing, expected: expected)
                }
                await connection.disconnect()
            } catch { /* No raw network errors, credentials or payloads are logged. */ }
            guard !Task.isCancelled, isCurrent(server, expected) else { return }
            await resetLink(server, expected)
            guard !Task.isCancelled, isCurrent(server, expected) else { return }
            if began.duration(to: .now) > .seconds(30) { delay = 1 }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            delay = min(30, delay * 2)
        }
    }

    private func admit(_ offer: RelayOffer, server: String, pairing: PairingClient, expected: Int) {
        let open = links.values.reduce(0) { $0 + $1.tunnels.count }
        guard open < Self.tunnelLimit, isCurrent(server, expected),
              links[server]?.tunnels[offer.tunnelID] == nil else { return }
        links[server]?.tunnels[offer.tunnelID] = Task { [weak self] in
            guard let self else { return }
            await self.serve(offer, server: server, pairing: pairing, expected: expected)
        }
    }

    private func serve(_ offer: RelayOffer, server: String, pairing: PairingClient, expected: Int) async {
        do {
            let channel = try await RelaySecureChannel.host(pairing: pairing, offer: offer)
            guard isCurrent(server, expected), !Task.isCancelled else { await channel.close(); return }
            let bridge = RelayTerminalBridge(channel: channel, pairing: pairing,
                                              local: LocalAgentClient(socketURL: socketURL), traceID: offer.tunnelID)
            links[server]?.bridges[offer.tunnelID] = bridge
            await bridge.run()
        } catch { /* Failed authentication never reaches the local broker. */ }
        guard isCurrent(server, expected) else { return }
        links[server]?.bridges.removeValue(forKey: offer.tunnelID)
        links[server]?.tunnels.removeValue(forKey: offer.tunnelID)
    }
}

/// A deliberately smaller remote surface than the private local Socket protocol.
enum RelayTerminalPolicy {
    static func request(_ data: Data, attached: Bool, permission: PairingPermission) throws -> LocalAgentRequest {
        guard data.count <= 49_152,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = try? JSONDecoder().decode(LocalAgentRequest.self, from: data),
              request.version == 1, validSessionID(request.id) else { throw AgentFailure(.invalidRequest) }
        let allowed: Set<String>
        switch request.operation {
        case .status, .list:
            guard !attached else { throw AgentFailure(.invalidRequest) }
            allowed = ["version", "id", "operation"]
        case .attach:
            guard !attached, let id = request.sessionID, validSessionID(id),
                  let columns = request.columns, let rows = request.rows,
                  validDimensions(columns: columns, rows: rows), let mode = request.mode else { throw AgentFailure(.invalidRequest) }
            guard permission == .control || mode == .view else { throw AgentFailure(.readOnly) }
            allowed = ["version", "id", "operation", "session_id", "columns", "rows", "mode"]
        case .input:
            guard attached, let bytes = request.data, bytes.count <= 16_384 else { throw AgentFailure(.invalidRequest) }
            guard permission == .control else { throw AgentFailure(.readOnly) }
            allowed = ["version", "id", "operation", "data"]
        case .resize:
            guard attached, let columns = request.columns, let rows = request.rows,
                  validDimensions(columns: columns, rows: rows) else { throw AgentFailure(.invalidRequest) }
            guard permission == .control else { throw AgentFailure(.readOnly) }
            allowed = ["version", "id", "operation", "columns", "rows"]
        case .detach:
            guard attached else { throw AgentFailure(.invalidRequest) }
            allowed = ["version", "id", "operation"]
        case .create, .close, .share: throw AgentFailure(.invalidRequest)
        }
        guard Set(object.keys).isSubset(of: allowed) else { throw AgentFailure(.invalidRequest) }
        return request
    }
}

private enum RelayBridgeWorkResult: Sendable, Equatable { case outputEnded, outputDetached, readerEnded, deadline }

actor RelayTerminalBridge {
    private let channel: RelaySecureChannel
    private let pairing: PairingClient
    private let local: LocalAgentClient
    private let traceID: String
    private var attachment: LocalTerminalAttachment?
    private var closed = false
    private var detaching = false

    init(channel: RelaySecureChannel, pairing: PairingClient, local: LocalAgentClient, traceID: String = "") {
        self.channel = channel; self.pairing = pairing; self.local = local; self.traceID = traceID
    }

    func close() async {
        guard !closed else { return }
        closed = true
        let previous = attachment; attachment = nil
        await channel.close()
        await previous?.disconnect()
    }

    func run() async {
        let grant = await channel.grant
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.requests(grant: grant) }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        let current = try await self.pairing.trustedRelayGrant(id: grant.id)
                        guard current == grant else { throw AgentFailure(.unavailable) }
                    }
                }
                do { _ = try await group.next() }
                catch { await close(); group.cancelAll(); throw error }
                await close(); group.cancelAll()
            }
        } catch { trace("run-failed", error: error); await close() }
    }

    private func requests(grant: DeviceGrant) async throws {
        while !Task.isCancelled, !closed {
            let bytes = try await initialRequest()
            let current = try await pairing.trustedRelayGrant(id: grant.id)
            guard current == grant else { throw AgentFailure(.unavailable) }
            var request: LocalAgentRequest?
            do {
                request = try RelayTerminalPolicy.request(bytes, attached: attachment != nil, permission: grant.permission)
                guard let request else { throw AgentFailure(.invalidRequest) }
                switch request.operation {
                case .status:
                    let status = try await local.status()
                    // Remote devices learn only whether tmux exists, not this Mac's servers.
                    try await reply(request, status: LocalAgentStatus(tmuxAvailable: status.tmuxAvailable))
                    await awaitPeerClose(); return
                case .list:
                    let sessions = try await local.sessions(peer: peer(grant))
                    try await reply(request, sessions: sessions); await awaitPeerClose(); return
                case .attach:
                    trace("local-attach-start")
                    let connection = try await local.attach(sessionID: request.sessionID!, columns: request.columns!, rows: request.rows!,
                                                            mode: request.mode!, peer: peer(grant))
                    guard !closed else { await connection.disconnect(); return }
                    attachment = connection
                    trace("local-attach-ready")
                    try await reply(request, session: connection.session, mode: request.mode)
                    trace("attach-ack-sent")
                    try await attachedRequestsAndOutput(connection, grant: grant)
                    return
                default: throw AgentFailure(.invalidRequest)
                }
            } catch {
                trace("initial-request-error", error: error)
                try await errorReply(id: request?.id ?? recoverID(bytes), error: error)
                await awaitPeerClose()
                return
            }
        }
    }

    /// The paired device this channel acts for. The broker shows it only
    /// shared sessions.
    private func peer(_ grant: DeviceGrant) -> LocalRemotePeer {
        LocalRemotePeer(deviceID: grant.client.id, name: grant.client.name)
    }

    private func initialRequest() async throws -> Data {
        let channel = channel
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await channel.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw AgentFailure(.unavailable)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AgentFailure(.unavailable) }
            return result
        }
    }

    private func attachedRequestsAndOutput(_ connection: LocalTerminalAttachment, grant: DeviceGrant) async throws {
        try await withThrowingTaskGroup(of: RelayBridgeWorkResult.self) { group in
            group.addTask {
                do {
                    for try await event in connection.events {
                        try Task.checkCancellation()
                        switch event {
                        case .output(let data): try await self.send(LocalAgentFrame(kind: .output, data: data))
                        case .geometry(let session): try await self.send(LocalAgentFrame(kind: .geometry, session: session))
                        }
                    }
                    if await self.detaching { return .outputDetached }
                    await self.trace("local-output-ended")
                    try await self.send(LocalAgentFrame(kind: .closed))
                    return .outputEnded
                } catch {
                    if await self.detaching { return .outputDetached }
                    await self.trace("local-output-error", error: error)
                    throw error
                }
            }
            group.addTask {
                try await self.attachedRequests(connection, grant: grant)
                return .readerEnded
            }
            do {
                let first = try await group.next()
                if first == .outputDetached {
                    // Local detach completes output before the remote ACK. The
                    // request reader owns that ACK and its bounded peer close.
                    _ = try await group.next()
                } else if first == .outputEnded {
                    // The existing reader observes the peer closing after the final
                    // event. Never start a competing receive on this secure channel.
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        return .deadline
                    }
                    _ = try await group.next()
                }
            } catch { await close(); group.cancelAll(); throw error }
            await close(); group.cancelAll()
        }
    }

    private func attachedRequests(_ connection: LocalTerminalAttachment, grant: DeviceGrant) async throws {
        while !Task.isCancelled, !closed {
            let bytes = try await channel.receive()
            let current = try await pairing.trustedRelayGrant(id: grant.id)
            guard current == grant else { throw AgentFailure(.unavailable) }
            var request: LocalAgentRequest?
            do {
                request = try RelayTerminalPolicy.request(bytes, attached: true, permission: grant.permission)
                guard let request else { throw AgentFailure(.invalidRequest) }
                switch request.operation {
                case .input: try await connection.send(request.data!)
                case .resize: try await connection.resize(columns: request.columns!, rows: request.rows!)
                case .detach:
                    detaching = true
                    do {
                        try await connection.detach()
                        attachment = nil
                        try await reply(request)
                    } catch {
                        try await errorReply(id: request.id, error: error)
                    }
                    await awaitPeerClose()
                    return
                default: throw AgentFailure(.invalidRequest)
                }
                try await reply(request)
            } catch { try await errorReply(id: request?.id ?? recoverID(bytes), error: error) }
        }
    }

    // A completed WebSocket send may still be queued in the relay. Let the
    // recipient consume the final response and close, instead of canceling it.
    private func awaitPeerClose() async {
        let channel = channel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await channel.receive() }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func trace(_ phase: String, error: Error? = nil) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["WITERM_RELAY_TRACE"] == "1" else { return }
        let tag: String
        if let failure = error as? AgentFailure { tag = failure.code.rawValue }
        else if let failure = error as? LocalAgentClientError { tag = String(describing: failure) }
        else if let failure = error as? RelayError { tag = String(describing: failure) }
        else if error is CancellationError { tag = "cancelled" }
        else { tag = error == nil ? "ok" : "other" }
        // Fixed phases/error enums and an opaque route prefix only, never data.
        print("relay-bridge[\(traceID.prefix(8))] \(phase): \(tag)")
        #endif
    }

    private func reply(_ request: LocalAgentRequest, session: LocalSessionInfo? = nil,
                       sessions: [LocalSessionInfo]? = nil, status: LocalAgentStatus? = nil,
                       mode: LocalAttachmentMode? = nil) async throws {
        try await send(LocalAgentFrame(id: request.id, kind: .response, ok: true, status: status,
                                       sessions: sessions, session: session, mode: mode))
    }

    private func errorReply(id: String?, error: Error) async throws {
        let code: LocalAgentErrorCode
        if let error = error as? AgentFailure { code = error.code }
        else if let error = error as? LocalAgentClientError, case .rejected(let rejection) = error { code = rejection }
        else { code = .unavailable }
        try await send(LocalAgentFrame(id: id, kind: .response, ok: false, error: code))
    }

    private func recoverID(_ bytes: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let id = object["id"] as? String, validSessionID(id) else { return nil }
        return id
    }

    private func send(_ frame: LocalAgentFrame) async throws {
        guard !closed else { throw AgentFailure(.unavailable) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try await channel.send(encoder.encode(frame))
    }
}
