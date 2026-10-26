import Darwin
import Foundation

enum Posix {
    static func noSignalPipe(_ fd: Int32) {
        var flag: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout.size(ofValue: flag)))
    }

    static func closeOnExec(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { throw AgentFailure() }
    }

    static func nonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { throw AgentFailure() }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw AgentFailure() }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes + [0])
        }
        return address
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    static func writeAll(_ fd: Int32, data: Data, timeout: TimeInterval = 2) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 50) < 0 && errno != EINTR { return false }
            }
            return true
        }
    }

    // All allocations and file actions are prepared in the parent. Darwin
    // posix_spawn performs the child transition; no forked Swift/Foundation code.
    static func spawn(executable: String, arguments: [String], environment: [String: String], input: Int32?, output: Int32?, tty: Bool) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw AgentFailure() }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        func checked(_ value: Int32) throws { if value != 0 { throw AgentFailure() } }
        if let input { try checked(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)) }
        else { try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)) }
        if let output { try checked(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)) }
        else { try checked(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)) }
        if tty, let output { try checked(posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO)) }
        else { try checked(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)) }
        var defaults = sigset_t()
        var mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if tty { flags |= Int16(POSIX_SPAWN_SETSID) }
        try checked(posix_spawnattr_setflags(&attributes, flags))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try checked(error)
        return pid
    }
}

struct CommandResult {
    let status: Int32
    let output: Data
}

struct CommandRunner {
    let executable: String
    let environment: [String: String]

    func run(_ arguments: [String], timeout: TimeInterval = 3) throws -> CommandResult {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw AgentFailure() }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { Darwin.close(readFD) }
        do {
            try Posix.closeOnExec(readFD); try Posix.closeOnExec(writeFD)
            try Posix.nonblocking(readFD)
        } catch { Darwin.close(writeFD); throw error }
        let pid: pid_t
        do { pid = try Posix.spawn(executable: executable, arguments: arguments, environment: environment, input: nil, output: writeFD, tty: false) }
        catch { Darwin.close(writeFD); throw error }
        Darwin.close(writeFD)
        var output = Data(), status: Int32 = 0
        var exited = false, eof = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        defer {
            if !exited {
                _ = kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        while !exited || !eof {
            let count = Darwin.read(readFD, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= 65536 else { throw AgentFailure() }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw AgentFailure() }
            if !exited {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { exited = true }
                else if result < 0 && errno != EINTR {
                    // Never signal a PID that another reaper may already have
                    // released back to the process table.
                    if errno == ECHILD { exited = true }
                    throw AgentFailure()
                }
            }
            if exited && eof { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AgentFailure() }
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            if count <= 0 { _ = poll(&descriptor, 1, 20) }
        }
        return CommandResult(status: status, output: output)
    }
}
