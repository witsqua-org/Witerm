import Crypto
import Foundation
import Security
import LocalAuthentication

/// What a read that may not ask the person found.
enum SSHSecretProbe: Equatable {
    case missing
    /// Readable without asking: a host-key pin, or a credential saved before
    /// credentials were protected.
    case readable(Data)
    /// Saved behind device-owner authentication.
    case locked
}

protocol SSHSecretStorage: Sendable {
    func read(_ account: String) throws -> Data?
    func create(_ data: Data, account: String) throws -> Bool
    func write(_ data: Data, account: String) throws
    func delete(_ account: String) throws
    /// Reads without any prompt, saying whether an item is there but locked.
    func probe(_ account: String) throws -> SSHSecretProbe
    /// Reads a locked item with a context the person already authenticated.
    func read(_ account: String, unlock: SSHUnlock) throws -> Data?
    /// Replaces an item with one that needs device-owner authentication to read.
    func writeProtected(_ data: Data, account: String) throws
    /// Every account in this store, read from attributes only (no prompt).
    func accounts() throws -> [String]
}

extension SSHSecretStorage {
    func probe(_ account: String) throws -> SSHSecretProbe { try read(account).map(SSHSecretProbe.readable) ?? .missing }
    func read(_ account: String, unlock: SSHUnlock) throws -> Data? { try read(account) }
    func writeProtected(_ data: Data, account: String) throws { try write(data, account: account) }
    func accounts() throws -> [String] { [] }
}

struct SSHKeychainStorage: SSHSecretStorage {
    static let service = "com.witerm.ssh.v1"
    /// Marks an item written with access control. Whether to ask the person
    /// follows this mark, not only the Keychain's refusal: the simulator
    /// doesn't enforce `.userPresence` on reads, and the app must ask anyway.
    static let protectedMark = "witerm.credential.protected.v1"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// A saved credential: readable only after Face ID, Touch ID, or the
    /// device passcode (the Mac's login password), only on this device, only
    /// while a passcode is set, and never synced. Nil when the device can't
    /// protect it, such as without a passcode; nothing is stored then.
    static func protectedItem(_ data: Data, account: String) -> [String: Any]? {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrAccessControl as String: access,
                kSecAttrDescription as String: protectedMark,
                kSecValueData as String: data]
    }

    /// Attributes first (never a prompt); the data only for an unmarked,
    /// unprotected item saved before protection existed.
    func probe(_ account: String) throws -> SSHSecretProbe {
        let context = LAContext()
        context.interactionNotAllowed = true
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = context
        var attributes: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &attributes) {
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed: return .locked
        case errSecSuccess: break
        default: throw SSHFailure.storageUnavailable
        }
        if (attributes as? [String: Any])?[kSecAttrDescription as String] as? String == Self.protectedMark { return .locked }
        var d = query(account)
        d[kSecReturnData as String] = true
        d[kSecMatchLimit as String] = kSecMatchLimitOne
        d[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        switch SecItemCopyMatching(d as CFDictionary, &item) {
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed: return .locked
        case errSecSuccess:
            guard let data = item as? Data else { throw SSHFailure.storageUnavailable }
            return .readable(data)
        default: throw SSHFailure.storageUnavailable
        }
    }

    func read(_ account: String, unlock: SSHUnlock) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = unlock.context
        var item: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        if result == errSecUserCanceled || result == errSecAuthFailed { throw SSHFailure.cancelled }
        guard result == errSecSuccess, let data = item as? Data else { throw SSHFailure.storageUnavailable }
        return data
    }

    func writeProtected(_ data: Data, account: String) throws {
        guard let item = Self.protectedItem(data, account: account) else { throw SSHFailure.storageUnavailable }
        // Replace rather than update: updating a protected item would ask the
        // person again, and an older unprotected item gains protection here.
        try delete(account)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SSHFailure.storageUnavailable }
    }

    func accounts() throws -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.service,
                                kSecAttrSynchronizable as String: false,
                                kSecUseDataProtectionKeychain as String: true,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var items: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &items)
        if result == errSecItemNotFound { return [] }
        guard result == errSecSuccess, let list = items as? [[String: Any]] else { throw SSHFailure.storageUnavailable }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }
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
    private func account(_ hostID: UUID) -> String { "credential-\(hostID.uuidString)" }

    private func isSaved(_ hostID: UUID) throws -> Bool {
        try profiles().contains(where: { ($0.jumpHosts + [$0.host]).contains(where: { $0.id == hostID }) })
    }

    /// Which of these hosts have a saved credential, without asking the person.
    public func savedCredentialHosts(_ hostIDs: [UUID]) throws -> Set<UUID> {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        var saved = Set<UUID>()
        for id in hostIDs where try isSaved(id) {
            if try secrets.probe(account(id)) != .missing { saved.insert(id) }
        }
        return saved
    }

    /// Whether reading these credentials needs the person to authenticate.
    /// Credentials saved before they were protected don't, until they're
    /// next saved (after a successful connection), which protects them.
    public func credentialsNeedUnlock(_ hostIDs: [UUID]) throws -> Bool {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        return try hostIDs.contains { try isSaved($0) && secrets.probe(account($0)) == .locked }
    }

    /// The saved credentials for these hosts, read with one authentication.
    /// `unlock` must already be unlocked when any of them is protected.
    public func credentials(_ hostIDs: [UUID], unlock: SSHUnlock?) throws -> [UUID: SSHCredential] {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        var result: [UUID: SSHCredential] = [:]
        for id in hostIDs where try isSaved(id) {
            let data: Data?
            switch try secrets.probe(account(id)) {
            case .missing: data = nil
            case .readable(let value): data = value
            case .locked:
                guard let unlock else { throw SSHFailure.cancelled }
                data = try secrets.read(account(id), unlock: unlock)
            }
            if let data { result[id] = try JSONDecoder().decode(StoredSSHCredential.self, from: data).credential() }
        }
        return result
    }

    /// One host's credential when it can be read without asking; a protected
    /// one throws `cancelled` (use `credentials(_:unlock:)`).
    public func credential(hostID: UUID) throws -> SSHCredential? {
        try credentials([hostID], unlock: nil)[hostID]
    }

    public func setCredential(_ credential: SSHCredential?, hostID: UUID) throws {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard try isSaved(hostID) else { throw SSHFailure.invalidConfiguration }
        if let credential {
            try secrets.writeProtected(JSONEncoder().encode(StoredSSHCredential(credential)), account: account(hostID))
        } else { try secrets.delete(account(hostID)) }
    }

    /// Deletes a host but keeps its credentials, so Undo can restore it
    /// without reading them; `purgeCredentials` or the next launch removes them.
    public func delete(id: UUID, keepingCredentials: Bool) throws {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard keepingCredentials else { return try delete(id: id) }
        var values = try profiles()
        guard values.contains(where: { $0.id == id }) else { return }
        values.removeAll { $0.id == id }
        try write(values)
    }

    /// Removes the credentials of hosts no saved profile uses any more.
    public func purgeUnusedCredentials() throws {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        let used = Set(try profiles().flatMap { $0.jumpHosts + [$0.host] }.map { account($0.id) })
        for name in try secrets.accounts() where name.hasPrefix("credential-") && !used.contains(name) {
            try secrets.delete(name)
        }
    }
}

