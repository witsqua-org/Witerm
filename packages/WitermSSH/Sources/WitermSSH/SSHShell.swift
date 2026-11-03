import Foundation
@preconcurrency import Citadel
@preconcurrency import NIO
@preconcurrency import NIOSSH

/// A single PTY channel. The lock protects lifecycle and pending input bytes;
/// the channel handler and reply queue are exclusively event-loop owned.
public final class SSHShell: @unchecked Sendable {
    /// The shell's output in arrival order. Reading it is what lets more
    /// arrive; nothing is ever dropped (see `SSHOutputFlow`).
    public let output: SSHShellOutput
    internal let id = UUID()
    private let channel: Channel
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var closed = false
    private var pendingInput = 0

    private init(channel: Channel, output: SSHShellOutput,
                 continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.channel = channel; self.output = output; self.continuation = continuation
    }

    internal static func open(client: SSHClient, columns: Int, rows: Int) async throws -> SSHShell {
        try validateDimensions(columns, rows)
        // Unbounded in elements, bounded in bytes by the flow: past its high
        // water mark the channel stops reading and the SSH window holds the
        // host back. A fixed element count dropped output, and with it the
        // session, whenever one socket read carried more than it (`seq 1 100000`).
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        let flow = SSHOutputFlow()
        let handler = SSHPTYHandler(continuation: pair.continuation, flow: flow)
        let channel = try await client.createSessionChannel { channel in
            channel.pipeline.addHandler(handler)
        }
        let shell = SSHShell(channel: channel, output: SSHShellOutput(stream: pair.stream, flow: flow), continuation: pair.continuation)
        pair.continuation.onTermination = { [weak shell] _ in
            guard let shell else { return }
            Task { await shell.close() }
        }
        do {
            try await withTaskCancellationHandler {
                try await handler.request(channel: channel, event: SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: "xterm-256color", terminalCharacterWidth: columns,
                    terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                ))
                try await handler.request(channel: channel, event: SSHChannelRequestEvent.ShellRequest(wantReply: true))
                try Task.checkCancellation()
            } onCancel: { channel.close(promise: nil) }
            return shell
        } catch {
            await shell.close()
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { return }
        guard data.count <= 16384 else { throw SSHFailure.backpressure }
        try lock.withLock {
            guard !closed, channel.isActive else { throw SSHFailure.disconnected }
            guard pendingInput <= 262144 - data.count, channel.isWritable else { throw SSHFailure.backpressure }
            pendingInput += data.count
        }
        defer { lock.withLock { pendingInput -= data.count } }
        // A stalled peer cannot retain pending writes indefinitely. Closing the
        // channel settles the future; no code retries an uncertain write.
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) { self.channel.close(promise: nil) }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(data: data))))
        } onCancel: { self.channel.close(promise: nil) }
    }

    public func resize(columns: Int, rows: Int) async throws {
        try Self.validateDimensions(columns, rows)
        guard lock.withLock({ !closed }), channel.isActive else { throw SSHFailure.disconnected }
        try Task.checkCancellation()
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) { self.channel.close(promise: nil) }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0
            ))
        } onCancel: { self.channel.close(promise: nil) }
    }

    public func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }; closed = true; return true
        }
        guard shouldClose else { return }
        continuation.finish()
        try? await channel.close()
    }

    private static func validateDimensions(_ columns: Int, _ rows: Int) throws {
        guard (20...500).contains(columns), (5...200).contains(rows) else { throw SSHFailure.invalidConfiguration }
    }

    deinit { continuation.finish(); channel.close(promise: nil) }
}

/// Shell output as an async sequence; each element read is counted as
/// consumed, which is what resumes a channel the flow paused.
public struct SSHShellOutput: AsyncSequence, Sendable {
    public typealias Element = Data
    let stream: AsyncThrowingStream<Data, Error>
    let flow: SSHOutputFlow

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<Data, Error>.AsyncIterator
        let flow: SSHOutputFlow

