import Darwin
import Foundation
import WitermCore

final class AgentConnection: @unchecked Sendable {
    let token = UUID()
    let descriptor: Int32
    // Attachment state is exclusively owned by AgentBroker's serial queue.
    var sessionID: String?
    var mode: LocalAttachmentMode?
    /// The paired device an attachment acts for; nil for this Mac.
    var peer: LocalRemotePeer?
    var child: PTYChild?
    private let condition = NSCondition()
    private var outgoing: [Data] = []
    private var queuedBytes = 0
    private var closing = false
    private var flush = true
    private var workers = 2
    private let received: @Sendable (Data, AgentConnection) -> Void
    private let disconnected: @Sendable (AgentConnection, Bool) -> Void
    static let deliveryLimit = 256 * 1024
    /// How long a client may take nothing before it's let go. Longer than
    /// the client's own wait, so a stuck window says so itself.
    static let stallLimit: TimeInterval = 45
    private var lastDelivery = ProcessInfo.processInfo.systemUptime

    init(descriptor: Int32, received: @escaping @Sendable (Data, AgentConnection) -> Void, disconnected: @escaping @Sendable (AgentConnection, Bool) -> Void) throws {
        self.descriptor = descriptor
        self.received = received
        self.disconnected = disconnected
        try Posix.closeOnExec(descriptor)
        try Posix.nonblocking(descriptor)
        Posix.noSignalPipe(descriptor)
    }

    func start() {
        Thread.detachNewThread { [self] in readLoop() }
        Thread.detachNewThread { [self] in writeLoop() }
    }

    @discardableResult
    func enqueue(_ frame: LocalAgentFrame) -> Bool {
        guard var bytes = try? wireEncoder().encode(frame) else { finish(afterFlush: false); return false }
        bytes.append(10)
        condition.lock()
        guard !closing else { condition.unlock(); return false }
        if queuedBytes + bytes.count > Self.deliveryLimit {
            condition.unlock()
            finish(afterFlush: true, terminalError: .backpressure, emitClosed: true)
            return false
        }
        outgoing.append(bytes)
        queuedBytes += bytes.count
        condition.signal()
        condition.unlock()
        return true
    }

    /// Blocks a PTY reader while this connection's queue can't take another
    /// chunk, so output waits in the PTY (and tmux) instead of overflowing
    /// here. False once the connection is closing, or after it's ended for
    /// delivering nothing for `stallLimit`.
    func waitForRoom(reserve: Int = 32 * 1024) -> Bool {
        condition.lock()
        while queuedBytes + reserve > Self.deliveryLimit, !closing {
            if ProcessInfo.processInfo.systemUptime - lastDelivery >= Self.stallLimit {
                condition.unlock()
                finish(afterFlush: false, terminalError: .backpressure, emitClosed: true)
                return false
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.5))
        }
        let open = !closing
        condition.unlock()
        return open
    }

    func finish(afterFlush: Bool, terminalError: LocalAgentErrorCode? = nil, emitClosed: Bool = false) {
        condition.lock()
        guard !closing else { condition.unlock(); return }
        closing = true
        flush = afterFlush
        if !afterFlush { queuedBytes -= outgoing.reduce(0) { $0 + $1.count }; outgoing.removeAll() }
        if emitClosed, var frame = try? wireEncoder().encode(LocalAgentFrame(kind: .closed, error: terminalError)) {
            frame.append(10)
            // One small terminal-error frame is the only reserved overhead.
            outgoing.append(frame); queuedBytes += frame.count
        }
        condition.broadcast()
        condition.unlock()
        _ = Darwin.shutdown(descriptor, SHUT_RD)
        disconnected(self, false)
    }

    private func workerEnded() {
        condition.lock()
        workers -= 1
        let last = workers == 0
        condition.unlock()
        if last { Darwin.close(descriptor); disconnected(self, true) }
    }

    private func readLoop() {
        defer { finish(afterFlush: false); workerEnded() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        while true {
            condition.lock(); let done = closing; condition.unlock()
            if done { return }
            var polled = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&polled, 1, 250)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { return }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return
            }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.count > 65536 {
                    enqueue(LocalAgentFrame(kind: .response, ok: false, error: .invalidRequest))
                    finish(afterFlush: true); return
                }
                received(line, self)
                condition.lock(); let done = closing; condition.unlock()
                if done { return }
            }
            if pending.count > 65536 {
                enqueue(LocalAgentFrame(kind: .response, ok: false, error: .invalidRequest))
                finish(afterFlush: true); return
            }
        }
    }

    private func writeLoop() {
        defer { _ = Darwin.shutdown(descriptor, SHUT_RDWR); finish(afterFlush: false); workerEnded() }
        while true {
            condition.lock()
            while outgoing.isEmpty && !closing { condition.wait() }
            if closing && (!flush || outgoing.isEmpty) { condition.unlock(); return }
            let bytes = outgoing.removeFirst()
            // Keep in-flight bytes in the accounting until the bounded write ends.
            condition.unlock()
            // A client that reads slowly is waited for; one that reads nothing
            // for the stall limit is let go.
            let success = Posix.writeAll(descriptor, data: bytes, timeout: Self.stallLimit)
            condition.lock()
            queuedBytes -= bytes.count
            lastDelivery = ProcessInfo.processInfo.systemUptime
            condition.broadcast()
            condition.unlock()
            if !success { return }
        }
    }
}
