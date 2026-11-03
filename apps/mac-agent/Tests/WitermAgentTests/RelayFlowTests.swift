import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import WitermCore
@testable import WitermAgent

// MARK: - A modeled relay

/// One leg of a tunnel as `server/internal/relay/relay.go` routes it: the
/// server reads a message from one endpoint and puts it in the other leg's
/// queue, which holds 16 messages in its channel plus the one being written,
/// and 256 KiB counting that one. A message that doesn't fit closes the whole
/// tunnel; nothing is dropped. A write that can't finish in 5 seconds (the
/// endpoint's buffers are full) also closes it. Heartbeats aren't modeled:
/// they are why the server can't just stop reading a fast sender.
struct RelayLegModel: Sendable {
    var messages = 16
    var bytes = 256 * 1024
    var message = 65_536
    var writeTimeout: Duration = .seconds(5)
    /// Bytes per second from the server to this endpoint; nil is unlimited.
    var bandwidth: Double?
    /// One-way delay, pipelined.
    var latency: Duration = .zero
    /// What the endpoint's TCP and WebSocket buffers take before the
    /// server's write blocks.
    var buffer = 256 * 1024
}

enum ModeledClose: String, Sendable { case overflow, writeTimeout = "write-timeout", endpoint }

actor ModeledLeg {
    struct Stats: Sendable {
        var messages = 0
        var bytes = 0
        var peakQueued = 0
        var peakBytes = 0
        var largest = 0
    }

    let model: RelayLegModel
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var buffer: [(data: Data, arrival: ContinuousClock.Instant)] = []
    private var bufferBytes = 0
    private var closed = false
    private var receiver: CheckedContinuation<Void, Never>?
    private var writerWake: CheckedContinuation<Void, Never>?
    private(set) var stats = Stats()

    init(_ model: RelayLegModel) { self.model = model }

    /// The server read `data` for this leg; false means it overflowed.
    func put(_ data: Data) -> Bool {
        guard !closed, data.count <= model.message, queue.count < model.messages,
              queuedBytes + data.count <= model.bytes else { return false }
        queue.append(data)
        queuedBytes += data.count
        stats.messages += 1
        stats.bytes += data.count
        stats.peakQueued = max(stats.peakQueued, queue.count)
        stats.peakBytes = max(stats.peakBytes, queuedBytes)
        stats.largest = max(stats.largest, data.count)
        let waiter = writerWake; writerWake = nil; waiter?.resume()
        return true
    }

    /// The server's writer for this leg.
    func run(failed: @Sendable (ModeledClose) -> Void) async {
        while !closed {
            guard !queue.isEmpty else {
                await withCheckedContinuation { writerWake = $0 }
                continue
            }
            // Taken from the channel; its bytes stay counted until written.
            let data = queue.removeFirst()
            if let bandwidth = model.bandwidth { try? await Task.sleep(for: .seconds(Double(data.count) / bandwidth)) }
            let deadline = ContinuousClock.now + model.writeTimeout
            while !closed, bufferBytes + data.count > model.buffer {
                guard ContinuousClock.now < deadline else { failed(.writeTimeout); return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard !closed else { return }
            queuedBytes -= data.count
            buffer.append((data, .now + model.latency))
            bufferBytes += data.count
            let waiter = receiver; receiver = nil; waiter?.resume()
        }
    }

    func receive() async throws -> Data {
        while true {
            guard !closed else { throw RelayError.transport }
            if let first = buffer.first {
                if first.arrival > .now {
                    try? await Task.sleep(until: first.arrival, clock: .continuous)
                    continue
                }
                buffer.removeFirst()
                bufferBytes -= first.data.count
                return first.data
            }
            await withCheckedContinuation { receiver = $0 }
        }
    }

    func close() {
        closed = true
        let r = receiver, w = writerWake
        receiver = nil; writerWake = nil
        r?.resume(); w?.resume()
    }
}

final class ModeledTunnel: @unchecked Sendable {
    let toHost: ModeledLeg
    let toClient: ModeledLeg
    private let lock = NSLock()
    private var reason: ModeledClose?

    init(toHost: RelayLegModel = .init(), toClient: RelayLegModel = .init()) {
        self.toHost = ModeledLeg(toHost)
        self.toClient = ModeledLeg(toClient)
        startWriters()
    }

    private func startWriters() {
        let failed: @Sendable (ModeledClose) -> Void = { [weak self] reason in self?.close(reason) }
        for leg in [toHost, toClient] { Task { await leg.run(failed: failed) } }
    }

    var closeReason: ModeledClose? { lock.withLock { reason } }

    func close(_ why: ModeledClose) {
        let first = lock.withLock { () -> Bool in
            guard reason == nil else { return false }
            reason = why
            return true
        }
        guard first else { return }
        let legs = [toHost, toClient]
        Task { for leg in legs { await leg.close() } }
    }

    var hostSocket: ModeledSocket { ModeledSocket(inbound: toHost, outbound: toClient, tunnel: self) }
    var clientSocket: ModeledSocket { ModeledSocket(inbound: toClient, outbound: toHost, tunnel: self) }
}

final class ModeledSocket: RelaySocketIO, Sendable {
    let inbound: ModeledLeg
    let outbound: ModeledLeg
    let tunnel: ModeledTunnel
    init(inbound: ModeledLeg, outbound: ModeledLeg, tunnel: ModeledTunnel) {
        self.inbound = inbound; self.outbound = outbound; self.tunnel = tunnel
    }
    func send(_ data: Data) async throws {
        guard data.count <= 65_536 else { tunnel.close(.endpoint); throw RelayError.invalidMessage }
        let tunnel = tunnel
        try await withTaskCancellationHandler {
            guard await outbound.put(data) else {
                tunnel.close(.overflow)
                throw RelayError.transport
            }
        } onCancel: { tunnel.close(.endpoint) }
    }
    func receive() async throws -> Data {
        let tunnel = tunnel
        return try await withTaskCancellationHandler {
            try await inbound.receive()
        } onCancel: { tunnel.close(.endpoint) }
    }
    func close() { tunnel.close(.endpoint) }
}

// MARK: - Offline paired identities (test only, never the Keychain)

private final class FlowTestStore: PairingSecureStore, @unchecked Sendable {
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
}

private struct FlowTestOffline: PairingTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw RelayError.transport }
}