        public mutating func next() async throws -> Data? {
            let data = try await base.next()
            if let data { flow.consumed(data.count) }
            return data
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: stream.makeAsyncIterator(), flow: flow) }
}

/// Bytes the shell produced that its reader hasn't taken yet. Above
/// `highWater` the channel's next read waits (`park`) until the reader is
/// back under `lowWater`; meanwhile NIOSSH holds what arrived without
/// widening the SSH window, so the host pauses rather than flooding memory.
final class SSHOutputFlow: @unchecked Sendable {
    static let highWater = 1 << 20
    static let lowWater = 256 << 10
    private let lock = NSLock()
    private var queued = 0
    private var resume: (() -> Void)?

    func produced(_ count: Int) { lock.withLock { queued += count } }

    var isAboveHighWater: Bool { lock.withLock { queued > Self.highWater } }

    /// Keeps `resume` for when the reader catches up. False when it already
    /// has, and the caller should read now.
    func park(_ resume: @escaping () -> Void) -> Bool {
        lock.withLock {
            guard queued > Self.lowWater else { return false }
            self.resume = resume
            return true
        }
    }

    func consumed(_ count: Int) {
        let resume = lock.withLock { () -> (() -> Void)? in
            queued -= count
            guard queued <= Self.lowWater, let waiting = self.resume else { return nil }
            self.resume = nil
            return waiting
        }
        resume?()
    }
}

private final class SSHPTYHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let flow: SSHOutputFlow
    private var reply: EventLoopPromise<Void>?
    private var replyTimeout: Scheduled<Void>?
    private var ended = false

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation, flow: SSHOutputFlow) {
        self.continuation = continuation; self.flow = flow
    }

    /// Reads wait while the reader is far behind; see `SSHOutputFlow`.
    func read(context: ChannelHandlerContext) {
        if flow.isAboveHighWater {
            let loop = context.eventLoop
            let bound = NIOLoopBound(context, eventLoop: loop)
            if flow.park({ loop.execute { bound.value.read() } }) { return }
        }
        context.read()
    }

    func request<Event: Sendable>(channel: Channel, event: Event) async throws {
        try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            guard !self.ended, self.reply == nil else { return channel.eventLoop.makeFailedFuture(SSHFailure.disconnected) }
            let reply = channel.eventLoop.makePromise(of: Void.self)
            self.reply = reply
            self.replyTimeout = channel.eventLoop.scheduleTask(in: .seconds(10)) {
                self.fail(SSHFailure.disconnected, channel: channel)
            }
            channel.triggerUserOutboundEvent(event).whenFailure { error in self.fail(error, channel: channel) }
            return reply.futureResult
        }.get()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !ended else { return }
        let incoming = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = incoming.data,
              incoming.type == .channel || incoming.type == .stdErr else {
            fail(SSHFailure.disconnected, channel: context.channel); return
        }
        // Elements of at most 8 KiB; the flow bounds how many bytes wait.
        while bytes.readableBytes > 0 {
            guard let part = bytes.readBytes(length: min(bytes.readableBytes, 8192)) else { break }
            flow.produced(part.count)
            switch continuation.yield(Data(part)) {
            case .enqueued: break
            case .dropped: fail(SSHFailure.backpressure, channel: context.channel); return
            case .terminated: context.close(promise: nil); return
            @unknown default: fail(SSHFailure.disconnected, channel: context.channel); return
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            replyTimeout?.cancel(); replyTimeout = nil
            let pending = reply; reply = nil; pending?.succeed(())
        } else if event is ChannelFailureEvent {
            fail(SSHFailure.disconnected, channel: context.channel)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(error: nil)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish(error: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error, channel: context.channel) }

    private func finish(error: Error?) {
        guard !ended else { return }; ended = true
        replyTimeout?.cancel(); replyTimeout = nil
        let pending = reply; reply = nil; pending?.fail(error ?? SSHFailure.disconnected)
        continuation.finish(throwing: error)
    }

    private func fail(_ error: Error, channel: Channel) {
        finish(error: error)
        channel.close(promise: nil)
    }
}
