import Foundation
import Darwin
@preconcurrency import Citadel
import NIO

enum SSHFilePolicy {
    static let chunkSize = 64 * 1024
    static let maximumBytes: UInt64 = 1 << 40

    static func validate(path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SSHFailure.invalidPath }
    }

    static func validate(localURL: URL) throws {
        guard localURL.isFileURL, localURL.host == nil || localURL.host == "localhost",
              !localURL.path.isEmpty else { throw SSHFailure.invalidPath }
    }

    static func childPath(parent: String, name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SSHFailure.invalidPath
        }
        let value = (parent == "/" ? "/" : parent + "/") + name
        try validate(path: value)
        return value
    }
}

extension SSHConnection {
    // A short-lived subsystem per operation avoids retaining server file handles
    // after a cancelled transfer or a directory request. Closing it interrupts a
    // stalled request; cancellation never queues a replay on a new connection.
    private func withSFTP<T: Sendable>(
        _ body: @escaping @Sendable (SFTPClient) async throws -> T
    ) async throws -> T {
        try requireConnected()
        let sftp = try await client.openSFTP()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let result = try await body(sftp)
                try Task.checkCancellation()
                try await sftp.close()
                return result
            } catch {
                try? await sftp.close()
                throw error
            }
        } onCancel: {
            Task { try? await sftp.close() }
        }
    }

    public func listDirectory(path: String) async throws -> [SSHFileEntry] {
        try SSHFilePolicy.validate(path: path)
        return try await withSFTP { sftp in
            let canonical = try await sftp.getRealPath(atPath: path)
            try SSHFilePolicy.validate(path: canonical)
            let batches = try await sftp.listDirectory(atPath: canonical, maximumEntries: 10_000)
            return try batches.flatMap(\.components).compactMap { item in
                guard item.filename != ".", item.filename != ".." else { return nil }
                return SSHFileEntry(
                    name: item.filename,
                    path: try SSHFilePolicy.childPath(parent: canonical, name: item.filename),
                    isDirectory: item.attributes.permissions.map { $0 & 0o170000 == 0o040000 } ?? false,
                    size: item.attributes.size
                )
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    public func createDirectory(path: String) async throws {
        try SSHFilePolicy.validate(path: path)
        try await withSFTP { sftp in
            var attributes = SFTPFileAttributes()
            attributes.permissions = 0o700
            try await sftp.createDirectory(atPath: path, attributes: attributes)
        }
    }

    /// Removes one file or an empty directory. Recursive deletion is deliberately
    /// unavailable so a user-selected item cannot expand to an unseen tree.
    public func remove(path: String, isDirectory: Bool) async throws {
        try SSHFilePolicy.validate(path: path)
        guard path != "/", path != ".", path != ".." else { throw SSHFailure.invalidPath }
        try await withSFTP { sftp in
            if isDirectory { try await sftp.rmdir(at: path) }
            else { try await sftp.remove(at: path) }
        }
    }

    public func download(
        remotePath: String,
        to localURL: URL,
        progress: @escaping @Sendable (UInt64, UInt64?) -> Void = { _, _ in }
    ) async throws {
        try SSHFilePolicy.validate(path: remotePath)
        try SSHFilePolicy.validate(localURL: localURL)
        let temporary = localURL.deletingLastPathComponent()
            .appendingPathComponent(".witerm-\(UUID().uuidString).part")
        let fd = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw SSHFailure.storageUnavailable }
        let destination = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? destination.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try await withSFTP { sftp in
            let file = try await sftp.openFile(filePath: remotePath, flags: .read)
            do {
                let total = try await file.readAttributes().size
                if let total, total > SSHFilePolicy.maximumBytes { throw SSHFailure.transferTooLarge }
                var offset: UInt64 = 0
                progress(0, total)
                while true {
                    try Task.checkCancellation()
                    let bytes = try await file.read(from: offset, length: UInt32(SSHFilePolicy.chunkSize))
                    guard bytes.readableBytes > 0 else { break }
                    guard bytes.readableBytes <= SSHFilePolicy.chunkSize,
                          UInt64(bytes.readableBytes) <= SSHFilePolicy.maximumBytes - offset else {
                        throw SSHFailure.transferTooLarge
                    }
                    try destination.write(contentsOf: Data(bytes.readableBytesView))
                    offset += UInt64(bytes.readableBytes)
                    progress(offset, total)
                }
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        }
        try Task.checkCancellation()
        try destination.synchronize()
        try destination.close()
        // link(2) publishes atomically and fails for an existing file or symlink;
        // a check-then-rename must not silently replace an intervening user file.
        let linked = temporary.path.withCString { source in
            localURL.path.withCString { target in Darwin.link(source, target) }
        }
        guard linked == 0 else { throw SSHFailure.storageUnavailable }
    }

    public func upload(
        localURL: URL,
        to remotePath: String,
        progress: @escaping @Sendable (UInt64, UInt64?) -> Void = { _, _ in }
    ) async throws {
        try SSHFilePolicy.validate(localURL: localURL)
        try SSHFilePolicy.validate(path: remotePath)
        let attributes = try localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true else { throw SSHFailure.invalidPath }
        let total = attributes.fileSize.map(UInt64.init)
        if let total, total > SSHFilePolicy.maximumBytes { throw SSHFailure.transferTooLarge }
        let source = try FileHandle(forReadingFrom: localURL)
        defer { try? source.close() }
        // Creation is exclusive on the server. Never truncate an existing path.
        // A failed/cancelled transfer removes only the path created by this call;
        // disconnected servers can still retain that partial file until cleanup.
        try await withSFTP { sftp in
            var attributes = SFTPFileAttributes()
            attributes.permissions = 0o600
            let file = try await sftp.openFile(
                filePath: remotePath, flags: [.write, .create, .forceCreate], attributes: attributes)
            do {
                var offset: UInt64 = 0
                progress(0, total)
                while true {
                    try Task.checkCancellation()
                    let data = try source.read(upToCount: SSHFilePolicy.chunkSize) ?? Data()
                    guard !data.isEmpty else { break }
                    guard UInt64(data.count) <= SSHFilePolicy.maximumBytes - offset else {
                        throw SSHFailure.transferTooLarge
                    }
                    try await file.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                    progress(offset, total)
                }
                try await file.close()
            } catch {
                try? await file.close()
                if sftp.isActive {
                    try? await sftp.remove(at: remotePath)
                } else {
                    // Cancellation closed the stalled subsystem. A fresh one is
                    // used only for deletion, never to resume/replay file bytes.
                    let cleanup = try? await self.client.openSFTP()
                    try? await cleanup?.remove(at: remotePath)
                    try? await cleanup?.close()
                }
                throw error
            }
        }
    }
}