struct FlowTestPeers: Sendable {
    let server = URL(string: "https://relay.example")!
    let grant: DeviceGrant
    let host: PairingClient
    let client: PairingClient
    let hostCredentials: RelayCredentials
    let clientCredentials: RelayCredentials
    let tunnelID = "33333333-3333-4333-8333-333333333333"

    init() throws {
        let hostKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let clientKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let hostDevice = PairedDevice(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "Flow Mac", platform: .macos,
                                      publicKey: hostKey.publicKey.rawRepresentation.base64EncodedString())
        let clientDevice = PairedDevice(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", name: "Flow Phone", platform: .ios,
                                        publicKey: clientKey.publicKey.rawRepresentation.base64EncodedString())
        let pairingID = "11111111-1111-4111-8111-111111111111"
        let message = PairingEncoding.approvalMessage(pairingID: pairingID, hostKey: hostDevice.publicKey,
                                                      clientKey: clientDevice.publicKey, permission: .control)
        grant = DeviceGrant(id: "22222222-2222-4222-8222-222222222222", pairingID: pairingID, host: hostDevice,
                            client: clientDevice, permission: .control,
                            approvalSignature: try hostKey.signature(for: message).base64EncodedString(),
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let hostStore = FlowTestStore()
        let clientStore = FlowTestStore()
        let account = PairingIdentity.account(server: server.absoluteString)
        try hostStore.write(hostKey.rawRepresentation, account: account)
        try clientStore.write(clientKey.rawRepresentation, account: account)
        let ledger = PairingTrustLedger(pinnedHosts: [pairingID: hostDevice.publicKey], grants: [grant.id: grant])
        for (store, key) in [(hostStore, hostDevice.publicKey), (clientStore, clientDevice.publicKey)] {
            try store.write(RemoteWire.encoder().encode(ledger),
                            account: PairingTrustLedger.account(server: server.absoluteString, publicKey: key))
        }
        host = try PairingClient(serverAddress: server.absoluteString, deviceName: "Flow Mac", platform: .macos,
                                 store: hostStore, transport: FlowTestOffline())
        client = try PairingClient(serverAddress: server.absoluteString, deviceName: "Flow Phone", platform: .ios,
                                   store: clientStore, transport: FlowTestOffline())
        let token = Data(repeating: 9, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        hostCredentials = RelayCredentials(server: server, device: hostDevice, accessToken: token,
                                           expiresAt: Date().addingTimeInterval(3600))
        clientCredentials = RelayCredentials(server: server, device: clientDevice, accessToken: token,
                                             expiresAt: Date().addingTimeInterval(3600))
    }

    func channels(over tunnel: ModeledTunnel) async throws -> (client: RelaySecureChannel, host: RelaySecureChannel) {
        async let client = RelaySecureChannel.establish(pairing: self.client, credentials: clientCredentials, grant: grant,
                                                        tunnelID: tunnelID, role: .client, socket: tunnel.clientSocket)
        async let host = RelaySecureChannel.establish(pairing: self.host, credentials: hostCredentials, grant: grant,
                                                      tunnelID: tunnelID, role: .host, socket: tunnel.hostSocket)
        return try await (client, host)
    }
}

// MARK: - Measuring

/// Output bytes in order, hashed, and where geometry fell among them. Only
/// counts and digests leave it; terminal bytes are never printed.
final class FlowTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var digest = SHA256()
    private var bytes = 0
    private var geometry: [Int] = []
    private var tail = Data()

    func record(_ event: LocalTerminalEvent) {
        lock.withLock {
            switch event {
            case .output(let data):
                digest.update(data: data)
                bytes += data.count
                tail.append(data)
                if tail.count > 8192 { tail = tail.suffix(4096) }
            case .geometry: geometry.append(bytes)
            }
        }
    }
    var count: Int { lock.withLock { bytes } }
    var geometryOffsets: [Int] { lock.withLock { geometry } }
    var hash: String { lock.withLock { digest.finalize().map { String(format: "%02x", $0) }.joined() } }
    func contains(_ marker: String) -> Bool { lock.withLock { tail.range(of: Data(marker.utf8)) != nil } }
}

/// Process memory now, in bytes (the test process also hosts the service).
func flowFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

final class FlowPeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var task: Task<Void, Never>?
    let baseline = flowFootprint()
    func start() {
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let now = flowFootprint()
                self?.lock.withLock { self?.peak = max(self?.peak ?? 0, now) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    func stop() -> UInt64 {
        task?.cancel()
        return lock.withLock { peak > baseline ? peak - baseline : 0 }
    }
}

/// Bridges and tunnels opened for the phone, in order.
final class FlowHost: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var tunnels: [ModeledTunnel] = []
    private(set) var bridges: [RelayTerminalBridge] = []
    let peers: FlowTestPeers
    let local: LocalAgentClient
    let toHost: RelayLegModel
    let toClient: RelayLegModel
    let limits: RelayOutputWindow.Limits
    let observed = FlowTranscript()

    init(peers: FlowTestPeers, local: LocalAgentClient, toHost: RelayLegModel = .init(latency: .milliseconds(20)),
         toClient: RelayLegModel, limits: RelayOutputWindow.Limits = .init()) {
        self.peers = peers; self.local = local; self.toHost = toHost; self.toClient = toClient; self.limits = limits
    }

    /// A fresh tunnel and Mac bridge for each phone connection, as the server and
    /// `RelayHostCoordinator` do.
    var open: @Sendable () async throws -> RelaySecureChannel {
        { [self] in
            let tunnel = ModeledTunnel(toHost: toHost, toClient: toClient)
            let (client, host) = try await peers.channels(over: tunnel)
            let observed = observed
            let bridge = RelayTerminalBridge(channel: host, pairing: peers.host, local: local, traceID: "flow",
                                             flowLimits: limits, flowObserver: { observed.record($0) })
            lock.withLock { tunnels.append(tunnel); bridges.append(bridge) }
            Task { await bridge.run() }
            return client
        }
    }
    var lastTunnel: ModeledTunnel? { lock.withLock { tunnels.last } }
    var lastBridge: RelayTerminalBridge? { lock.withLock { bridges.last } }
    var tunnelCount: Int { lock.withLock { tunnels.count } }
}

/// An isolated service with its own tmux server and state directory.
struct FlowService {
    let directory: URL
    let configuration: AgentConfiguration
    let broker: AgentBroker
    let local: LocalAgentClient

