import Foundation
@preconcurrency import Citadel
@preconcurrency import NIO
@preconcurrency import NIOSSH
@preconcurrency import Network

/// Only resource membership is shared with callbacks; each bridge owns mutable
/// I/O state on its private serial queue. No payload is stored in this registry.
final class SSHForwardRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: SSHForwardRecord] = [:]
    func reserve(_ forward: SSHForward) throws -> SSHForwardRecord {
        try lock.withLock {
            guard records.count < 8, !records.values.contains(where: {
                $0.forward.kind == forward.kind && forward.listenPort != 0
                    && $0.forward.listenPort == forward.listenPort
            }) else { throw SSHFailure.invalidForward }
            let record = SSHForwardRecord(forward: forward)
            records[forward.id] = record
            return record
        }
    }
    func active() -> [SSHForward] { lock.withLock { records.values.filter(\.isReady).map(\.forward) } }
    func remove(_ id: UUID) -> SSHForwardRecord? {
        let record = lock.withLock { records.removeValue(forKey: id) }
        record?.stop()
        return record
    }
    func closeAll() async {
        let previous = lock.withLock {
            let result = Array(records.values); records.removeAll(); return result
        }
        for record in previous { record.stop() }
    }
}

final class SSHForwardRecord: @unchecked Sendable {
    private struct Peer {
        var channel: Channel?
        var network: NWConnection?
        var bridge: SSHNetworkBridge?
    }
    private let lock = NSLock()
    private var value: SSHForward
    private var listener: NWListener?
    private var task: Task<Void, Never>?
    private var peers: [UUID: Peer] = [:]
    private var stopped = false
    private var ready = false
    private var finished = false
    init(forward: SSHForward) { value = forward }
    var forward: SSHForward { lock.withLock { value } }
    var isReady: Bool { lock.withLock { ready && !stopped } }
    var isFinished: Bool { lock.withLock { finished } }
    func markFinished() { lock.withLock { finished = true } }
    func activate(port: Int, listener: NWListener? = nil) throws -> SSHForward {
        try lock.withLock {
            guard !stopped else { listener?.cancel(); throw CancellationError() }
            value = SSHForward(id: value.id, kind: value.kind, listenPort: port,
                               targetHost: value.targetHost, targetPort: value.targetPort)
            self.listener = listener; ready = true
            return value
        }
    }
    func setTask(_ task: Task<Void, Never>) {
        let cancel = lock.withLock { if stopped { return true }; self.task = task; return false }
        if cancel { task.cancel() }
    }
    func setListener(_ listener: NWListener) throws {
        try lock.withLock {
            guard !stopped else { listener.cancel(); throw CancellationError() }
            self.listener = listener
        }
    }
    func reservePeer() -> UUID? {
        lock.withLock {
            guard !stopped, peers.count < 32 else { return nil }
            let id = UUID(); peers[id] = Peer(); return id
        }
    }
    func trackNetwork(_ network: NWConnection, token: UUID) -> Bool {
        let accepted = lock.withLock {
            guard !stopped, peers[token] != nil else { return false }
            peers[token]?.network = network; return true
        }
        if !accepted { network.cancel() }
        return accepted
    }
    func trackChannel(_ channel: Channel, token: UUID) -> Bool {
        let accepted = lock.withLock {
            guard !stopped, peers[token] != nil else { return false }
            peers[token]?.channel = channel; return true
        }
        if !accepted { channel.close(promise: nil) }
        return accepted
    }
    func installBridge(_ bridge: SSHNetworkBridge, token: UUID) -> Bool {
        let accepted = lock.withLock {
            guard !stopped, peers[token] != nil else { return false }
            peers[token]?.bridge = bridge; return true
        }
        if !accepted { bridge.stop() }
        return accepted
    }
    func releasePeer(_ token: UUID) {
        guard let peer = lock.withLock({ peers.removeValue(forKey: token) }) else { return }
        peer.bridge?.stop(); peer.network?.cancel(); peer.channel?.close(promise: nil)
    }
    func stop() {
        let resources = lock.withLock { () -> (Task<Void, Never>?, NWListener?, [Peer]) in
            guard !stopped else { return (nil, nil, []) }
            stopped = true
            let result = (task, listener, Array(peers.values))
            task = nil; listener = nil; peers.removeAll()
            return result
        }
        resources.0?.cancel()
        resources.1?.stateUpdateHandler = nil
        resources.1?.newConnectionHandler = nil
        resources.1?.cancel()
        for peer in resources.2 {
            peer.bridge?.stop(); peer.network?.cancel(); peer.channel?.close(promise: nil)
        }
    }
}

