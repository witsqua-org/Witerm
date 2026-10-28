import Darwin
import Foundation
import XCTest
@testable import WitermCore
@testable import WitermAgent

private final class RelayLiveMemorySecureStore: PairingSecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func create(_ data: Data, account: String) throws -> Bool {
        lock.withLock {
            guard values[account] == nil else { return false }
            values[account] = data
            return true
        }
    }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }

    func tombstone(_ grant: DeviceGrant, server: URL) throws {
        let account = PairingTrustLedger.account(server: server.absoluteString, publicKey: grant.host.publicKey)
        try lock.withLock {
            guard let data = values[account] else { throw RelayError.untrusted }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var ledger = try decoder.decode(PairingTrustLedger.self, from: data)
            ledger.revokedPairings.insert(grant.pairingID)
            ledger.grants.removeValue(forKey: grant.id)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            values[account] = try encoder.encode(ledger)
        }
    }
}

private actor RelayLiveCapture {
    private var bytes = Data()
    private(set) var finished = false
    func append(_ data: Data) throws {
        guard bytes.count + data.count <= 262_144 else { throw RelayError.backpressure }
        bytes.append(data)
    }
    func contains(_ marker: String) -> Bool { String(decoding: bytes, as: UTF8.self).contains(marker) }
    func finish() { finished = true }
}

/// Faults only this test endpoint's next application write. Native WebSocket
/// heartbeat/certificate validation and the real Docker/Noise path stay intact.
private final class RelayLiveFaultSocket: RelaySocketIO, @unchecked Sendable {
    private let socket: RelayWebSocket
    private let lock = NSLock()
    private var failNextWrite = false
    private let jitter: Bool
    private var delayIndex = 0
    private var injectedDelays: [Int] = []
    private var nextReadStall = false
    private var reading = false
    private var writing = false
    private var closed = false

    init(credentials: RelayCredentials, tunnelID: String, jitter: Bool = false) throws {
        self.jitter = jitter
        socket = try RelayWebSocket(credentials: credentials, path: "v1/relay/tunnels/\(tunnelID)")
    }

    func failNextApplicationWrite() { lock.withLock { failNextWrite = true } }
    func stallNextApplicationRead() { lock.withLock { nextReadStall = true } }
    func delayRange() -> (Int, Int, Int) { lock.withLock { (injectedDelays.count, injectedDelays.min() ?? 0, injectedDelays.max() ?? 0) } }

    private func delayLocked() -> Int {
        guard jitter else { return 0 }
        let value = [100, 300, 160, 240][delayIndex % 4]
        delayIndex += 1
        // Test instrumentation is also bounded; only the range/count matters.
        if injectedDelays.count < 64 { injectedDelays.append(value) }
        return value
    }

    func send(_ data: Data) async throws {
        let (fail, milliseconds) = try lock.withLock {
            guard !closed else { throw RelayError.transport }
            guard !writing else { throw RelayError.backpressure }
            writing = true
            let next = failNextWrite
            failNextWrite = false
            return (next, delayLocked())
        }
        defer { lock.withLock { writing = false } }
        if fail {
            close()
            throw RelayError.transport
        }
        try await withTaskCancellationHandler {
            if milliseconds > 0 { try await Task.sleep(for: .milliseconds(milliseconds)) }
            try await socket.send(data)
        } onCancel: { self.close() }
    }

    func receive() async throws -> Data {
        try lock.withLock {
            guard !closed else { throw RelayError.transport }
            guard !reading else { throw RelayError.backpressure }
            reading = true
        }
        defer { lock.withLock { reading = false } }
        return try await withTaskCancellationHandler {
            let data = try await socket.receive()
            let milliseconds = lock.withLock {
                if nextReadStall { nextReadStall = false; return 6_500 }
                return delayLocked()
            }
            if milliseconds > 0 { try await Task.sleep(for: .milliseconds(milliseconds)) }
            guard !lock.withLock({ closed }) else { throw RelayError.transport }
            return data
        } onCancel: { self.close() }
    }
    func close() { lock.withLock { closed = true }; socket.close() }
}

@MainActor
final class RelayLiveTests: XCTestCase {
    private func eventually(_ description: String, seconds: Double = 8,
                            _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail(description)
        throw RelayError.unavailable
    }

    private func capture(_ attachment: RemoteTerminalAttachment, into result: RelayLiveCapture) -> Task<Void, Never> {
        Task.detached {
            do {
                for try await data in attachment.output { try await result.append(data) }
            } catch { /* Expected on disconnect/revocation; never log terminal payloads. */ }
            await result.finish()
        }
    }

    private func captureEvents(_ attachment: RemoteTerminalAttachment, into result: TerminalGeometryCapture) -> Task<Void, Never> {
        Task.detached {
            do { for try await event in attachment.events { try await result.append(event) } }
            catch { await result.finish(error: error); return }
            await result.finish()
        }
    }

    private func pair(host: PairingClient, phone: PairingClient, server: String,
                      permission: PairingPermission) async throws -> DeviceGrant {
        _ = try await phone.register()
        let invitation = try await host.createPairing()
        let pasted = try PairingInvitation(urlString: invitation.urlString, expectedServer: server)
        let joined = try await phone.join(pasted)
        XCTAssertEqual(joined.status, .pending)
        let pending = try await host.pairing(id: invitation.pairingID)
        let approval = try await host.approve(pending, permission: permission)
        let grant = try XCTUnwrap(approval.grant)
        let accepted = try await phone.pairing(id: invitation.pairingID)
        XCTAssertEqual(accepted.grant?.id, grant.id)
        let hostTrust = try await host.trustedRelayGrant(id: grant.id)
        let phoneTrust = try await phone.trustedRelayGrant(id: grant.id)
        XCTAssertEqual(hostTrust, phoneTrust)
        return grant
    }