    static func start(_ test: XCTestCase) throws -> FlowService {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") else { throw XCTSkip("tmux is required") }
        let url = URL(fileURLWithPath: "/private/tmp/witerm-flow-test-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        let service = FlowService(directory: url, configuration: configuration, broker: broker,
                                  local: LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock")))
        test.addTeardownBlock {
            broker.stop()
            _ = try? CommandRunner(executable: "/opt/homebrew/bin/tmux", environment: configuration.environment)
                .run(["-S", url.appendingPathComponent("tmux.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: url)
        }
        return service
    }
}

// MARK: - Tests

final class RelayFlowTests: XCTestCase {
    /// About 2 MB/s from the relay to the phone, 20 ms each way.
    private let slowPhoneLink = RelayLegModel(bandwidth: 2_000_000, latency: .milliseconds(20))

    private func eventually(_ seconds: Double, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// A renderer that takes `rate` bytes per second, as a phone's terminal
    /// view is slower than the Mac producing output.
    private func render(_ attachment: RemoteTerminalAttachment, into transcript: FlowTranscript, rate: Double)
        -> Task<Error?, Never> {
        Task.detached {
            do {
                for try await event in attachment.events {
                    transcript.record(event)
                    if case .output(let data) = event, rate.isFinite {
                        try await Task.sleep(for: .microseconds(Int(Double(data.count) / rate * 1_000_000)))
                    }
                }
                return nil
            } catch { return error }
        }
    }

    private struct BurstResult {
        let seconds: Double
        let marker: Bool
        let ended: Error?
        let tunnelClose: ModeledClose?
        let tunnels: Int
        let memory: UInt64
        let window: RelayOutputWindow.Stats?
        let phoneLeg: ModeledLeg.Stats
        let observed: Int
        let rendered: Int
        let identical: Bool
        let geometryIdentical: Bool
        let after: Bool
        let detached: Bool
    }

    /// Runs `lines` of `seq` in a real tmux session while the phone renders
    /// through the modeled relay.
    private func burst(lines: Int, flow: Bool, timeout: Double) async throws -> BurstResult {
        let service = try FlowService.start(self)
        let peers = try FlowTestPeers()
        let session = try await service.local.create(name: "Flow burst", columns: 80, rows: 24, shared: true)
        let host = FlowHost(peers: peers, local: service.local, toClient: slowPhoneLink)
        let attachment = try await RemoteTerminalClient.attach(
            open: host.open, flowKey: UUID().uuidString, sessionID: session.id, columns: 80, rows: 24,
            mode: .control, history: true, advertiseFlow: flow)
        let flowControlled = await attachment.flowControlled
        XCTAssertEqual(flowControlled, flow)
        let rendered = FlowTranscript()
        let reader = render(attachment, into: rendered, rate: 1_500_000)
        let sampler = FlowPeakSampler()
        sampler.start()
        try await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        // The marker is computed, so the typed command never contains it.
        // Without flow control the attach's own redraw (many small
        // messages) can already overflow the slow phone's leg.
        do { try await attachment.send(Data("seq -f '%.0f' 1 \(lines); echo FLOW_DONE_$((6*7))\n".utf8)) }
        catch where !flow {}
        let marker = try await eventually(timeout) {
            if rendered.contains("FLOW_DONE_42") { return true }
            return host.lastTunnel?.closeReason != nil
        } && rendered.contains("FLOW_DONE_42")
        let elapsed = started.duration(to: .now)
        var after = false
        var identical = false
        var geometryIdentical = false
        var detached = false
        if marker {
            // Still attached: typing after the burst reaches the shell and back.
            try await attachment.send(Data("echo FLOW_AFTER_$((6*7))\n".utf8))
            after = try await eventually(20) { rendered.contains("FLOW_AFTER_42") }
            // Once quiet, everything the Mac took from the service reached the renderer, in order.
            identical = try await eventually(20) {
                host.observed.count > 0 && host.observed.count == rendered.count && host.observed.hash == rendered.hash
            }
            geometryIdentical = host.observed.geometryOffsets == rendered.geometryOffsets
        }
        // Read before the detach below, which closes the tunnel as it should.
        let close = host.lastTunnel?.closeReason
        if marker { do { try await attachment.detach(); detached = true } catch {} }
        let memory = sampler.stop()
        let window = await host.lastBridge?.window?.stats
        let phoneLeg = await host.lastTunnel!.toClient.stats
        await attachment.abort()
        let ended = await reader.value
        try? await service.local.close(sessionID: session.id)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return BurstResult(seconds: seconds, marker: marker, ended: ended, tunnelClose: close, tunnels: host.tunnelCount,
                           memory: memory, window: window, phoneLeg: phoneLeg, observed: host.observed.count,
                           rendered: rendered.count, identical: identical, geometryIdentical: geometryIdentical,
                           after: after, detached: detached)
    }

    private func report(_ name: String, _ result: BurstResult) {
        let window = result.window.map {
            "frames=\($0.sentFrames) acked=\($0.acknowledgedFrames) peakRecords=\($0.peakRecords) peakBytes=\($0.peakBytes) peakPending=\($0.peakPending) largestRecord=\($0.largestRecord)"
        } ?? "none"
        print("RELAY-FLOW \(name): seconds=\(String(format: "%.2f", result.seconds)) marker=\(result.marker) "
              + "close=\(result.tunnelClose?.rawValue ?? "none") tunnels=\(result.tunnels) "
              + "phoneLeg(messages=\(result.phoneLeg.messages) peakQueued=\(result.phoneLeg.peakQueued) peakBytes=\(result.phoneLeg.peakBytes) largest=\(result.phoneLeg.largest)) "
              + "window(\(window)) observed=\(result.observed) rendered=\(result.rendered) identical=\(result.identical) "
              + "memoryGrowth=\(result.memory / 1024)KiB")
    }

    private func assertKept(_ result: BurstResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.marker, "The burst didn't finish on the phone", file: file, line: line)
        XCTAssertNil(result.tunnelClose, "The relay closed the tunnel", file: file, line: line)
        XCTAssertEqual(result.tunnels, 1, "The phone needed another tunnel", file: file, line: line)
        XCTAssertTrue(result.after, "Typing after the burst didn't come back", file: file, line: line)
        XCTAssertTrue(result.identical, "What the phone rendered isn't what the Mac took from the service", file: file, line: line)
        XCTAssertTrue(result.geometryIdentical, "Geometry moved among the output", file: file, line: line)
        XCTAssertTrue(result.detached, "The detach wasn't acknowledged", file: file, line: line)
        let window = result.window
        XCTAssertNotNil(window)
        XCTAssertLessThanOrEqual(window?.peakRecords ?? .max, RelayFlowControl.windowRecords, file: file, line: line)
        XCTAssertLessThanOrEqual(window?.peakBytes ?? .max, RelayFlowControl.windowBytes, file: file, line: line)
        XCTAssertLessThanOrEqual(window?.largestRecord ?? .max, 49_152 + 16, file: file, line: line)
        // Output plus replies stay well inside the relay's queue.
        XCTAssertLessThanOrEqual(result.phoneLeg.peakQueued, 12, file: file, line: line)
        XCTAssertLessThanOrEqual(result.phoneLeg.peakBytes, 160 * 1024, file: file, line: line)
        XCTAssertLessThan(result.memory, 192 << 20, "Memory grew without bound", file: file, line: line)
    }

    /// The reported failure: an attachment that doesn't acknowledge (an
    /// older phone, or the code before flow control) sends as fast as the
    /// relay reads, so a slower phone's leg passes 16 messages or 256 KiB and
    /// the relay closes the tunnel mid-burst.
    func testWithoutFlowControlASlowPhoneOverflowsTheRelay() async throws {
        let result = try await burst(lines: 100_000, flow: false, timeout: 60)
        report("legacy-100k", result)
        XCTAssertFalse(result.marker, "A slow phone kept up without flow control")
        XCTAssertNotNil(result.tunnelClose)
        XCTAssertNil(result.window)
        XCTAssertNotNil(result.ended, "The phone's attachment should have ended")
    }

    func testFlowControlKeepsTheTunnelThrough100000Lines() async throws {
        let result = try await burst(lines: 100_000, flow: true, timeout: 120)
        report("flow-100k", result)
        assertKept(result)
    }

    func testFlowControlKeepsTheTunnelThrough1000000Lines() async throws {
        let result = try await burst(lines: 1_000_000, flow: true, timeout: 240)
        report("flow-1m", result)
        assertKept(result)
    }

    /// An older phone (no `flow` in its attach) gets exactly today's
    /// attachment: no confirmation, no window, 8 KiB output frames.
    func testOlderPhoneGetsTheAttachmentAsBefore() async throws {
        let service = try FlowService.start(self)
        let peers = try FlowTestPeers()
        let session = try await service.local.create(name: "Older phone", columns: 80, rows: 24, shared: true)
        let host = FlowHost(peers: peers, local: service.local, toClient: RelayLegModel())
        let attachment = try await RemoteTerminalClient.attach(
            open: host.open, flowKey: UUID().uuidString, sessionID: session.id, columns: 80, rows: 24,
            mode: .control, history: false, advertiseFlow: false)
        let flowControlled = await attachment.flowControlled
        XCTAssertFalse(flowControlled)
        let rendered = FlowTranscript()
        let reader = render(attachment, into: rendered, rate: .infinity)
        try await Task.sleep(for: .milliseconds(300))
        try await attachment.send(Data("seq 1 2000; echo OLDER_$((6*7))\n".utf8))
        let seen = try await eventually(30) { rendered.contains("OLDER_42") }
        XCTAssertTrue(seen)
        let window = await host.lastBridge?.window
        XCTAssertNil(window, "No window without flow control")
        XCTAssertNil(host.lastTunnel?.closeReason)
        // Legacy frames carry at most 8 KiB: about 22 KB once Base64'd with
        // escaped slashes and encrypted.
        let legacyLargest = await host.lastTunnel!.toClient.stats.largest
        XCTAssertLessThanOrEqual(legacyLargest, 8192 * 8 / 3 + 256)
        try await attachment.detach()
        _ = await reader.value
        try? await service.local.close(sessionID: session.id)
    }

    // MARK: Raw records, as a device that bypasses the SDK

    private func rawFrame(_ channel: RelaySecureChannel, until id: String? = nil,
                          skipping: Set<LocalFrameKind> = [.output, .geometry]) async throws -> LocalAgentFrame {
        for _ in 0..<4096 {
            let bytes = try await relayDeadline(10) { try await channel.receive() }
            let frame = try RemoteWire.decoder().decode(LocalAgentFrame.self, from: bytes)
            if let id, frame.id == id { return frame }
            if id == nil, !skipping.contains(frame.kind) { return frame }
            guard skipping.contains(frame.kind) else { throw RelayError.invalidMessage }
        }
        throw RelayError.backpressure
    }

    private func rawAttach(_ host: FlowHost, session: String, flow: Bool) async throws -> RelaySecureChannel {
        let channel = try await host.open()
        let attach = LocalAgentRequest(operation: .attach, sessionID: session, columns: 80, rows: 24, mode: .control,
                                       flow: flow ? 1 : nil)
        try await channel.send(RemoteWire.encoder().encode(attach))
        let reply = try await rawFrame(channel, until: attach.id)
        XCTAssertEqual(reply.ok, true)
        XCTAssertEqual(reply.flow, flow ? 1 : nil)
        return channel
    }

    /// Without flow control an acknowledgement is just an invalid request,
    /// as on an older Mac; with it, one that claims more than was sent ends
    /// the attachment.
    func testAcknowledgementsNeedFlowControlAndMustBeTrue() async throws {
        let service = try FlowService.start(self)
        let peers = try FlowTestPeers()
        let session = try await service.local.create(name: "Raw acks", columns: 80, rows: 24, shared: true)
        let host = FlowHost(peers: peers, local: service.local, toClient: RelayLegModel())

        let legacy = try await rawAttach(host, session: session.id, flow: false)
        let ack = LocalAgentRequest(operation: .ack, consumed: 1)
        try await legacy.send(RemoteWire.encoder().encode(ack))
        let refused = try await rawFrame(legacy, until: ack.id)
        XCTAssertEqual(refused.ok, false)
        XCTAssertEqual(refused.error, .invalidRequest)
        await legacy.close()

        let flowing = try await rawAttach(host, session: session.id, flow: true)
        let lie = LocalAgentRequest(operation: .ack, consumed: 1_000_000)
        try await flowing.send(RemoteWire.encoder().encode(lie))
        let ended = try await eventually(10) {
            do { _ = try await relayDeadline(1) { try await flowing.receive() }; return false } catch { return true }
        }
        XCTAssertTrue(ended, "An impossible acknowledgement must end the attachment")
        try? await service.local.close(sessionID: session.id)
    }

    /// A device that stops acknowledging while output waits is told
    /// `backpressure` after the stall limit (45 s; 1 s here), and the session
    /// keeps running.
    func testADeviceThatStopsAcknowledgingGetsBackpressure() async throws {
        let service = try FlowService.start(self)
        let peers = try FlowTestPeers()
        let session = try await service.local.create(name: "Stalled", columns: 80, rows: 24, shared: true)
        var limits = RelayOutputWindow.Limits()
        limits.stall = .seconds(1)
        let host = FlowHost(peers: peers, local: service.local, toClient: RelayLegModel(), limits: limits)
        let channel = try await rawAttach(host, session: session.id, flow: true)
        let input = LocalAgentRequest(operation: .input, data: Data("seq 1 200000\n".utf8))
        try await channel.send(RemoteWire.encoder().encode(input))
        let started = ContinuousClock.now
        // Read everything, acknowledge nothing.
        let closed = try await rawFrame(channel, skipping: [.output, .geometry, .response])
        XCTAssertEqual(closed.kind, .closed)
        XCTAssertEqual(closed.error, .backpressure)
        XCTAssertLessThan(started.duration(to: .now), .seconds(15))
        let stats = await host.lastBridge?.window?.stats
        XCTAssertEqual(stats?.acknowledgedFrames, 0)
        XCTAssertLessThanOrEqual(stats?.peakRecords ?? .max, RelayFlowControl.windowRecords)
        XCTAssertNil(host.lastTunnel?.closeReason, "The relay itself never overflowed")
        let listed = try await service.local.sessions()
        XCTAssertTrue(listed.contains { $0.id == session.id }, "The session must keep running")
        await channel.close()
        try? await service.local.close(sessionID: session.id)
    }

    // MARK: Exact bytes without tmux

    /// `seq 1 1000000` exactly (6.9 MB), with geometry every 100,000 lines,
    /// through the window, the encrypted channel and the modeled relay to a
    /// slow renderer: every byte arrives once, in order, with geometry in its
    /// place. The same events sent the way the bridge did before flow
    /// control overflow the relay.
    func testAMillionLinesArriveExactlyThroughTheWindow() async throws {
        let result = try await synthetic(flow: true)
        print("RELAY-FLOW synthetic-1m: seconds=\(String(format: "%.2f", result.seconds)) bytes=\(result.bytes) "
              + "close=\(result.close?.rawValue ?? "none") peakQueued=\(result.leg.peakQueued) peakBytes=\(result.leg.peakBytes) "
              + "messages=\(result.leg.messages) window(peakRecords=\(result.window?.peakRecords ?? -1) peakBytes=\(result.window?.peakBytes ?? -1) frames=\(result.window?.sentFrames ?? -1)) "
              + "memoryGrowth=\(result.memory / 1024)KiB")
        XCTAssertNil(result.close)
        XCTAssertTrue(result.identical, "Bytes were lost, duplicated or reordered")
        XCTAssertEqual(result.geometry, result.expectedGeometry, "Geometry moved among the output")
        XCTAssertLessThanOrEqual(result.window?.peakRecords ?? .max, RelayFlowControl.windowRecords)
        XCTAssertLessThanOrEqual(result.window?.peakBytes ?? .max, RelayFlowControl.windowBytes)
        XCTAssertLessThanOrEqual(result.leg.peakQueued, 9)
        XCTAssertLessThan(result.memory, 192 << 20)
    }

    func testAMillionLinesOverflowTheRelayWithoutTheWindow() async throws {
        let result = try await synthetic(flow: false)
        print("RELAY-FLOW synthetic-legacy: close=\(result.close?.rawValue ?? "none") rendered=\(result.bytes) of \(result.expected)")
        XCTAssertEqual(result.close, .overflow)
        XCTAssertLessThan(result.bytes, result.expected)
    }

    private struct SyntheticResult {
        let seconds: Double
        let bytes: Int
        let expected: Int
        let identical: Bool
        let geometry: [Int]
        let expectedGeometry: [Int]
        let close: ModeledClose?
        let leg: ModeledLeg.Stats
        let window: RelayOutputWindow.Stats?
        let memory: UInt64
    }

    private func synthetic(flow: Bool) async throws -> SyntheticResult {
        let peers = try FlowTestPeers()
        let tunnel = ModeledTunnel(toHost: RelayLegModel(latency: .milliseconds(20)), toClient: slowPhoneLink)
        let (client, host) = try await peers.channels(over: tunnel)
        let session = LocalSessionInfo(id: "77777777-7777-4777-8777-777777777777", name: "Synthetic",
                                       createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)
        // The events the local service would deliver: 8 KiB chunks of seq.
        let expected = FlowTranscript()
        var events: [LocalTerminalEvent] = []
        var chunk = Data()
        for line in 1...1_000_000 {
            chunk.append(contentsOf: "\(line)\n".utf8)
            if chunk.count >= 8000 { events.append(.output(chunk)); chunk = Data() }
            if line.isMultiple(of: 100_000) {
                if !chunk.isEmpty { events.append(.output(chunk)); chunk = Data() }
                let columns = line.isMultiple(of: 200_000) ? 100 : 80
                events.append(.geometry(LocalSessionInfo(id: session.id, name: session.name, createdAt: session.createdAt,
                                                         columns: columns, rows: 24)))
            }
        }
        events.forEach(expected.record)
        let stream = AsyncThrowingStream<LocalTerminalEvent, Error> { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        let window = RelayOutputWindow()
        let rpc = RemoteRPCConnection(channel: client)
        await rpc.start()
        let mac = Task {
            let attach = try RemoteWire.decoder().decode(LocalAgentRequest.self, from: await host.receive())
            try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(
                id: attach.id, kind: .response, ok: true, session: session, mode: .view, flow: flow ? 1 : nil)))
            if flow {
                // The bridge's request reader: acknowledgements until the phone closes.
                Task {
                    while true {
                        let request = try RemoteWire.decoder().decode(LocalAgentRequest.self, from: await host.receive())
                        guard request.operation == .ack, let consumed = request.consumed else { throw RelayError.invalidMessage }
                        try await window.acknowledge(consumed)
                    }
                }
                try await window.run(stream) { try await host.send($0) }
            } else {
                // The bridge before flow control: each event as soon as the relay takes it.
                for try await event in stream {
                    switch event {
                    case .output(let data): try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(kind: .output, data: data)))
                    case .geometry(let info): try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(kind: .geometry, session: info)))
                    }
                }
            }
            try await host.send(RemoteWire.encoder().encode(LocalAgentFrame(kind: .closed)))
        }
        let started = ContinuousClock.now
        do {
            _ = try await rpc.request(LocalAgentRequest(operation: .attach, sessionID: session.id, columns: 80, rows: 24,
                                                        mode: .view, flow: flow ? 1 : nil))
        } catch where !flow {
            // Without the window the relay can overflow before the reply even arrives.
        }
        let sampler = FlowPeakSampler()
        sampler.start()
        let rendered = FlowTranscript()
        do {
            for try await event in rpc.events {
                rendered.record(event)
                if case .output(let data) = event {
                    try await Task.sleep(for: .microseconds(Int(Double(data.count) / 1_500_000 * 1_000_000)))
                }
            }
        } catch {
            // The legacy run ends here when the relay closes.
            if flow { print("RELAY-FLOW synthetic consumer error: \(error)") }
        }
        let elapsed = started.duration(to: .now)
        let memory = sampler.stop()
        if flow, case .failure(let error) = await mac.result { print("RELAY-FLOW synthetic mac error: \(error)") }
        mac.cancel()
        _ = await mac.result
        await rpc.close()
        await host.close()
        let stats = flow ? await window.stats : nil
        return SyntheticResult(
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            bytes: rendered.count, expected: expected.count,
            identical: rendered.count == expected.count && rendered.hash == expected.hash,
            geometry: rendered.geometryOffsets, expectedGeometry: expected.geometryOffsets,
            close: tunnel.closeReason == .endpoint ? nil : tunnel.closeReason,
            leg: await tunnel.toClient.stats, window: stats, memory: memory)
    }
}
