import Darwin
import Foundation
import WitermCore

/// `witerm orbit serve`: Orbit's process. Witerm starts it when Orbit is
/// opened; it serves the app and `witerm mcp` on `orbit.sock` (mode 0600 in
/// a 0700 folder, peers checked to be this user), keeps running while a
/// thread runs, and exits after 15 minutes with nothing running and no
/// requests. One instance per folder, by `orbit.lock`. It never logs
/// messages, terminal text, or the API key, which it holds only in memory.
enum OrbitDaemon {
    static let idleExit: Duration = .seconds(15 * 60)

    /// `WITERM_ORBIT_OPENAI_URL`, for development and tests: another
    /// Responses endpoint, HTTPS or on this Mac only.
    static func endpoint(environment: [String: String]) -> URL {
        guard let raw = environment["WITERM_ORBIT_OPENAI_URL"], let url = URL(string: raw),
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")) else {
            return OpenAIResponses.endpoint
        }
        return url
    }

    static func serve(directory: URL, agentSocket: URL, endpoint: URL = OpenAIResponses.endpoint) async throws -> Never {
        _ = umask(0o077)
        _ = setsid()
        try privateDirectory(directory)
        let lock = open(directory.appendingPathComponent("orbit.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CLIFailure(exit: .failure, code: "orbit_lock", message: "Orbit couldn't start.") }
        // Another Orbit already serves this folder.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(CLIExit.success.rawValue) }
        let store = OrbitStore(directory: directory)
        try store.prepare()
        let engine = OrbitEngine(store: store, terminals: LocalAgentClient(socketURL: agentSocket),
                                 api: OpenAIResponses(endpoint: endpoint))
        let listener = try listen(at: directory.appendingPathComponent(OrbitPaths.socketName))
        Thread.detachNewThread { accept(listener, engine: engine) }
        while true {
            try? await Task.sleep(for: .seconds(30))
            let (running, last) = (await engine.runningCount, await engine.lastRequest)
            if running == 0, ContinuousClock.now - last > idleExit {
                unlink(directory.appendingPathComponent(OrbitPaths.socketName).path)
                exit(CLIExit.success.rawValue)
            }
        }
    }

    /// A folder only this user can enter, never a symlink.
    static func privateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw unsafe }
            guard lstat(url.path, &info) == 0 else { throw unsafe }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw unsafe }
        if info.st_mode & 0o077 != 0 { guard chmod(url.path, 0o700) == 0 else { throw unsafe } }
    }

    private static var unsafe: CLIFailure {
        CLIFailure(exit: .failure, code: "orbit_unsafe", message: "Orbit's folder failed a safety check.")
    }

    private static func listen(at socket: URL) throws -> Int32 {
        // The lock is held, so a socket left here is a dead instance's.
        unlink(socket.path)
        var address = sockaddr_un()
        let bytes = Array(socket.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw unsafe }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let descriptor = socket_(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw unsafe }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socket.path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw unsafe
        }
        return descriptor
    }

    private static func socket_(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
        Darwin.socket(domain, type, proto)
    }

    private static func accept(_ listener: Int32, engine: OrbitEngine) {
        while true {
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                exit(CLIExit.failure.rawValue)
            }
            Thread.detachNewThread { serve(connection, engine: engine) }
        }
    }

    /// One request line, one reply line, then the connection closes.
    private static func serve(_ connection: Int32, engine: OrbitEngine) {
        defer { close(connection) }
        _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(connection, &user, &group) == 0, user == geteuid() else { return }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !line.contains(0x0a) {
            let count = read(connection, &buffer, buffer.count)
            if count > 0 {
                line.append(contentsOf: buffer[0..<count])
                guard line.count <= OrbitWire.lineLimit else { return }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
        let body = line.prefix { $0 != 0x0a }
        let reply = Locked<Data>(Data())
        let done = DispatchSemaphore(value: 0)
        Task {
            let response: OrbitResponse
            if let request = try? OrbitWire.decoder().decode(OrbitRequest.self, from: body) {
                response = await engine.handle(request)
            } else {
                let id = (try? JSONDecoder().decode(JSONValue.self, from: body))?["id"]?.string
                response = OrbitResponse(id: id, ok: false, error: .invalidRequest)
            }
            reply.set((try? OrbitWire.encoder().encode(response)) ?? Data())
            done.signal()
        }
        done.wait()
        var data = reply.get()
        data.append(0x0a)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(connection, base.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count } else if count < 0, errno == EINTR { continue } else { return }
            }
        }
    }
}

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}