    private func response(to request: LocalAgentRequest, from channel: RelaySecureChannel) async throws -> LocalAgentFrame {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try await channel.send(encoder.encode(request))
        for _ in 0..<64 {
            let bytes = try await relayDeadline(5) { try await channel.receive() }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let frame = try decoder.decode(LocalAgentFrame.self, from: bytes)
            if frame.id == request.id { return frame }
            guard frame.kind == .output else { throw RelayError.invalidMessage }
        }
        throw RelayError.backpressure
    }

    private func panePID(sessionID: String, directory: URL, configuration: AgentConfiguration) throws -> Int32 {
        let runner = CommandRunner(executable: try XCTUnwrap(configuration.tmuxPath), environment: configuration.environment)
        let result = try runner.run(["-S", directory.appendingPathComponent("tmux.sock").path,
                                     "display-message", "-p", "-t", "witerm-" + sessionID, "#{pane_pid}"])
        XCTAssertEqual(result.status, 0)
        let value = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(value))
    }

    private func faultableAttachment(pairing: PairingClient, grantID: String, sessionID: String, jitter: Bool = false)
        async throws -> (RemoteTerminalAttachment, RelayLiveFaultSocket) {
        let grant = try await pairing.trustedRelayGrant(id: grantID)
        let credentials = try await pairing.relayCredentials()
        let tunnelID = try await RelayNetwork.createTunnel(credentials: credentials, grantID: grantID)
        let socket = try RelayLiveFaultSocket(credentials: credentials, tunnelID: tunnelID, jitter: jitter)
        let channel = try await RelaySecureChannel.establish(pairing: pairing, credentials: credentials,
            grant: grant, tunnelID: tunnelID, role: .client, socket: socket)
        let rpc = RemoteRPCConnection(channel: channel)
        await rpc.start()
        do {
            let frame = try await rpc.request(LocalAgentRequest(operation: .attach, sessionID: sessionID,
                columns: 111, rows: 39, mode: .control))
            let session = try XCTUnwrap(frame.session)
            return (RemoteTerminalAttachment(connection: rpc, session: session, mode: .control), socket)
        } catch {
            await rpc.close()
            throw error
        }
    }

    /// One Mac host listens through two servers at once. Turning one server
    /// off takes the Mac offline there only. A loopback server counts twice:
    /// `localhost` and `127.0.0.1` normalize to different servers, each with
    /// its own identities and grants.
    func testLiveHostServesSeveralServersAtOnce() async throws {
        guard let first = ProcessInfo.processInfo.environment["WITERM_RELAY_LIVE_SERVER_URL"] else {
            throw XCTSkip("Set WITERM_RELAY_LIVE_SERVER_URL to exercise the real relay and isolated tmux")
        }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else {
            throw XCTSkip("A real tmux installation is required")
        }
        let environment = ProcessInfo.processInfo.environment
        var alternate = URLComponents(string: first)
        let loopback = alternate?.host == "localhost"
        alternate?.host = loopback ? "127.0.0.1" : nil
        guard let second = environment["WITERM_RELAY_LIVE_SECOND_SERVER_URL"] ?? alternate?.url?.absoluteString else {
            throw XCTSkip("Set WITERM_RELAY_LIVE_SECOND_SERVER_URL, or use a localhost server")
        }
        let servers = [try PairingServerAddress.normalized(first).absoluteString,
                       try PairingServerAddress.normalized(second).absoluteString]
        XCTAssertNotEqual(servers[0], servers[1])
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        var hosts: [String: PairingClient] = [:]
        var remotes: [RemoteTerminalClient] = []
        for (index, server) in servers.enumerated() {
            let host = try PairingClient(serverAddress: server, deviceName: "Multi Mac \(index) " + suffix, platform: .macos,
                                         store: RelayLiveMemorySecureStore(), transport: URLSessionPairingTransport())
            let phone = try PairingClient(serverAddress: server, deviceName: "Multi iOS \(index) " + suffix, platform: .ios,
                                          store: RelayLiveMemorySecureStore(), transport: URLSessionPairingTransport())
            _ = try await host.register()
            let grant = try await pair(host: host, phone: phone, server: server, permission: .view)
            addTeardownBlock { try? await phone.revoke(grantID: grant.id) }
            hosts[server] = host
            remotes.append(RemoteTerminalClient(pairing: phone, grantID: grant.id))
        }

        let directory = URL(fileURLWithPath: "/private/tmp/witerm-relay-multi-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = try AgentConfiguration(stateDirectory: directory, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        let coordinator = RelayHostCoordinator(stateDirectory: directory, pairings: hosts)
        let local = LocalAgentClient(socketURL: directory.appendingPathComponent("agent.sock"))
        addTeardownBlock {
            await coordinator.stop()
            for session in (try? await local.sessions()) ?? [] { try? await local.close(sessionID: session.id) }
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", directory.appendingPathComponent("tmux.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        try broker.start()
        let created = try await local.create(name: "Multi server " + suffix, shared: true)
        let store = RelayHostConfigurationStore(stateDirectory: directory)
        try store.writeAll(servers.map { RelayHostConfiguration(serverAddress: $0, deviceName: "Multi Mac " + suffix, enabled: true) })
        await coordinator.start()
        // Each poll opens a tunnel, which the server rate-limits per device;
        // poll gently and treat a limited attempt as "not yet".
        for remote in remotes {
            try await eventually("The Mac did not come online through every server", seconds: 20) {
                do { return try await remote.sessions().map(\.id) == [created.id] }
                catch RelayError.offline, RelayError.backpressure {
                    try await Task.sleep(for: .milliseconds(500)); return false
                }
            }
        }

        // Turning one server off leaves the other reachable.
        try store.upsert(RelayHostConfiguration(serverAddress: servers[1], deviceName: "Multi Mac " + suffix, enabled: false))
        try await eventually("The disabled server still reached the Mac", seconds: 20) {
            do { _ = try await remotes[1].sessions() } catch RelayError.offline { return true }
            catch RelayError.backpressure {}
            try await Task.sleep(for: .milliseconds(500)); return false
        }
        let listing = try await remotes[0].sessions()
        XCTAssertEqual(listing.map(\.id), [created.id], "The other server must stay connected")
    }

    /// A session invitation over the real server and relay: its grant reaches
    /// nothing until the recipient proves the link's key inside the encrypted
    /// channel, then only its session and permission, and nothing once the
    /// Mac forgets it, even while the server still lists the grant.
    func testLiveSessionInvitationReachesOneSession() async throws {
        guard let address = ProcessInfo.processInfo.environment["WITERM_RELAY_LIVE_SERVER_URL"] else {
            throw XCTSkip("Set WITERM_RELAY_LIVE_SERVER_URL to exercise the real relay and isolated tmux")
        }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else {
            throw XCTSkip("A real tmux installation is required")
        }
        let server = try PairingServerAddress.normalized(address).absoluteString
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        let host = try PairingClient(serverAddress: server, deviceName: "Invite Mac " + suffix, platform: .macos,
                                     store: RelayLiveMemorySecureStore(), transport: URLSessionPairingTransport())
        let guest = try PairingClient(serverAddress: server, deviceName: "Invite Guest " + suffix, platform: .ios,
                                      store: RelayLiveMemorySecureStore(), transport: URLSessionPairingTransport())
        _ = try await host.register()
        _ = try await guest.register()

        let directory = URL(fileURLWithPath: "/private/tmp/witerm-relay-invite-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = try AgentConfiguration(stateDirectory: directory, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        let coordinator = RelayHostCoordinator(stateDirectory: directory, pairings: [server: host])
        let local = LocalAgentClient(socketURL: directory.appendingPathComponent("agent.sock"))
        addTeardownBlock {
            await coordinator.stop()
            for session in (try? await local.sessions()) ?? [] { try? await local.close(sessionID: session.id) }
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", directory.appendingPathComponent("tmux.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        try broker.start()
        let invited = try await local.create(name: "Invited " + suffix)
        let shared = try await local.create(name: "Shared " + suffix, shared: true)
        try RelayHostConfigurationStore(stateDirectory: directory)
            .writeAll([RelayHostConfiguration(serverAddress: server, deviceName: "Invite Mac " + suffix, enabled: true)])
        await coordinator.start()

        // The Mac records the invitation before its link exists.
        let created = try await host.createPairing()
        let key = SessionInvitation.newProofKey()
        let until = Date().addingTimeInterval(600)
        _ = try await local.guests(adding: LocalGuestInvite(pairingID: created.pairingID, sessionID: invited.id,
                                                            permission: .view, expiresAt: until, key: key))
        let link = SessionInvitation.make(pairing: created, permission: .view, expiresAt: until, proofKey: key)
        let received = try SessionInvitation(urlString: link.urlString)
        _ = try await guest.join(received.pairingInvitation())
        let approved = try await host.approve(try await host.pairing(id: created.pairingID), permission: .view)
        let grant = try XCTUnwrap(approved.grant)
        addTeardownBlock { try? await guest.revoke(grantID: grant.id) }
        let signed = try await guest.grants().first { $0.pairingID == created.pairingID }
        XCTAssertEqual(signed?.permission, received.permission)
        let remote = RemoteTerminalClient(pairing: guest, grantID: grant.id)

        // Before the proof, even a shared session is out of reach.
        try await eventually("The Mac did not come online", seconds: 20) {
            do { return try await remote.sessions().isEmpty }
            catch RelayError.offline, RelayError.backpressure { try await Task.sleep(for: .milliseconds(500)); return false }
        }
        let forged = SessionInvitation.make(pairing: created, permission: .view, expiresAt: until, proofKey: SessionInvitation.newProofKey())
        do { try await remote.redeem(forged); XCTFail("A proof without the link's key was accepted") }
        catch RelayError.sessionUnavailable { }
        try await remote.redeem(received)
        let listed = try await remote.sessions()
        XCTAssertEqual(listed.map(\.id), [invited.id], "An invitation reached more than its session")
        XCTAssertEqual(listed.first?.access, .view)
        do { let leaked = try await remote.attach(sessionID: shared.id, mode: .view); await leaked.disconnect(); XCTFail("An invitation reached a shared session") }
        catch RelayError.sessionUnavailable { }
        let watching = try await remote.attach(sessionID: invited.id, columns: invited.columns, rows: invited.rows, mode: .view, history: true)
        try await watching.detach()

        // Once the Mac forgets it, the grant reaches nothing, though the server still lists it.
        _ = try await local.guests(removing: created.pairingID)
        let forgotten = try await remote.sessions()
        XCTAssertTrue(forgotten.isEmpty, "A forgotten invitation's grant fell back to another policy")
    }

    func testLiveEncryptedTerminalAndLocalRevocation() async throws {
        guard let address = ProcessInfo.processInfo.environment["WITERM_RELAY_LIVE_SERVER_URL"] else {
            throw XCTSkip("Set WITERM_RELAY_LIVE_SERVER_URL to exercise the real relay and isolated tmux")
        }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else {
            throw XCTSkip("A real tmux installation is required")
        }
        var stage = "pairing"
        defer { print("Relay live last stage: \(stage)") }
        let server = try PairingServerAddress.normalized(address)
        let hostStore = RelayLiveMemorySecureStore()
        let phoneStore = RelayLiveMemorySecureStore()
        let viewerStore = RelayLiveMemorySecureStore()
        let alternateStore = RelayLiveMemorySecureStore()
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        let host = try PairingClient(serverAddress: address, deviceName: "Live Mac " + suffix, platform: .macos,
                                     store: hostStore, transport: URLSessionPairingTransport())
        let phone = try PairingClient(serverAddress: address, deviceName: "Live iOS " + suffix, platform: .ios,
                                      store: phoneStore, transport: URLSessionPairingTransport())
        let viewer = try PairingClient(serverAddress: address, deviceName: "Live Viewer " + suffix, platform: .ios,
                                       store: viewerStore, transport: URLSessionPairingTransport())
        let alternate = try PairingClient(serverAddress: address, deviceName: "Live Second iOS " + suffix, platform: .ios,
                                          store: alternateStore, transport: URLSessionPairingTransport())
        _ = try await host.register()
        let controlGrant = try await pair(host: host, phone: phone, server: address, permission: .control)
        addTeardownBlock { try? await phone.revoke(grantID: controlGrant.id) }
        let viewGrant = try await pair(host: host, phone: viewer, server: address, permission: .view)
        addTeardownBlock { try? await viewer.revoke(grantID: viewGrant.id) }
        let alternateGrant = try await pair(host: host, phone: alternate, server: address, permission: .control)
        addTeardownBlock { try? await alternate.revoke(grantID: alternateGrant.id) }

        stage = "local broker"
        let directory = URL(fileURLWithPath: "/private/tmp/witerm-relay-live-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = try AgentConfiguration(stateDirectory: directory, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        let coordinator = RelayHostCoordinator(stateDirectory: directory, pairing: host)
        let local = LocalAgentClient(socketURL: directory.appendingPathComponent("agent.sock"))
        addTeardownBlock {
            await coordinator.stop()
            for session in (try? await local.sessions()) ?? [] { try? await local.close(sessionID: session.id) }
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", directory.appendingPathComponent("tmux.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        try broker.start()
        let created = try await local.create(name: "Relay live " + suffix, shared: true)
        try RelayHostConfigurationStore(stateDirectory: directory).upsert(
            RelayHostConfiguration(serverAddress: address, deviceName: "Live Mac " + suffix, enabled: true))
        await coordinator.start()
        stage = "remote list"
        let remote = RemoteTerminalClient(pairing: phone, grantID: controlGrant.id)
        var listing: [LocalSessionInfo] = []
        try await eventually("The real Mac host did not become available", seconds: 15) {
            do { listing = try await remote.sessions(); return true }
            catch RelayError.offline { return false }
        }
        XCTAssertEqual(listing.map(\.id), [created.id])

        stage = "unshared session stays private"
        let hidden = try await local.create(name: "Private " + suffix)
        let visible = try await remote.sessions()
        XCTAssertEqual(visible.map(\.id), [created.id], "A paired device listed an unshared session")
        do {
            let leaked = try await remote.attach(sessionID: hidden.id, mode: .view)
            await leaked.disconnect()
            XCTFail("A paired device attached to an unshared session")
        } catch RelayError.sessionUnavailable { }
        try await local.close(sessionID: hidden.id)

        stage = "control attach and input"
        let control = try await remote.attach(sessionID: created.id)
        let initial = RelayLiveCapture()
        let initialReader = capture(control, into: initial)
        defer { initialReader.cancel() }
        let originalPID = try panePID(sessionID: created.id, directory: directory, configuration: configuration)
        try await control.send(Data("printf 'RELAY_''\(suffix)\\n'\n".utf8))
        try await eventually("Encrypted input did not reach the real shell") { await initial.contains("RELAY_" + suffix) }
        stage = "second controller rejection"
        // Typing alongside is this Mac's choice per device; without it, a
        // second controller waits for the first to leave.
        _ = try await local.deviceAccess(LocalDeviceAccess(deviceID: controlGrant.client.id, scope: .shared,
                                                           permission: .control, coTyping: false))
        do {
            let conflict = try await remote.attach(sessionID: created.id)
            await conflict.disconnect()
            XCTFail("A second remote controller was accepted")
        } catch RelayError.sessionBusy { }
        stage = "control resize"
        try await control.resize(columns: 111, rows: 39)
        try await control.send(Data("WITERM_VIEW_GUARD=untouched; printf 'RELAY_''SIZE:%s\\n' \"$(stty size)\"\n".utf8))
        try await eventually("Encrypted resize did not reach the real PTY") { await initial.contains("RELAY_SIZE:39 111") }

        stage = "view SDK authorization"
        let readOnlyClient = RemoteTerminalClient(pairing: viewer, grantID: viewGrant.id)
        do {
            let wrongMode = try await readOnlyClient.attach(sessionID: created.id, mode: .control)
            await wrongMode.disconnect()
            XCTFail("A view grant obtained a control attachment")
        } catch RelayError.readOnly { }
        // Use authenticated encrypted wire directly, bypassing the SDK's view
        // checks, to prove the Mac enforces the grant and attachment permission.
        stage = "view wire control rejection"
        let forbidden = try await RelaySecureChannel.client(pairing: viewer, grantID: viewGrant.id)
        let denied = try await response(to: LocalAgentRequest(operation: .attach, sessionID: created.id,
            columns: 80, rows: 24, mode: .control), from: forbidden)
        XCTAssertEqual(denied.error, .readOnly)
        await forbidden.close()

        stage = "view wire attach"
        let observerChannel = try await RelaySecureChannel.client(pairing: viewer, grantID: viewGrant.id)
        let attached = try await response(to: LocalAgentRequest(operation: .attach, sessionID: created.id,
            columns: 20, rows: 5, mode: .view), from: observerChannel)
        XCTAssertEqual(attached.ok, true)
        XCTAssertEqual(attached.session?.columns, 111)
        XCTAssertEqual(attached.session?.rows, 39)
        let observed = RelayLiveCapture()
        stage = "view wire repaint"
        for _ in 0..<64 {
            let bytes = try await relayDeadline(5) { try await observerChannel.receive() }
            let frame = try wireDecoder().decode(LocalAgentFrame.self, from: bytes)
            guard frame.kind == .output, let data = frame.data else { throw RelayError.invalidMessage }
            try await observed.append(data)
            if await observed.contains("RELAY_SIZE:39 111") { break }
        }
        let observerRepainted = await observed.contains("RELAY_SIZE:39 111")
        XCTAssertTrue(observerRepainted, "Read-only terminal did not repaint at its authoritative dimensions")
        for request in [LocalAgentRequest(operation: .input, data: Data("DENIED".utf8)),
                        LocalAgentRequest(operation: .resize, columns: 91, rows: 31)] {
            stage = request.operation == .input ? "view wire input rejection" : "view wire resize rejection"
            let reply = try await response(to: request, from: observerChannel)
            XCTAssertEqual(reply.error, .readOnly)
        }
        await observerChannel.close()

        stage = "multiple encrypted observers follow rapid alternate-screen geometry"
        let firstGeometryView = try await readOnlyClient.attach(sessionID: created.id, mode: .view)
        let secondGeometryView = try await remote.attach(sessionID: created.id, mode: .view)
        let firstScreen = try TerminalGeometryScreen(directory: directory, configuration: configuration, columns: 111, rows: 39)
        let secondScreen = try TerminalGeometryScreen(directory: directory, configuration: configuration, columns: 111, rows: 39)
        defer { firstScreen.close(); secondScreen.close() }
        let firstGeometry = TerminalGeometryCapture(screen: firstScreen, initialSession: firstGeometryView.session)
        let secondGeometry = TerminalGeometryCapture(screen: secondScreen, initialSession: secondGeometryView.session)
        let firstGeometryReader = captureEvents(firstGeometryView, into: firstGeometry)
        let secondGeometryReader = captureEvents(secondGeometryView, into: secondGeometry)
        defer { firstGeometryReader.cancel(); secondGeometryReader.cancel() }
        try await control.send(geometryScreenInput())
        try await eventually("Encrypted observers did not render the initial alternate screen") {
            let first = try await firstGeometry.rendered("GRID_39_111_宽🙂", columns: 111, rows: 39)
            let second = try await secondGeometry.rendered("GRID_39_111_宽🙂", columns: 111, rows: 39)
            return first && second
        }
        for (columns, rows) in [(103, 37), (91, 29), (120, 40), (104, 32)] {
            try await control.resize(columns: columns, rows: rows)
        }
        try await eventually("Encrypted geometry/VT ordering did not produce the final Unicode screen") {
            let first = try await firstGeometry.rendered("GRID_32_104_宽🙂", columns: 104, rows: 32)
            let second = try await secondGeometry.rendered("GRID_32_104_宽🙂", columns: 104, rows: 32)
            return first && second
        }
        for captured in [firstGeometry, secondGeometry] {
            let changes = await captured.geometries()
            XCTAssertEqual(changes.map { "\($0.columns)x\($0.rows)" }, ["103x37", "91x29", "120x40", "104x32"])
            XCTAssertTrue(changes.allSatisfy { $0.id == created.id && $0.name == created.name && $0.createdAt == created.createdAt })
            let edge = try await captured.rendered("EDGE_32_104", columns: 104, rows: 32)
            XCTAssertTrue(edge, "Encrypted observer still rendered a cropped viewport")
        }
        do { try await firstGeometryView.resize(columns: 80, rows: 24); XCTFail("A live geometry viewer changed control dimensions") }
        catch RelayError.readOnly { }
        XCTAssertEqual(try panePID(sessionID: created.id, directory: directory, configuration: configuration), originalPID)
        try await control.send(Data([3]))
        try await control.send(Data("printf '\\033[?1049l'; printf 'GEOM_''EXIT\\n'\n".utf8))
        try await eventually("Alternate-screen test process did not return to the existing shell") { await initial.contains("GEOM_EXIT") }
        try await control.resize(columns: 111, rows: 39)
        try await firstGeometryView.detach(); try await secondGeometryView.detach()
        await firstGeometryReader.value; await secondGeometryReader.value
        firstScreen.close(); secondScreen.close()
        stage = "explicit disconnect"
        try await control.detach()

        // These are immediate ownership handoffs after the detach ACK. No
        // sleeps or sessionBusy retries may hide an ACK-before-release race.
        stage = "immediate second-client control handoff"
        let alternateRemote = RemoteTerminalClient(pairing: alternate, grantID: alternateGrant.id)
        let alternateControl = try await alternateRemote.attach(sessionID: created.id, columns: 111, rows: 39)
        let alternateOutput = RelayLiveCapture()
        let alternateReader = capture(alternateControl, into: alternateOutput)
        defer { alternateReader.cancel() }
        try await eventually("Explicit disconnect did not finish remote output", seconds: 3) { await initial.finished }

        stage = "original client downgraded to view"
        let downgraded = try await remote.attach(sessionID: created.id, columns: 111, rows: 39, mode: .view)
        let downgradedOutput = RelayLiveCapture()
        let downgradedReader = capture(downgraded, into: downgradedOutput)
        defer { downgradedReader.cancel() }
        do {
            try await downgraded.send(Data("WITERM_VIEW_GUARD=changed\n".utf8))
            XCTFail("A downgraded attachment sent input")
        } catch RelayError.readOnly { }
        do {
            try await downgraded.resize(columns: 91, rows: 31)
            XCTFail("A downgraded attachment resized the controller")
        } catch RelayError.readOnly { }
        // The original grant still permits control. A raw view attachment must
        // nevertheless stay read-only at the Mac/local broker boundary.
        let downgradedChannel = try await RelaySecureChannel.client(pairing: phone, grantID: controlGrant.id)
        let downgradedAttach = try await response(to: LocalAgentRequest(operation: .attach, sessionID: created.id,
            columns: 20, rows: 5, mode: .view), from: downgradedChannel)
        XCTAssertEqual(downgradedAttach.ok, true)
        XCTAssertEqual(downgradedAttach.session?.columns, 111)
        XCTAssertEqual(downgradedAttach.session?.rows, 39)
        for request in [LocalAgentRequest(operation: .input, data: Data("WITERM_VIEW_GUARD=changed\n".utf8)),
                        LocalAgentRequest(operation: .resize, columns: 91, rows: 31)] {
            let reply = try await response(to: request, from: downgradedChannel)
            XCTAssertEqual(reply.error, .readOnly)
        }
        try await alternateControl.send(Data("printf 'RELAY_''HANDOFF:%s:%s\\n' \"$WITERM_VIEW_GUARD\" \"$(stty size)\"\n".utf8))
        try await eventually("Second client did not control the same unchanged shell") {
            await alternateOutput.contains("RELAY_HANDOFF:untouched:39 111")
        }
        try await eventually("The original client's view did not remain attached") {
            await downgradedOutput.contains("RELAY_HANDOFF:untouched:39 111")
        }
        XCTAssertEqual(try panePID(sessionID: created.id, directory: directory, configuration: configuration), originalPID)

        stage = "immediate original-client reacquire"
        try await alternateControl.detach()
        let resumed = try await remote.attach(sessionID: created.id, columns: 111, rows: 39)
        stage = "reconnect repaint"
        let repaint = RelayLiveCapture()
        let repaintReader = capture(resumed, into: repaint)
        defer { repaintReader.cancel() }
        try await eventually("Reconnect did not repaint the existing terminal") { await repaint.contains("RELAY_SIZE:39 111") }
        XCTAssertEqual(try panePID(sessionID: created.id, directory: directory, configuration: configuration), originalPID)
        try await resumed.send(Data("printf 'RELAY_''PID:%s\\n' \"$$\"\n".utf8))
        try await eventually("Reconnect did not retain the same shell") { await repaint.contains("RELAY_PID:\(originalPID)") }
        do {
            try await downgraded.send(Data("WITERM_VIEW_GUARD=changed\n".utf8))
            XCTFail("An old view attachment inherited newly acquired control")
        } catch RelayError.readOnly { }
        try await downgraded.detach()
        await downgradedChannel.close()

        stage = "faultable control connection"
        try await resumed.detach()
        let (faultable, socket) = try await faultableAttachment(pairing: phone, grantID: controlGrant.id, sessionID: created.id)
        let faultOutput = RelayLiveCapture()
        let faultReader = capture(faultable, into: faultOutput)
        defer { faultReader.cancel() }
        try await faultable.send(Data("WITERM_REPLAY_COUNT=0; WITERM_REPLAY_COUNT=$((WITERM_REPLAY_COUNT+1)); printf 'RELAY_''ACKED_COUNT:%s\\n' \"$WITERM_REPLAY_COUNT\"\n".utf8))
        try await eventually("The acknowledged input did not execute exactly once") {
            await faultOutput.contains("RELAY_ACKED_COUNT:1")
        }
        stage = "endpoint write failure"
        socket.failNextApplicationWrite()
        do {
            try await faultable.send(Data("WITERM_REPLAY_COUNT=$((WITERM_REPLAY_COUNT+1))\n".utf8))
            XCTFail("The faulted endpoint acknowledged an unsent input")
        } catch RelayError.transport { }
        try await eventually("Endpoint failure did not finish remote output", seconds: 3) { await faultOutput.finished }

        stage = "manual reconnect after endpoint failure"
        // Transport loss has no detach ACK. Only host cleanup may be retried;
        // the failed input is never submitted again by the test/client.
        var afterFailure: RemoteTerminalAttachment?
        try await eventually("The failed endpoint did not release controller ownership", seconds: 3) {
            do {
                afterFailure = try await remote.attach(sessionID: created.id, columns: 111, rows: 39)
                return true
            } catch RelayError.sessionBusy { return false }
        }
        let recovered = try XCTUnwrap(afterFailure)
        let recoveredOutput = RelayLiveCapture()
        let recoveredReader = capture(recovered, into: recoveredOutput)
        defer { recoveredReader.cancel() }
        try await recovered.send(Data("printf 'RELAY_''RECOVERED:%s:%s\\n' \"$WITERM_REPLAY_COUNT\" \"$$\"\n".utf8))
        try await eventually("Manual reconnect changed shell or replayed failed input") {
            await recoveredOutput.contains("RELAY_RECOVERED:1:\(originalPID)")
        }
        XCTAssertEqual(try panePID(sessionID: created.id, directory: directory, configuration: configuration), originalPID)

        stage = "local ledger revocation"
        // Revoke only the host's local trust ledger. Server-side grant remains
        // active, so closure must come from fresh endpoint trust verification.
        try hostStore.tombstone(controlGrant, server: server)
        let serverGrants = try await phone.grants()
        XCTAssertTrue(serverGrants.contains(where: { $0.id == controlGrant.id }))
        try await eventually("Local trust revocation did not close an existing tunnel", seconds: 3) { await recoveredOutput.finished }
        do { _ = try await host.trustedRelayGrant(id: controlGrant.id); XCTFail("Local tombstone was ignored") }
        catch RelayError.revoked { }
        catch RelayError.untrusted { /* Its tombstoned grant was already removed by the periodic check. */ }
        let unaffected = try await readOnlyClient.sessions()
        XCTAssertEqual(unaffected.map(\.id), [created.id], "Unrelated grant must remain online after local revocation")
        do { _ = try await remote.sessions(); XCTFail("A new encrypted handshake bypassed local revocation") }
        catch { /* Host rejects the proof/tunnel without accepting a request. */ }
        XCTAssertEqual(try panePID(sessionID: created.id, directory: directory, configuration: configuration), originalPID)

        stage = "stop sharing disconnects paired devices"
        let watcher = try await readOnlyClient.attach(sessionID: created.id, mode: .view)
        let watched = RelayLiveCapture()
        let watchReader = capture(watcher, into: watched)
        defer { watchReader.cancel() }
        let unshared = try await local.share(sessionID: created.id, shared: false)
        XCTAssertEqual(unshared.sharing?.shared, false)
        try await eventually("Stopping sharing did not disconnect the paired device", seconds: 3) { await watched.finished }
        let afterUnshare = try await readOnlyClient.sessions()
        XCTAssertTrue(afterUnshare.isEmpty, "An unshared session stayed listed")
        XCTAssertEqual(try panePID(sessionID: created.id, directory: directory, configuration: configuration), originalPID,
                       "Stopping sharing changed the shell")
        await recovered.disconnect()
        await coordinator.stop()
        try await local.close(sessionID: created.id)
        let remaining = try await local.sessions()
        XCTAssertTrue(remaining.isEmpty)
        stage = "complete"
    }

    func testLiveOwnedSocketDelayStalledReadAndWakeHooks() async throws {
        guard let address = ProcessInfo.processInfo.environment["WITERM_RELAY_LIVE_SERVER_URL"] else {
            throw XCTSkip("Set WITERM_RELAY_LIVE_SERVER_URL to exercise owned relay endpoint faults")
        }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        var stage = "weak pairing"
        defer { print("Weak relay last stage: \(stage)") }
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        let host = try PairingClient(serverAddress: address, deviceName: "Weak Mac " + suffix, platform: .macos,
            store: RelayLiveMemorySecureStore(), transport: URLSessionPairingTransport())
        let phone = try PairingClient(serverAddress: address, deviceName: "Weak iOS " + suffix, platform: .ios,
            store: RelayLiveMemorySecureStore(), transport: URLSessionPairingTransport())
        let viewer = try PairingClient(serverAddress: address, deviceName: "Weak Viewer " + suffix, platform: .ios,
            store: RelayLiveMemorySecureStore(), transport: URLSessionPairingTransport())
        _ = try await host.register()
        let grant = try await pair(host: host, phone: phone, server: address, permission: .control)
        addTeardownBlock { try? await phone.revoke(grantID: grant.id) }
        let viewGrant = try await pair(host: host, phone: viewer, server: address, permission: .view)
        addTeardownBlock { try? await viewer.revoke(grantID: viewGrant.id) }
        let directory = URL(fileURLWithPath: "/private/tmp/witerm-relay-weak-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = try AgentConfiguration(stateDirectory: directory, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        let coordinator = RelayHostCoordinator(stateDirectory: directory, pairing: host)
        let local = LocalAgentClient(socketURL: directory.appendingPathComponent("agent.sock"))
        addTeardownBlock {
            await coordinator.stop()
            for session in (try? await local.sessions()) ?? [] { try? await local.close(sessionID: session.id) }
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", directory.appendingPathComponent("tmux.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        try broker.start()
        let session = try await local.create(name: "Weak endpoint " + suffix, shared: true)
        let originalPID = try panePID(sessionID: session.id, directory: directory, configuration: configuration)
        try RelayHostConfigurationStore(stateDirectory: directory).upsert(
            RelayHostConfiguration(serverAddress: address, deviceName: "Weak Mac " + suffix, enabled: true))
        await coordinator.start()
        let remote = RemoteTerminalClient(pairing: phone, grantID: grant.id)
        try await eventually("Weak test host did not come online", seconds: 15) {
            do { _ = try await remote.sessions(); return true } catch RelayError.offline { return false }
        }
        stage = "100-300ms owned message delay and jitter"
        let (delayed, socket) = try await faultableAttachment(pairing: phone, grantID: grant.id, sessionID: session.id, jitter: true)
        let delayedOutput = RelayLiveCapture()
        let delayedReader = capture(delayed, into: delayedOutput)
        defer { delayedReader.cancel() }
        try await delayed.send(Data("WITERM_WEAK_COUNT=0; printf 'WEAK_''READY\\n'\n".utf8))
        try await eventually("Jittered real terminal input did not execute") { await delayedOutput.contains("WEAK_READY") }
        try await delayed.resize(columns: 73, rows: 21)
        try await delayed.send(Data("printf 'WEAK_''SIZE:%s\\n' \"$(stty size)\"\n".utf8))
        try await eventually("Jittered resize did not reach the real pane") { await delayedOutput.contains("WEAK_SIZE:21 73") }
        let (delayCount, minimumDelay, maximumDelay) = socket.delayRange()
        XCTAssertGreaterThanOrEqual(delayCount, 8)
        XCTAssertEqual(minimumDelay, 100)
        XCTAssertEqual(maximumDelay, 300)

        stage = "independent observer confirms executed input while ACK read stalls"
        let observer = try await RemoteTerminalClient(pairing: viewer, grantID: viewGrant.id)
            .attach(sessionID: session.id, mode: .view)
        let observed = RelayLiveCapture()
        let observerReader = capture(observer, into: observed)
        defer { observerReader.cancel() }
        socket.stallNextApplicationRead()
        let unknownResult = Task {
            try await delayed.send(Data("WITERM_WEAK_COUNT=$((WITERM_WEAK_COUNT+1)); printf 'WEAK_''EXECUTED:%s\\n' \"$WITERM_WEAK_COUNT\"\n".utf8))
        }
        // A separate authenticated view connection sees the real command's
        // effect. The controller's wrapper is withholding its next record for
        // 6.5s, beyond the 5s RPC deadline; no server or OS network is stopped.
        try await eventually("The real host did not execute the stalled-ACK input") { await observed.contains("WEAK_EXECUTED:1") }
        do { try await unknownResult.value; XCTFail("A read stall beyond the RPC deadline returned success") }
        catch RelayError.transport { }
        try await eventually("Stalled endpoint did not close its output", seconds: 3) { await delayedOutput.finished }
        try await observer.detach()

        stage = "manual reconnect retains unknown-result count exactly once"
        let recovered = try await remote.attach(sessionID: session.id, columns: 73, rows: 21)
        let recoveredOutput = RelayLiveCapture()
        let recoveredReader = capture(recovered, into: recoveredOutput)
        defer { recoveredReader.cancel() }
        try await recovered.send(Data("printf 'WEAK_''RECOVERED:%s:%s\\n' \"$WITERM_WEAK_COUNT\" \"$$\"\n".utf8))
        try await eventually("Reconnect replayed unknown-result input or replaced the shell") {
            await recoveredOutput.contains("WEAK_RECOVERED:1:\(originalPID)")
        }

        stage = "sleep notification branch rehearsal"
        await coordinator.prepareForSleep()
        try await eventually("Sleep hook did not close existing remote attachment", seconds: 3) { await recoveredOutput.finished }
        XCTAssertEqual(try panePID(sessionID: session.id, directory: directory, configuration: configuration), originalPID)
        let preserved = try await local.sessions()
        XCTAssertEqual(preserved.map(\.id), [session.id])
        try await eventually("Sleep hook allowed a new tunnel", seconds: 3) {
            do { _ = try await remote.sessions(); return false } catch RelayError.offline { return true }
        }
        await coordinator.resumeAfterWake()
        try await eventually("Wake hook did not reauthenticate the host", seconds: 15) {
            do { _ = try await remote.sessions(); return true } catch RelayError.offline { return false }
        }
        let awake = try await remote.attach(sessionID: session.id, columns: 73, rows: 21)
        let awakeOutput = RelayLiveCapture()
        let awakeReader = capture(awake, into: awakeOutput)
        defer { awakeReader.cancel() }
        try await awake.send(Data("printf 'WEAK_''AWAKE:%s:%s\\n' \"$WITERM_WEAK_COUNT\" \"$$\"\n".utf8))
        try await eventually("Wake re-handshake lost the shell or repeated unknown input") {
            await awakeOutput.contains("WEAK_AWAKE:1:\(originalPID)")
        }
        XCTAssertEqual(try panePID(sessionID: session.id, directory: directory, configuration: configuration), originalPID)
        try await awake.detach()
        await coordinator.stop()
        try await local.close(sessionID: session.id)
        stage = "complete (hook rehearsal only; not physical OS sleep)"
    }
}
