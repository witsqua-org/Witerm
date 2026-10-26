import Crypto
import Foundation
import Security
import LocalAuthentication

protocol SSHSecretStorage: Sendable {
    func read(_ account: String) throws -> Data?
    func create(_ data: Data, account: String) throws -> Bool
    func write(_ data: Data, account: String) throws
    func delete(_ account: String) throws
}

struct SSHKeychainStorage: SSHSecretStorage {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.witerm.ssh.v1",
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw SSHFailure.storageUnavailable }
        return data
    }
    func create(_ data: Data, account: String) throws -> Bool {
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary, nil)
        if result == errSecDuplicateItem { return false }
        guard result == errSecSuccess else { throw SSHFailure.storageUnavailable }
        return true
    }
    func write(_ data: Data, account: String) throws {
        let result = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            if try !create(data, account: account) {
                guard SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
                    throw SSHFailure.storageUnavailable
                }
            }
        } else if result != errSecSuccess { throw SSHFailure.storageUnavailable }
    }
    func delete(_ account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw SSHFailure.storageUnavailable }
    }
}

public actor SSHKnownHosts {
    private static let trustLock = NSRecursiveLock()
    private let secrets: any SSHSecretStorage
    public init() throws { secrets = SSHKeychainStorage() }
    init(secrets: any SSHSecretStorage) { self.secrets = secrets }

    private func account(_ authority: String) -> String {
        "host-" + SHA256.hash(data: Data(authority.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func validate(_ key: SSHHostKey) throws {
        guard !key.authority.isEmpty, key.authority == key.authority.lowercased(),
              key.authority.utf8.count <= 300,
              let data = Data(base64Encoded: key.publicKey), data.count >= 5, data.count <= 16_384,
              data.base64EncodedString() == key.publicKey else { throw SSHFailure.hostKeyRejected }
        let bytes = [UInt8](data)
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length < 128, length + 4 <= data.count,
              String(data: data.subdata(in: 4..<(length + 4)), encoding: .utf8) == key.algorithm,
              key.fingerprint == "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        else { throw SSHFailure.hostKeyRejected }
    }
    public func status(for key: SSHHostKey) throws -> SSHHostKeyStatus {
        Self.trustLock.lock(); defer { Self.trustLock.unlock() }
        try validate(key)
        guard let data = try secrets.read(account(key.authority)) else { return .unknown }
        guard let stored = try? JSONDecoder().decode(SSHHostKey.self, from: data), stored.authority == key.authority else {
            throw SSHFailure.storageUnavailable
        }
        try validate(stored)
        return stored.publicKey == key.publicKey && stored.algorithm == key.algorithm
            ? .trusted : .changed(previousFingerprint: stored.fingerprint)
    }
    public func trust(_ key: SSHHostKey) throws {
        Self.trustLock.lock(); defer { Self.trustLock.unlock() }
        try validate(key)
        switch try status(for: key) {
        case .trusted: return
        case .changed: throw SSHFailure.hostKeyChanged
        case .unknown:
            if try !secrets.create(JSONEncoder().encode(key), account: account(key.authority)) {
                guard try status(for: key) == .trusted else { throw SSHFailure.hostKeyChanged }
            }
        }
    }
    public func storedKey(authority: String) throws -> SSHHostKey? {
        Self.trustLock.lock(); defer { Self.trustLock.unlock() }
        guard let data = try secrets.read(account(authority)) else { return nil }
        guard let key = try? JSONDecoder().decode(SSHHostKey.self, from: data), key.authority == authority else {
            throw SSHFailure.storageUnavailable
        }
        try validate(key)
        return key
    }
    /// Explicit trust removal, never a replacement operation. The UI must show
    /// the current fingerprint and require confirmation; concurrent changes fail.
    public func forget(authority: String, expectedFingerprint: String) throws {
        Self.trustLock.lock(); defer { Self.trustLock.unlock() }
        guard let key = try storedKey(authority: authority) else { return }
        guard key.fingerprint == expectedFingerprint else { throw SSHFailure.hostKeyChanged }
        try secrets.delete(account(authority))
    }
}

private struct StoredSSHCredential: Codable {
    var kind: String
    var value: String
    var passphrase: String?
    init(_ value: SSHCredential) throws {
        switch value {
        case .password(let password):
            guard password.utf8.count <= 65_536 else { throw SSHFailure.invalidConfiguration }
            kind = "password"; self.value = password
        case .privateKey(let key, let passphrase):
            guard key.utf8.count <= 262_144, (passphrase?.utf8.count ?? 0) <= 65_536 else { throw SSHFailure.invalidConfiguration }
            kind = "key"; self.value = key; self.passphrase = passphrase
        }
    }
    func credential() throws -> SSHCredential {
        switch kind {
        case "password": return .password(value)
        case "key": return .privateKey(value, passphrase: passphrase)
        default: throw SSHFailure.storageUnavailable
        }
    }
}

public actor SSHProfileStore {
    // UI actions may create separate actor instances for the same file. This
    // recursive lock covers the complete read/modify/write transaction, not
    // merely each instance's independent actor executor.
    private static let diskLock = NSRecursiveLock()
    private let url: URL
    private let secrets: any SSHSecretStorage
    public init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: true).appendingPathComponent("Witerm/SSH", isDirectory: true)
        url = base.appendingPathComponent("profiles.json")
        secrets = SSHKeychainStorage()
        try Self.prepare(base)
    }
    init(directory: URL, secrets: any SSHSecretStorage) throws {
        url = directory.appendingPathComponent("profiles.json")
        self.secrets = secrets
        try Self.prepare(directory)
    }
    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw SSHFailure.storageUnavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public func profiles() throws -> [SSHProfile] {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1_048_576 else {
            throw SSHFailure.storageUnavailable
        }
        let profiles = try JSONDecoder().decode([SSHProfile].self, from: Data(contentsOf: url))
        guard profiles.count <= 200, Set(profiles.map(\.id)).count == profiles.count else { throw SSHFailure.storageUnavailable }
        for profile in profiles { try profile.validate() }
        return profiles
    }
    private func write(_ values: [SSHProfile]) throws {
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ profile: SSHProfile) throws {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        try profile.validate()
        var values = try profiles()
        let allHosts = values.flatMap { $0.jumpHosts + [$0.host] }
        for host in profile.jumpHosts + [profile.host] {
            guard !values.filter({ $0.id != profile.id }).flatMap({ $0.jumpHosts + [$0.host] })
                .contains(where: { $0.id == host.id && $0 != host }) else { throw SSHFailure.invalidConfiguration }
            if allHosts.contains(where: { $0.id == host.id && $0 != host }) {
                try secrets.delete("credential-\(host.id.uuidString)")
            }
        }
        if let index = values.firstIndex(where: { $0.id == profile.id }) { values[index] = profile }
        else {
            guard values.count < 200 else { throw SSHFailure.invalidConfiguration }
            values.append(profile)
        }
        let retained = Set(values.flatMap { $0.jumpHosts + [$0.host] }.map(\.id))
        for id in Set(allHosts.map(\.id)).subtracting(retained) {
            try secrets.delete("credential-\(id.uuidString)")
        }
        try write(values)
    }
    public func delete(id: UUID) throws {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        var values = try profiles()
        guard let removed = values.first(where: { $0.id == id }) else { return }
        values.removeAll { $0.id == id }
        let remaining = Set(values.flatMap { $0.jumpHosts + [$0.host] }.map(\.id))
        for host in removed.jumpHosts + [removed.host] where !remaining.contains(host.id) {
            try secrets.delete("credential-\(host.id.uuidString)")
        }
        try write(values)
    }
    public func credential(hostID: UUID) throws -> SSHCredential? {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard try profiles().contains(where: { ($0.jumpHosts + [$0.host]).contains(where: { $0.id == hostID }) }) else { return nil }
        guard let data = try secrets.read("credential-\(hostID.uuidString)") else { return nil }
        return try JSONDecoder().decode(StoredSSHCredential.self, from: data).credential()
    }
    public func setCredential(_ credential: SSHCredential?, hostID: UUID) throws {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard try profiles().contains(where: { ($0.jumpHosts + [$0.host]).contains(where: { $0.id == hostID }) }) else {
            throw SSHFailure.invalidConfiguration
        }
        let account = "credential-\(hostID.uuidString)"
        if let credential { try secrets.write(JSONEncoder().encode(StoredSSHCredential(credential)), account: account) }
        else { try secrets.delete(account) }
    }
}