/// One authentication for one connection attempt: Face ID or Touch ID with
/// the device passcode (the Mac's login password) as the fallback, reused for
/// every hop of a jump-host chain.
public final class SSHUnlock: @unchecked Sendable {
    public enum Method: Sendable, Equatable {
        case faceID, touchID, opticID, passcode
        /// No passcode is set: nothing can be saved.
        case unavailable
    }

    public enum Outcome: Sendable, Equatable {
        case unlocked
        /// The person cancelled; the attempt ends quietly.
        case cancelled
        /// The person chose to type the password for this attempt instead.
        case enterPassword
    }

    let context = LAContext()

    public init() {}

    /// How saved credentials are protected on this device.
    public static var method: Method {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        // The hardware's biometry type is set even with nothing enrolled;
        // only enrolled biometrics protect, otherwise the passcode does.
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .passcode }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    /// Asks once. Biometrics come first, with `fallbackTitle` (Enter Password)
    /// for typing the SSH password instead; without biometrics, or once they're
    /// locked out, the device passcode.
    public func unlock(reason: String, fallbackTitle: String) async throws -> Outcome {
        context.localizedFallbackTitle = fallbackTitle
        let biometric = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        do {
            _ = try await context.evaluatePolicy(biometric ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication,
                                                 localizedReason: reason)
            return .unlocked
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            case .userFallback: return .enterPassword
            case .biometryLockout:
                _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return .unlocked
            default: throw SSHFailure.storageUnavailable
            }
        }
    }
}
