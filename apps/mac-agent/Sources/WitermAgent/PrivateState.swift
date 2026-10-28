import Darwin
import Foundation
import WitermCore

final class PrivateState {
    let directory: URL
    let socketURL: URL
    let tmuxSocketURL: URL
    private var lockFD: Int32 = -1

    init(directory requested: URL) throws {
        let fm = FileManager.default
        // Resolve normal system aliases in ancestors, but never follow a link
        // at the requested state directory itself.
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        directory = parent.appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        socketURL = directory.appendingPathComponent("agent.sock")
        tmuxSocketURL = directory.appendingPathComponent("tmux.sock")
        _ = try Posix.address(socketURL.path)
        _ = try Posix.address(tmuxSocketURL.path)
        var existing = stat()
        if lstat(directory.path, &existing) != 0 {
            guard errno == ENOENT else { throw AgentFailure() }
            do { try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { throw AgentFailure() }
        }
        guard lstat(directory.path, &existing) == 0,
              existing.st_mode & S_IFMT == S_IFDIR, existing.st_uid == geteuid(),
              existing.st_mode & 0o7777 == 0o700 else { throw AgentFailure() }
        let lockURL = directory.appendingPathComponent("agent.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentFailure() }
        var lockStat = stat()
        guard fstat(fd, &lockStat) == 0, lockStat.st_uid == geteuid(), lockStat.st_mode & S_IFMT == S_IFREG,
              lockStat.st_mode & 0o7777 == 0o600, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw AgentFailure()
        }
        lockFD = fd
    }

    deinit { if lockFD >= 0 { Darwin.close(lockFD) } }

    func removeStaleSocket() throws {
        var value = stat()
        if lstat(socketURL.path, &value) != 0 {
            if errno == ENOENT { return }; throw AgentFailure()
        }
        guard value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFSOCK, value.st_mode & 0o7777 == 0o600 else { throw AgentFailure() }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentFailure() }
        defer { Darwin.close(descriptor) }
        try Posix.nonblocking(descriptor)
        var address = try Posix.address(socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // The lock cannot justify removing an unrelated live listener.
        guard result != 0, errno == ECONNREFUSED else { throw AgentFailure() }
        guard unlink(socketURL.path) == 0 else { throw AgentFailure() }
    }

    func validateTmuxSocket() throws {
        var value = stat()
        if lstat(tmuxSocketURL.path, &value) != 0 {
            if errno == ENOENT { return }; throw AgentFailure()
        }
        guard value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFSOCK else { throw AgentFailure() }
    }

    func tmuxServerIsAbsent() throws -> Bool {
        var before = stat()
        if lstat(tmuxSocketURL.path, &before) != 0 {
            if errno == ENOENT { return true }
            throw AgentFailure()
        }
        guard before.st_uid == geteuid(), before.st_mode & S_IFMT == S_IFSOCK else { throw AgentFailure() }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentFailure() }
        defer { Darwin.close(descriptor) }
        try Posix.closeOnExec(descriptor)
        try Posix.nonblocking(descriptor)
        var address = try Posix.address(tmuxSocketURL.path)
        let outcome = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> (Int32, Int32) in
                let result = connect(descriptor, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                return (result, errno)
            }
        }
        if outcome.0 == 0 {
            guard Posix.sameUser(descriptor) else { throw AgentFailure() }
            return false
        }
        // In-progress/backlogged/other failures cannot prove that tasks ended.
        guard outcome.1 == ECONNREFUSED || outcome.1 == ENOENT else { return false }
        var after = stat()
        if lstat(tmuxSocketURL.path, &after) != 0 {
            if errno == ENOENT { return true }
            throw AgentFailure()
        }
        guard after.st_uid == geteuid(), after.st_mode & S_IFMT == S_IFSOCK else { throw AgentFailure() }
        // An endpoint replacement during the probe is deliberately ambiguous.
        return outcome.1 == ECONNREFUSED && before.st_dev == after.st_dev && before.st_ino == after.st_ino
    }

    func loadMetadata() throws -> [String: LocalSessionInfo] {
        let path = directory.appendingPathComponent("sessions.json")
        var value = stat()
        if lstat(path.path, &value) != 0 {
            if errno == ENOENT { return [:] }; throw AgentFailure()
        }
        guard value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o7777 == 0o600, value.st_size <= 65536 else { throw AgentFailure() }
        let data = try Data(contentsOf: path)
        let records = try wireDecoder().decode([LocalSessionInfo].self, from: data)
        guard records.count <= 16, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ validSessionID($0.id) && validDimensions(columns: $0.columns, rows: $0.rows) }) else { throw AgentFailure() }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func saveMetadata(_ records: [String: LocalSessionInfo]) throws {
        try replace("sessions.json", with: wireEncoder().encode(records.values.sorted { $0.id < $1.id }))
    }

    /// Sessions shared with paired devices. A missing file shares nothing, so
    /// sessions from before sharing existed stay private until shared.
    func loadSharing() throws -> Set<String> {
        let path = directory.appendingPathComponent("sharing.json")
        var value = stat()
        if lstat(path.path, &value) != 0 {
            if errno == ENOENT { return [] }; throw AgentFailure()
        }
        guard value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o7777 == 0o600, value.st_size <= 4096 else { throw AgentFailure() }
        let ids = try JSONDecoder().decode([String].self, from: Data(contentsOf: path))
        guard ids.count <= 16, ids.allSatisfy(validSessionID) else { throw AgentFailure() }
        return Set(ids)
    }

    func saveSharing(_ ids: Set<String>) throws {
        try replace("sharing.json", with: JSONEncoder().encode(ids.sorted()))
    }

    /// Sessions no paired device may reach, even one allowed every session.
    func loadPrivate() throws -> Set<String> {
        guard let data = try readPrivateFile("private.json", limit: 4096) else { return [] }
        let ids = try JSONDecoder().decode([String].self, from: data)
        guard ids.count <= 16, ids.allSatisfy(validSessionID) else { throw AgentFailure() }
        return Set(ids)
    }

    func savePrivate(_ ids: Set<String>) throws {
        try replace("private.json", with: JSONEncoder().encode(ids.sorted()))
    }

    /// This Mac's policy for each paired device. A device without an entry
    /// reaches shared sessions only.
    func loadDeviceAccess() throws -> [String: LocalDeviceAccess] {
        guard let data = try readPrivateFile("device-access.json", limit: 16384) else { return [:] }
        let entries = try JSONDecoder().decode([LocalDeviceAccess].self, from: data)
        guard entries.count <= 64, Set(entries.map(\.deviceID)).count == entries.count,
              entries.allSatisfy({ validSessionID($0.deviceID) }) else { throw AgentFailure() }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.deviceID, $0) })
    }

    func saveDeviceAccess(_ entries: [String: LocalDeviceAccess]) throws {
        try replace("device-access.json", with: JSONEncoder().encode(entries.values.sorted { $0.deviceID < $1.deviceID }))
    }

    /// Invitations to single sessions, with proof keys until redeemed.
    func loadGuests() throws -> [String: LocalGuestInvite] {
        guard let data = try readPrivateFile("guests.json", limit: 65536) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([LocalGuestInvite].self, from: data)
        guard entries.count <= 96, Set(entries.map(\.pairingID)).count == entries.count,
              entries.allSatisfy({ validSessionID($0.pairingID) && validSessionID($0.sessionID) }) else { throw AgentFailure() }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.pairingID, $0) })
    }

    func saveGuests(_ entries: [String: LocalGuestInvite]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try replace("guests.json", with: encoder.encode(entries.values.sorted { $0.pairingID < $1.pairingID }))
    }

    /// A regular 0600 file owned by this user, or nil when it doesn't exist.
    private func readPrivateFile(_ name: String, limit: Int) throws -> Data? {
        let path = directory.appendingPathComponent(name)
        var value = stat()
        if lstat(path.path, &value) != 0 {
            if errno == ENOENT { return nil }; throw AgentFailure()
        }
        guard value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o7777 == 0o600, value.st_size <= limit else { throw AgentFailure() }
        return try Data(contentsOf: path)
    }

    private func replace(_ name: String, with data: Data) throws {
        let temporary = directory.appendingPathComponent(".\(name)-\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentFailure() }
        defer { Darwin.close(fd); _ = unlink(temporary.path) }
        guard Posix.writeAll(fd, data: data), fsync(fd) == 0,
              rename(temporary.path, directory.appendingPathComponent(name).path) == 0 else { throw AgentFailure() }
    }
}
