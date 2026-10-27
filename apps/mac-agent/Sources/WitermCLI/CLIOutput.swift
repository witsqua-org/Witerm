import Darwin
import Foundation
import WitermCore

/// Optional terminal messages must never prevent restoring the terminal or
/// exiting. Keep ordinary session output and scripted stdout lossless.
enum CLIOutput {
    static let standardOutput = CLIMessageWriter(descriptor: STDOUT_FILENO)
    static let standardError = CLIMessageWriter(descriptor: STDERR_FILENO)
}

final class CLIMessageWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var writing = false

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ data: Data, timeout: TimeInterval = 0.5) {
        guard !data.isEmpty else { return }
        let accepted = lock.withLock {
            guard !writing else { return false }
            writing = true
            return true
        }
        // At most one pending message per stream, even if help is requested
        // repeatedly while the terminal or stderr pipe is full.
        guard accepted else { return }
        let deadline = DispatchTime.now() + timeout
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            defer {
                lock.withLock { writing = false }
                finished.signal()
            }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count, DispatchTime.now() < deadline {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        var polled = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&polled, 1, 20)
                        continue
                    }
                    return
                }
            }
        }
        // poll(POLLOUT) cannot bound a subsequent blocking write (especially
        // with the session output writer using the same terminal). Bound the
        // caller's wait instead. Do not set O_NONBLOCK on inherited descriptors:
        // that would also change the parent shell's shared open-file state.
        _ = finished.wait(timeout: deadline)
    }
}

/// Drains ordered terminal bytes on a separate thread. A blocked terminal must
/// not stop the event reader from noticing service failure or session closure.
final class CLIStreamWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [Data] = []
    private var queuedBytes = 0
    private var finishing = false
    private var stopped = false
    private let completed: @Sendable (Result<Void, Error>) -> Void
    private static let limit = 256 * 1024

    init(completed: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.completed = completed
        Thread.detachNewThread { [self] in drain() }
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        // Includes the in-flight write, not just the waiting queue.
        guard !stopped, !finishing, queuedBytes + data.count <= Self.limit else {
            throw LocalAgentClientError.backpressure
        }
        pending.append(data)
        queuedBytes += data.count
        condition.signal()
    }

    func finish() {
        condition.lock()
        guard !stopped, !finishing else { condition.unlock(); return }
        finishing = true
        condition.signal()
        condition.unlock()
        // Preserve the last frame on a normal exit, but don't wait forever if
        // the terminal stopped reading it. Error/explicit detach don't flush.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            complete(.failure(LocalAgentClientError.backpressure))
        }
    }

    func stop() {
        condition.lock()
        stopped = true
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    private func complete(_ result: Result<Void, Error>) {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        stopped = true
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
        completed(result)
    }

    private func drain() {
        while true {
            condition.lock()
            while pending.isEmpty, !finishing, !stopped { condition.wait() }
            guard !stopped else { condition.unlock(); return }
            guard !pending.isEmpty else {
                condition.unlock()
                complete(.success(()))
                return
            }
            let data = pending.removeFirst()
            condition.unlock()
            guard write(data) else { complete(.failure(LocalAgentClientError.backpressure)); return }
            condition.lock()
            queuedBytes -= data.count
            condition.unlock()
        }
    }

    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                condition.lock(); let stop = stopped; condition.unlock()
                if stop { return false }
                let count = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var polled = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&polled, 1, 20)
                    continue
                }
                return false
            }
            return true
        }
    }
}
