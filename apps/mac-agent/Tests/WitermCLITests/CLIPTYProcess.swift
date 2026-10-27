import Darwin
import Foundation
import XCTest

/// A real terminal whose output the test can deliberately stop reading.
@MainActor
final class CLIPTYProcess {
    let process = Process()
    private var master: Int32
    private var slave: Int32
    private let original: termios
    private var captured = Data()

    init(binary: URL, arguments: [String], environment: [String: String], stderr: Int32? = nil,
         blockOutputBeforeLaunch: Bool = false, inputBeforeLaunch: String? = nil) throws {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw FixtureError.system }
        self.master = master
        self.slave = slave
        var settings = termios()
        guard tcgetattr(slave, &settings) == 0 else {
            close(master); close(slave); throw FixtureError.system
        }
        original = settings
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: stderr ?? slave, closeOnDealloc: false)
        do {
            if blockOutputBeforeLaunch { try fillOutput() }
            if let inputBeforeLaunch { try send(inputBeforeLaunch) }
            try process.run()
        } catch {
            close(master); close(slave)
            self.master = -1; self.slave = -1
            throw error
        }
    }

    func stop() {
        // Cleanup only. Every test must assert timely exit before reaching here.
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        close(master); close(slave)
    }

    func send(_ text: String) throws {
        let data = Data(text.utf8)
        guard data.withUnsafeBytes({ write(master, $0.baseAddress!, $0.count) }) == data.count else {
            throw FixtureError.system
        }
    }

    func waitFor(_ text: String, timeout: Duration = .seconds(5)) async throws -> Bool {
        let marker = Data(text.utf8), deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            drain()
            if captured.range(of: marker) != nil { return true }
            if !process.isRunning { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func waitForRaw() async throws -> Bool {
        for _ in 0..<200 {
            var settings = termios()
            if tcgetattr(slave, &settings) == 0, settings.c_lflag & tcflag_t(ICANON | ECHO) == 0 { return true }
            if !process.isRunning { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// No terminal reads here: an exit that depends on draining must fail.
    func waitForExit(timeout: Duration = .seconds(3)) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return !process.isRunning
    }

    var terminalRestored: Bool {
        var after = termios(), before = original
        guard tcgetattr(slave, &after) == 0,
              after.c_iflag == before.c_iflag, after.c_oflag == before.c_oflag,
              after.c_cflag == before.c_cflag,
              // Darwin may set PENDIN itself when restoring canonical input;
              // it describes pending type-ahead, not a changed terminal setting.
              after.c_lflag & ~tcflag_t(PENDIN) == before.c_lflag & ~tcflag_t(PENDIN),
              cfgetispeed(&after) == cfgetispeed(&before), cfgetospeed(&after) == cfgetospeed(&before) else { return false }
        return withUnsafeBytes(of: after.c_cc) { a in withUnsafeBytes(of: before.c_cc) { b in a.elementsEqual(b) } }
    }

    var terminalSettingsSummary: String {
        var after = termios()
        let result = tcgetattr(slave, &after)
        return "tcgetattr=\(result), flags=\(after.c_iflag)/\(after.c_oflag)/\(after.c_cflag)/\(after.c_lflag), "
            + "expected=\(original.c_iflag)/\(original.c_oflag)/\(original.c_cflag)/\(original.c_lflag)"
    }

    /// Open a separate nonblocking description; never change the CLI's flags.
    func fillOutput() throws {
        var name = [CChar](repeating: 0, count: 1024)
        guard ttyname_r(slave, &name, name.count) == 0 else { throw FixtureError.system }
        let fd = open(name, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureError.system }
        defer { close(fd) }
        try Self.fill(fd)
    }

    static func fill(_ descriptor: Int32) throws {
        let bytes = [UInt8](repeating: 120, count: 4096)
        for _ in 0..<1024 {
            let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress!, $0.count) }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw FixtureError.system }
        }
        throw FixtureError.didNotBlock
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = read(master, &bytes, bytes.count)
            guard count > 0 else { return }
            captured.append(contentsOf: bytes.prefix(count))
            if captured.count > 65_536 { captured = captured.suffix(65_536) }
        }
    }

    enum FixtureError: Error { case system, didNotBlock }
}
