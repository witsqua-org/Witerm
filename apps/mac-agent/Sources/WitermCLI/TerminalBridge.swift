import Darwin
import Foundation
import WitermCore

/// ssh-style escapes: the escape character counts only at the start of a
/// line, so it can still be typed anywhere else.
struct EscapeFilter {
    enum Event: Equatable { case send(Data), detach, help }

    let escape: UInt8?
    private var atLineStart = true
    private var pending = false

    init(escape: UInt8?) { self.escape = escape }

    mutating func feed(_ bytes: some Sequence<UInt8>) -> [Event] {
        var events: [Event] = []
        var buffer = Data()
        func flush() { if !buffer.isEmpty { events.append(.send(buffer)); buffer = Data() } }
        for byte in bytes {
            if pending, let escape {
                pending = false
                if byte == UInt8(ascii: ".") {
                    flush(); events.append(.detach); return events
                } else if byte == UInt8(ascii: "?") {
                    flush(); events.append(.help); atLineStart = true; continue
                } else if byte == escape {
                    buffer.append(byte)
                } else {
                    buffer.append(escape); buffer.append(byte)
                }
            } else if atLineStart, let escape, byte == escape {
                pending = true
                continue
            } else {
                buffer.append(byte)
            }
            atLineStart = byte == 13 || byte == 10
        }
        flush()
        return events
    }
}

/// Grid limits the service accepts.
func clampedGrid(columns: Int, rows: Int) -> (columns: Int, rows: Int) {
    (min(max(columns, 20), 500), min(max(rows, 5), 200))
}

/// Connects this terminal to an attached session until the user detaches or
/// the session ends. The terminal is always restored, however it exits.
final class TerminalBridge: @unchecked Sendable {
    enum Outcome: Equatable { case detached, ended }
    private enum Action { case input(Data), resize(Int, Int), detach, help }

    private let lock = NSLock()
    private var saved = termios()
    private var raw = false
    private var stopped = false
    private var detaching = false
    private let escape: UInt8?

    init(escape: UInt8?) { self.escape = escape }

    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    static func terminalSize() -> (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
            return (80, 24)
        }
        return clampedGrid(columns: Int(size.ws_col), rows: Int(size.ws_row))
    }

    func run(_ attachment: LocalTerminalAttachment, mode: LocalAttachmentMode) async throws -> Outcome {
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { throw CLIFailure(exit: .failure, code: "terminal", message: "Unable to read terminal settings.") }
        enterRaw()
        let (actions, sink) = AsyncStream<Action>.makeStream(bufferingPolicy: .unbounded)
        let signals = installSignals(sink)
        startReader(sink)
        defer {
            lock.withLock { stopped = true }
            sink.finish()
            signals.forEach { $0.cancel() }
            restore()
        }
        let events = attachment.events
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { [self] in
                for try await event in events {
                    if case .output(let data) = event { Self.write(data) }
                }
                return lock.withLock { detaching } ? .detached : .ended
            }
            group.addTask { [self] in
                for await action in actions {
                    switch action {
                    case .input(let data):
                        guard mode == .control else { continue }
                        var offset = 0
                        while offset < data.count {
                            let chunk = data.subdata(in: offset..<min(offset + 16_384, data.count))
                            try await attachment.send(chunk)
                            offset += chunk.count
                        }
                    case .resize(let columns, let rows):
                        if mode == .control { try await attachment.resize(columns: columns, rows: rows) }
                    case .help:
                        Self.write(Data(Self.helpText(escape).utf8))
                    case .detach:
                        lock.withLock { detaching = true }
                        try await attachment.detach()
                        return .detached
                    }
                }
                lock.withLock { detaching = true }
                try await attachment.detach()
                return .detached
            }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else { return .ended }
            return outcome
        }
    }

    static func helpText(_ escape: UInt8?) -> String {
        let key = escape.map { String(UnicodeScalar($0)) } ?? "~"
        return "\r\nWiterm escapes (after Enter):\r\n  \(key).  detach; the session keeps running\r\n  \(key)\(key)  type \(key)\r\n  \(key)?  this help\r\n"
    }

    // MARK: Terminal state

    private func enterRaw() {
        lock.withLock {
            var settings = saved
            cfmakeraw(&settings)
            raw = tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings) == 0
        }
    }

    /// Leaves raw mode and undoes modes a program in the session may have
    /// set: alternate screen, mouse reporting, bracketed paste, hidden cursor.
    private func restore() {
        Self.write(Data("\u{1B}[?1049l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?1l\u{1B}>\u{1B}[0m\u{1B}[?25h".utf8))
        lock.withLock {
            guard raw else { return }
            var settings = saved
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings)
            raw = false
        }
    }

    private func installSignals(_ sink: AsyncStream<Action>.Continuation) -> [DispatchSourceSignal] {
        var sources: [DispatchSourceSignal] = []
        func handle(_ number: Int32, _ action: @escaping @Sendable () -> Void) {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler(handler: action)
            source.resume()
            sources.append(source)
        }
        handle(SIGWINCH) {
            let size = Self.terminalSize()
            sink.yield(.resize(size.columns, size.rows))
        }
        for number in [SIGTERM, SIGHUP, SIGINT] { handle(number) { sink.yield(.detach) } }
        // A suspend from outside (raw mode never sends ^Z as a signal): give the
        // terminal back, stop, and take it again on continue.
        handle(SIGTSTP) { [self] in
            restore()
            kill(getpid(), SIGSTOP)
        }
        handle(SIGCONT) { [self] in
            enterRaw()
            let size = Self.terminalSize()
            sink.yield(.resize(size.columns, size.rows))
        }
        return sources
    }

    private func startReader(_ sink: AsyncStream<Action>.Continuation) {
        let escape = escape
        Thread.detachNewThread { [self] in
            var filter = EscapeFilter(escape: escape)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !lock.withLock({ stopped }) {
                var polled = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&polled, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                if ready <= 0 { if ready < 0 { break }; continue }
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { sink.yield(.detach); return }
                for event in filter.feed(buffer.prefix(count)) {
                    switch event {
                    case .send(let data): sink.yield(.input(data))
                    case .help: sink.yield(.help)
                    case .detach: sink.yield(.detach); return
                    }
                }
            }
        }
    }

    static func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(STDOUT_FILENO, base, remaining)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                base = base.advanced(by: count)
                remaining -= count
            }
        }
    }
}
