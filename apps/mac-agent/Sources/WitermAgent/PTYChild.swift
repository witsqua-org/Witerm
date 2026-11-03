import Darwin
import Foundation

final class PTYChild: @unchecked Sendable {
    private let lock = NSLock()
    private let inputLock = NSLock()
    // Lock order: outputBarrier -> lock. Neither an output callback nor an
    // ended callback may synchronously enter the broker's state queue.
    private let outputBarrier = NSLock()
    private var stopped = false
    private var started = false
    private var childReaped = false
    private var master: Int32
    private let pid: pid_t
    let terminalName: String

    init(executable: String, arguments: [String], environment: [String: String], columns: Int, rows: Int) throws {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw AgentFailure() }
        do {
            var name = [CChar](repeating: 0, count: 1024)
            guard ttyname_r(slave, &name, name.count) == 0 else { throw AgentFailure() }
            terminalName = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            try Posix.closeOnExec(master); try Posix.closeOnExec(slave)
            try Posix.nonblocking(master)
            pid = try Posix.spawn(executable: executable, arguments: arguments, environment: environment, input: slave, output: slave, tty: true)
        } catch { Darwin.close(master); Darwin.close(slave); throw error }
        Darwin.close(slave)
        self.master = master
    }

    /// `room` paces reading: it's asked before each read and may block until
    /// whoever receives the output can take more; false stops reading. Not
    /// reading lets the PTY fill, so tmux coalesces the screen for a slow
    /// client instead of anything being dropped here.
    func start(output: @escaping @Sendable (Data) -> Bool, room: @escaping @Sendable () -> Bool = { true },
               ended: @escaping @Sendable () -> Void) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }; started = true; return true
        }
        guard shouldStart else { return }
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            var status: Int32 = 0
            var reaped = false
            while true {
                let descriptor = lock.withLock { stopped ? -1 : master }
                if descriptor < 0 { break }
                var polled = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&polled, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 { break }
                if ready > 0 {
                    // Outside the barrier, so pausing output elsewhere never waits on a slow client.
                    guard room() else { break }
                    outputBarrier.lock()
                    let readable = lock.withLock { !stopped && master == descriptor }
                    guard readable else { outputBarrier.unlock(); break }
                    var count = 0
                    var readError: Int32 = 0
                    buffer.withUnsafeMutableBytes { storage in
                        guard let base = storage.baseAddress else { return }
                        // Coalesce only bytes already readable, with no timer
                        // or deferred Data task. A tmux redraw often comprises
                        // many tiny writes; each emitted chunk remains <=8 KiB.
                        while count < storage.count {
                            let part = Darwin.read(descriptor, base.advanced(by: count), storage.count - count)
                            if part > 0 { count += part; continue }
                            if part < 0 && errno == EINTR { continue }
                            if count == 0 { count = Int(part); readError = errno }
                            break
                        }
                    }
                    let accepted = count <= 0 || output(Data(buffer.prefix(count)))
                    outputBarrier.unlock()
                    if count > 0 {
                        if !accepted { break }
                    } else if count == 0 { break }
                    else if readError != EAGAIN && readError != EWOULDBLOCK && readError != EINTR { break }
                }
                if !reaped {
                    reaped = lock.withLock { () -> Bool in
                        let result = waitpid(pid, &status, WNOHANG)
                        if result == pid || (result < 0 && errno == ECHILD) {
                            childReaped = true
                            return true
                        }
                        return false
                    }
                }
                if reaped && ready == 0 { break }
            }
            stop()
            let finalDescriptor = lock.withLock { () -> Int32 in
                let value = master; master = -1; return value
            }
            if finalDescriptor >= 0 { Darwin.close(finalDescriptor) }
            if !reaped {
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                lock.withLock { childReaped = true }
            }
            ended()
        }
    }

    func send(_ data: Data) throws {
        inputLock.lock(); defer { inputLock.unlock() }
        let ok = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            return Posix.writeAll(master, data: data, timeout: 1)
        }
        guard ok else { throw AgentFailure(.backpressure) }
    }

    func resize(columns: Int, rows: Int) throws {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        let result: Int32 = lock.withLock {
            guard !stopped, !childReaped, ioctl(master, TIOCSWINSZ, &size) == 0 else { return -1 }
            // A posix_spawn/openpty child need not be the slave's foreground
            // process group. Do not depend on the kernel delivering SIGWINCH
            // implicitly: notify only this tmux attach process explicitly.
            return kill(pid, SIGWINCH)
        }
        guard result == 0 else { throw AgentFailure() }
    }

    // The broker takes these in stable connection order around the complete
    // geometry/resize/full-redraw transaction. Readers hold at most one 8 KiB
    // chunk and enqueue synchronously; no deferred Data work can accumulate.
    func pauseOutput() { outputBarrier.lock() }
    func resumeOutput() { outputBarrier.unlock() }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            // Only this attached tmux client is signalled, never the server or
            // the shell's process group. Closing a view leaves its task alive.
            if !childReaped { _ = kill(pid, SIGHUP) }
        }
    }

    deinit {
        stop()
        if master >= 0 { Darwin.close(master) }
        if !started {
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }
}
