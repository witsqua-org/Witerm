import Darwin
import Foundation
import WitermCore

/// ssh-style escapes: the escape character counts only at the start of a
/// line, so it can still be typed anywhere else.
struct EscapeFilter {
    enum Event: Equatable { case send(Data), detach, help, toggleRemoteTyping }

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
                } else if byte == UInt8(ascii: "p") {
                    flush(); events.append(.toggleRemoteTyping); atLineStart = true; continue
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

/// Resolves once with whichever of input or output finishes the attachment.
private final class OutcomeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<TerminalBridge.Outcome, Error>?
    private var waiter: CheckedContinuation<Result<TerminalBridge.Outcome, Error>, Never>?

    func resolve(_ value: Result<TerminalBridge.Outcome, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Result<TerminalBridge.Outcome, Error>, Never>? in
            guard result == nil else { return nil }
            result = value
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: value)
    }

    var value: Result<TerminalBridge.Outcome, Error> {
        get async {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> Result<TerminalBridge.Outcome, Error>? in
                    if let result { return result }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

/// Connects this terminal to an attached session until the user detaches or
/// the session ends. The terminal is always restored, however it exits.
final class TerminalBridge: @unchecked Sendable {
    enum Outcome: Equatable { case detached, ended }
    private enum Action { case input(Data), resize(Int, Int), detach, help, toggleRemoteTyping }

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

    /// `toggleRemoteTyping` pauses or resumes typing from paired devices in
    /// this session and returns whether they may type afterwards.
    func run(_ attachment: LocalTerminalAttachment, mode: LocalAttachmentMode,
             toggleRemoteTyping: (@Sendable () async throws -> Bool)? = nil) async throws -> Outcome {
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { throw CLIFailure(exit: .failure, code: "terminal", message: "Unable to read terminal settings.") }
        let (actions, sink) = AsyncStream<Action>.makeStream(bufferingPolicy: .unbounded)
        // Handlers exist before raw mode, so a signal can never leave it behind.
        let signals = installSignals(sink)
        defer { signals.forEach { $0.cancel() } }
        enterRaw()
        startReader(sink)
        let finished = OutcomeLatch()
        let writer = CLIStreamWriter { [self] result in
            // Once detaching, only its ACK/error may finish the command.
            guard !lock.withLock({ detaching }) else { return }
            finished.resolve(result.map { .ended })
        }
        let events = attachment.events
        let output = Task.detached { [self] in
            do {
                for try await event in events {
                    if case .output(let data) = event, !lock.withLock({ detaching }) { try writer.append(data) }
                }
                if !lock.withLock({ detaching }) { writer.finish() }
            } catch {
                if !lock.withLock({ detaching }) { finished.resolve(.failure(error)) }
            }
        }
        let input = Task { [self] in
            do {
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
                        CLIOutput.standardOutput.write(Data(Self.helpText(escape).utf8))
                    case .toggleRemoteTyping:
                        // A failed change leaves the session as it was and says so.
                        let message: String
                        if let toggleRemoteTyping, let typing = try? await toggleRemoteTyping() {
                            message = typing ? "[paired devices may type again]" : "[paired devices are view only in this session]"
                        } else {
                            message = "[remote typing unchanged]"
                        }
                        CLIOutput.standardOutput.write(Data("\r\n\(message)\r\n".utf8))
                    case .detach:
                        try await detach(attachment, writer: writer)
                        finished.resolve(.success(.detached))
                        return
                    }
                }
                try await detach(attachment, writer: writer)
                finished.resolve(.success(.detached))
            } catch { finished.resolve(.failure(error)) }
        }
        let result = await finished.value
        lock.withLock { stopped = true }
        sink.finish()
        writer.stop()
        restore()
        input.cancel()
        output.cancel()
        return try result.get()
    }

    /// The terminal comes back before waiting on the service, so a signal or
    /// `~.` restores it at once even if the detach is slow.
    private func detach(_ attachment: LocalTerminalAttachment, writer: CLIStreamWriter) async throws {
        lock.withLock { detaching = true }
        writer.stop()
        restore()
        try await attachment.detach()
    }

    static func helpText(_ escape: UInt8?) -> String {
        let key = escape.map { String(UnicodeScalar($0)) } ?? "~"
        return "\r\nWiterm escapes (after Enter):\r\n  \(key).  detach; the session keeps running\r\n  \(key)p  pause or resume typing from paired devices\r\n  \(key)\(key)  type \(key)\r\n  \(key)?  this help\r\n"
    }

    // MARK: Terminal state

    private func enterRaw() {
        lock.withLock {
            // Never again once leaving: a late SIGCONT must not re-enter raw mode.
            guard !raw, !detaching, !stopped else { return }
            var settings = saved
            cfmakeraw(&settings)
            // TCSAFLUSH waits for output to drain before changing modes. A
            // terminal already full at attach (or resume) would block here,
            // before the queued termination action can ever run.
            // Preserve TCSAFLUSH's input-discard behavior without its output
            // drain. Flush before entering raw mode, so newly delivered raw
            // input can never be discarded by a subsequent flush.
            var result: Int32
            repeat { result = tcflush(STDIN_FILENO, TCIFLUSH) } while result < 0 && errno == EINTR
            repeat { result = tcsetattr(STDIN_FILENO, TCSANOW, &settings) } while result < 0 && errno == EINTR
            raw = result == 0
        }
    }

    /// Leaves raw mode at once, without waiting for output to drain, then
    /// undoes modes a program in the session may have set: alternate screen,
    /// mouse reporting, bracketed paste, hidden cursor.
    private func restore() {
        let restored = lock.withLock { () -> Bool in
            guard raw else { return false }
            var settings = saved
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &settings)
            raw = false
            return true
        }
        guard restored else { return }
        CLIOutput.standardOutput.write(Data("\u{1B}[?1049l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?1l\u{1B}>\u{1B}[0m\u{1B}[?25h".utf8))
    }

    private func installSignals(_ sink: AsyncStream<Action>.Continuation) -> [DispatchSourceSignal] {
        var sources: [DispatchSourceSignal] = []
        func handle(_ number: Int32, _ action: @escaping @Sendable () -> Void) {
            // Listen first, then drop the default action, so no signal falls
            // between the two.
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler(handler: action)
            source.resume()
            signal(number, SIG_IGN)
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
                    case .toggleRemoteTyping: sink.yield(.toggleRemoteTyping)
                    case .detach: sink.yield(.detach); return
                    }
                }
            }
        }
    }

}