private final class SSHForwardStart: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<SSHForward, Error>?
    private var waiter: CheckedContinuation<SSHForward, Error>?
    func finish(_ value: Result<SSHForward, Error>) {
        let previous = lock.withLock { () -> CheckedContinuation<SSHForward, Error>? in
            guard result == nil else { return nil }
            result = value; let previous = waiter; waiter = nil; return previous
        }
        previous?.resume(with: value)
    }
    func wait() async throws -> SSHForward {
        try await withCheckedThrowingContinuation { continuation in
            let previous = lock.withLock { () -> Result<SSHForward, Error>? in
                if let result { return result }; waiter = continuation; return nil
            }
            if let previous { continuation.resume(with: previous) }
        }
    }
}

enum SSHForwardPolicy {
    static func validate(kind: SSHForward.Kind, listenPort: Int, targetHost: String, targetPort: Int) throws {
        guard (kind == .local ? (0...65535).contains(listenPort) : (1...65535).contains(listenPort)),
              (1...65535).contains(targetPort), !targetHost.isEmpty, targetHost.utf8.count <= 253,
              !targetHost.contains(where: { $0.isWhitespace }),
              !targetHost.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SSHFailure.invalidForward }
    }
}

extension SSHConnection {
    public func activeForwards() -> [SSHForward] { forwarding.active() }
    public func startForward(
        kind: SSHForward.Kind, listenPort: Int, targetHost: String, targetPort: Int
    ) async throws -> SSHForward {
        try requireConnected()
        try SSHForwardPolicy.validate(kind: kind, listenPort: listenPort, targetHost: targetHost, targetPort: targetPort)
        let forward = SSHForward(kind: kind, listenPort: listenPort, targetHost: targetHost, targetPort: targetPort)
        let record = try forwarding.reserve(forward)
        let start = SSHForwardStart(), registry = forwarding, client = client
        do {
            if kind == .local {
                let parameters = NWParameters.tcp
                let port: NWEndpoint.Port = listenPort == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(listenPort))!
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                let listener = try NWListener(using: parameters, on: port)
                try record.setListener(listener)
                listener.newConnectionHandler = { network in
                    guard let token = record.reservePeer(), record.trackNetwork(network, token: token) else {
                        network.cancel(); return
                    }
                    Task {
                        do {
                            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                            _ = try await client.createDirectTCPIPChannel(using: .init(
                                targetHost: targetHost, targetPort: targetPort, originatorAddress: origin
                            )) { channel in
                                guard record.trackChannel(channel, token: token) else {
                                    return channel.eventLoop.makeFailedFuture(SSHFailure.cancelled)
                                }
                                let bridge = SSHNetworkBridge(channel: channel, network: network) { [weak owner = record] in
                                    owner?.releasePeer(token)
                                }
                                guard record.installBridge(bridge, token: token) else {
                                    return channel.eventLoop.makeFailedFuture(SSHFailure.cancelled)
                                }
                                return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                                    channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                                }.flatMap { channel.pipeline.addHandler(bridge) }
                            }
                        } catch { record.releasePeer(token) }
                    }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = listener.port else { start.finish(.failure(SSHFailure.invalidForward)); return }
                        do { start.finish(.success(try record.activate(port: Int(port.rawValue), listener: listener))) }
                        catch { start.finish(.failure(error)) }
                    case .failed(let error): start.finish(.failure(error)); _ = registry.remove(forward.id)
                    case .cancelled: start.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: DispatchQueue(label: "com.witerm.ssh.listener"))
            } else {
                let task = Task {
                    defer { record.markFinished() }
                    do {
                        try await client.withRemotePortForward(host: "127.0.0.1", port: listenPort, onOpen: { info in
                            guard info.host == "127.0.0.1", info.boundPort == listenPort else { throw SSHFailure.invalidForward }
                            start.finish(.success(try record.activate(port: info.boundPort)))
                        }, handleChannel: { channel, info in
                            guard info.listeningHost == "127.0.0.1", info.listeningPort == listenPort,
                                  let token = record.reservePeer(), record.trackChannel(channel, token: token) else {
                                return channel.eventLoop.makeFailedFuture(SSHFailure.invalidForward)
                            }
                            let network = NWConnection(host: NWEndpoint.Host(targetHost),
                                                       port: NWEndpoint.Port(rawValue: UInt16(targetPort))!, using: .tcp)
                            guard record.trackNetwork(network, token: token) else {
                                return channel.eventLoop.makeFailedFuture(SSHFailure.cancelled)
                            }
                            let bridge = SSHNetworkBridge(channel: channel, network: network) { [weak owner = record] in
                                owner?.releasePeer(token)
                            }
                            guard record.installBridge(bridge, token: token) else {
                                return channel.eventLoop.makeFailedFuture(SSHFailure.cancelled)
                            }
                            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                                channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                            }.flatMap { channel.pipeline.addHandlers(SSHForwardDataCodec(), bridge) }
                        })
                    } catch { start.finish(.failure(error)) }
                    _ = registry.remove(forward.id)
                }
                record.setTask(task)
            }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                start.finish(.failure(SSHFailure.disconnected))
                _ = registry.remove(forward.id)
                if kind == .remote {
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        if !record.isFinished { try? await client.close() }
                    }
                }
            }
            defer { deadline.cancel() }
            return try await withTaskCancellationHandler {
                let result = try await start.wait()
                try Task.checkCancellation()
                return result
            } onCancel: {
                start.finish(.failure(CancellationError()))
                _ = registry.remove(forward.id)
                if kind == .remote {
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        if !record.isFinished { try? await client.close() }
                    }
                }
            }
        } catch {
            _ = forwarding.remove(forward.id)
            throw error
        }
    }
    public func stopForward(id: UUID) async {
        guard let record = forwarding.remove(id) else { return }
        if record.forward.kind == .remote {
            for _ in 0..<100 {
                if record.isFinished { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            await disconnect()
        }
    }
}

/// Network.framework only receives one explicit <=64KiB chunk at a time. Unlike
/// NIOPosix's readEOF drain, a TCP FIN cannot force an unbounded synchronous read.
/// All state below is owned by `queue`; NIO callbacks only enqueue immutable data.
final class SSHNetworkBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let channel: Channel
    private let network: NWConnection
    private let queue = DispatchQueue(label: "com.witerm.ssh.forward.peer")
    private let onClosed: @Sendable () -> Void
    private var ready = false, stopped = false
    private var receivePending = false, toSSHInFlight = false, sshReadPending = false
    private var tcpInputEnded = false, sshInputEnded = false, channelGone = false
    private var sshEOFSent = false, sshEOFComplete = false, tcpFINSent = false, tcpFINComplete = false
    private var sendPending = false
    private var pendingBytes = 0
    private var buffered: [Data] = []
    private var deadline: DispatchWorkItem?
    private var failureDeadline: DispatchWorkItem?
    private var fatalAfterDrain = false, receiveFailed = false
    init(channel: Channel, network: NWConnection, onClosed: @escaping @Sendable () -> Void) {
        self.channel = channel; self.network = network; self.onClosed = onClosed
    }
    func handlerAdded(context: ChannelHandlerContext) {
        queue.async { [self] in
            guard !stopped else { return }
            network.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, !ready else { return }; finish()
            }
            deadline = timeout
            queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            network.start(queue: queue)
        }
    }
    private func stateChanged(_ state: NWConnection.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            ready = true; deadline?.cancel(); deadline = nil
            receiveTCP(); requestSSHRead(); pumpSend()
        case .failed:
            // A terminal state can precede queued content and the final receive
            // completion. Cancelling here would discard valid buffered bytes.
            if ready { beginFailureDrain() } else { finish() }
        case .cancelled: finish()
        case .waiting: if ready { finish() }
        default: break
        }
    }
    func channelActive(context: ChannelHandlerContext) {
        queue.async { [self] in requestSSHRead() }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard bytes.readableBytes <= 262144 else { stop(); return }
        while bytes.readableBytes > 0 {
            guard let part = bytes.readSlice(length: min(65536, bytes.readableBytes)) else { break }
            let value = Data(part.readableBytesView)
            queue.async { [self] in
                guard !stopped else { return }
                guard value.count <= 262144 - pendingBytes else { finish(); return }
                pendingBytes += value.count; buffered.append(value); pumpSend()
            }
        }
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        queue.async { [self] in
            sshReadPending = false
            pumpSend(); requestSSHRead()
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            queue.async { [self] in sshInputEnded = true; pumpSend(); finishIfDrained() }
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        queue.async { [self] in
            channelGone = true; sshInputEnded = true; sshReadPending = false
            if tcpInputEnded { sshEOFComplete = true }
            pumpSend(); finishIfDrained()
        }
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { stop() }
    func handlerRemoved(context: ChannelHandlerContext) {
        queue.async { [self] in
            if !channelGone { channelGone = true; sshInputEnded = true; pumpSend(); finishIfDrained() }
        }
    }
    private func receiveTCP() {
        guard ready, !stopped, !receivePending, !toSSHInFlight, !tcpInputEnded, !receiveFailed else { return }
        receivePending = true
        network.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !stopped else { return }
            receivePending = false
            let hasError = error != nil
            if hasError {
                receiveFailed = true
                beginFailureDrain(fatal: true)
            } else if complete { tcpInputEnded = true }
            if let data, !data.isEmpty {
                guard data.count <= 65536, !channelGone else { finish(); return }
                toSSHInFlight = true
                channel.writeAndFlush(ByteBuffer(bytes: data)).whenComplete { [weak self] result in
                    guard let self else { return }
                    queue.async { [self] in
                        guard !stopped else { return }
                        toSSHInFlight = false
                        switch result {
                        case .failure:
                            finish()
                        case .success:
                            if hasError { finishIfDrained() }
                            else if tcpInputEnded { sendSSHOutputEOF() }
                            else { receiveTCP() }
                        }
                    }
                }
            } else if hasError { finishIfDrained() }
            else if tcpInputEnded { sendSSHOutputEOF() }
            else { receiveTCP() }
        }
    }
    private func sendSSHOutputEOF() {
        guard !stopped, tcpInputEnded, !toSSHInFlight, !sshEOFSent else { return }
        if fatalAfterDrain { finishIfDrained(); return }
        sshEOFSent = true
        if channelGone { sshEOFComplete = true; finishIfDrained(); return }
        channel.close(mode: .output).whenComplete { [weak self] result in
            guard let self else { return }
            queue.async { [self] in
                guard !stopped else { return }
                if case .failure = result, !channelGone { finish(); return }
                sshEOFComplete = true; finishIfDrained()
            }
        }
    }
    private func requestSSHRead() {
        guard ready, !stopped, !fatalAfterDrain, !sshInputEnded, !sshReadPending, pendingBytes < 65536, channel.isActive else { return }
        sshReadPending = true
        channel.read()
    }
    private func pumpSend() {
        guard ready, !stopped, !fatalAfterDrain, !sendPending else { return }
        if !buffered.isEmpty {
            let data = buffered.removeFirst()
            sendPending = true
            network.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !stopped else { return }
                sendPending = false; pendingBytes -= data.count
                guard error == nil else { beginFailureDrain(fatal: true); finishIfDrained(); return }
                pumpSend(); requestSSHRead(); finishIfDrained()
            })
        } else if sshInputEnded, pendingBytes == 0, !tcpFINSent {
            tcpFINSent = true; sendPending = true
            network.send(content: nil, contentContext: .finalMessage, isComplete: true,
                         completion: .contentProcessed { [weak self] error in
                guard let self, !stopped else { return }
                sendPending = false
                // Even an outbound FIN failure must not cancel a queued final
                // read. Let the receive completion distinguish EOF from error.
                if error != nil { beginFailureDrain() }
                tcpFINComplete = true; finishIfDrained()
            })
        }
    }
    private func beginFailureDrain(fatal: Bool = false) {
        if fatal {
            fatalAfterDrain = true
            pendingBytes -= buffered.reduce(0) { $0 + $1.count }
            buffered.removeAll()
        }
        guard failureDeadline == nil else { return }
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        failureDeadline = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
    private func finishIfDrained() {
        if fatalAfterDrain, !receivePending, !toSSHInFlight,
           receiveFailed || tcpInputEnded, pendingBytes == 0, !sendPending { finish(); return }
        // Once the SSH child is gone, there is no destination for future TCP
        // input. Release it after the already received response/FIN is drained.
        if channelGone, pendingBytes == 0, !sendPending, tcpFINComplete { finish(); return }
        if tcpInputEnded, sshInputEnded, !toSSHInFlight, pendingBytes == 0,
           tcpFINComplete, sshEOFComplete { finish() }
    }
    func stop() { queue.async { [self] in finish() } }
    private func finish() {
        guard !stopped else { return }; stopped = true
        deadline?.cancel(); deadline = nil
        failureDeadline?.cancel(); failureDeadline = nil
        buffered.removeAll(); pendingBytes = 0
        network.stateUpdateHandler = nil
        network.cancel(); channel.close(promise: nil)
        onClosed()
    }
}

private final class SSHForwardDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard value.type == .channel, case .byteBuffer(let bytes) = value.data else { context.close(promise: nil); return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}
