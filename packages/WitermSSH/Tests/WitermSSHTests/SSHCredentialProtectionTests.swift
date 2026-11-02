import Foundation
import Security
import XCTest
@testable import WitermSSH

/// A store that remembers which items were written protected, the way the
/// Keychain hides a protected item from a read that may not ask.
final class ProtectingSSHSecrets: SSHSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (data: Data, protected: Bool)] = [:]
    private(set) var unlockedReads = 0

    func read(_ account: String) -> Data? {
        lock.withLock { values[account].flatMap { $0.protected ? nil : $0.data } }
    }
    func create(_ data: Data, account: String) -> Bool {
        lock.withLock { guard values[account] == nil else { return false }; values[account] = (data, false); return true }
    }
    func write(_ data: Data, account: String) { lock.withLock { values[account] = (data, false) } }
    func delete(_ account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
    func probe(_ account: String) -> SSHSecretProbe {
        lock.withLock {
            guard let value = values[account] else { return .missing }
            return value.protected ? .locked : .readable(value.data)
        }
    }
    func read(_ account: String, unlock: SSHUnlock) -> Data? {
        lock.withLock { unlockedReads += 1; return values[account]?.data }
    }
    func writeProtected(_ data: Data, account: String) { lock.withLock { values[account] = (data, true) } }
    func accounts() -> [String] { lock.withLock { Array(values.keys) } }
    func isProtected(_ account: String) -> Bool? { lock.withLock { values[account]?.protected } }
}

@MainActor final class SSHCredentialProtectionTests: XCTestCase {
    private func password(_ credential: SSHCredential?) -> String? {
        if case .password(let value) = credential { return value }
        return nil
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-ssh-protection-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Saved credentials need Face ID, Touch ID, or the passcode to read;
    /// they stay on this device, only while a passcode is set, never synced.
    func testProtectedItemAttributes() throws {
        let item = try XCTUnwrap(SSHKeychainStorage.protectedItem(Data("fixture".utf8), account: "credential-test"))
        XCTAssertNotNil(item[kSecAttrAccessControl as String], "A saved credential must carry access control")
        XCTAssertEqual(CFGetTypeID(item[kSecAttrAccessControl as String] as CFTypeRef), SecAccessControlGetTypeID())
        XCTAssertNil(item[kSecAttrAccessible as String], "Accessibility belongs to the access control, not beside it")
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(item[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(item[kSecAttrService as String] as? String, SSHKeychainStorage.service)
        XCTAssertEqual(item[kSecAttrAccount as String] as? String, "credential-test")
        XCTAssertEqual(item[kSecValueData as String] as? Data, Data("fixture".utf8))
    }

    func testSavingProtectsAndReadingNeedsOneUnlockForEveryHop() async throws {
        let secrets = ProtectingSSHSecrets()
        let store = try SSHProfileStore(directory: directory(), secrets: secrets)
        let profile = SSHProfile(name: "fixture", host: SSHHost(hostname: "target.test", username: "user"),
                                 jumpHosts: [SSHHost(hostname: "jump.test", username: "user")])
        let ids = (profile.jumpHosts + [profile.host]).map(\.id)
        try await store.save(profile)
        try await store.setCredential(.password("jump-secret"), hostID: ids[0])
        try await store.setCredential(.password("target-secret"), hostID: ids[1])
        XCTAssertEqual(secrets.isProtected("credential-\(ids[0].uuidString)"), true)
        XCTAssertEqual(secrets.isProtected("credential-\(ids[1].uuidString)"), true)

        // Knowing they're saved never asks.
        let saved = try await store.savedCredentialHosts(ids)
        XCTAssertEqual(saved, Set(ids))
        let needsUnlock = try await store.credentialsNeedUnlock(ids)
        XCTAssertTrue(needsUnlock)
        XCTAssertEqual(secrets.unlockedReads, 0)

        // Without an unlock nothing protected is read.
        do { _ = try await store.credentials(ids, unlock: nil); XCTFail("Read a protected credential without unlocking") }
        catch { XCTAssertEqual(error as? SSHFailure, .cancelled) }

        let values = try await store.credentials(ids, unlock: SSHUnlock())
        XCTAssertEqual(password(values[ids[0]]), "jump-secret")
        XCTAssertEqual(password(values[ids[1]]), "target-secret")
        XCTAssertEqual(secrets.unlockedReads, 2, "Both hops are read with the same unlock")
    }

    /// A credential saved before protection reads without asking, and gains
    /// protection the next time it's saved after a successful connection.
    func testUnprotectedCredentialMigratesOnNextSave() async throws {
        let secrets = ProtectingSSHSecrets()
        let store = try SSHProfileStore(directory: directory(), secrets: secrets)
        let profile = SSHProfile(name: "legacy", host: SSHHost(hostname: "legacy.test", username: "user"))
        let account = "credential-\(profile.host.id.uuidString)"
        try await store.save(profile)
        secrets.write(try JSONEncoder().encode(["kind": "password", "value": "old-secret"]), account: account)

        let needsUnlock = try await store.credentialsNeedUnlock([profile.host.id])
        XCTAssertFalse(needsUnlock, "An unprotected credential must not ask for Face ID")
        let old = try await store.credentials([profile.host.id], unlock: nil)
        XCTAssertEqual(password(old[profile.host.id]), "old-secret")

        try await store.setCredential(.password("old-secret"), hostID: profile.host.id)
        XCTAssertEqual(secrets.isProtected(account), true)
        let afterwards = try await store.credentialsNeedUnlock([profile.host.id])
        XCTAssertTrue(afterwards)
    }

    /// Deleting keeps the protected items for Undo, which restores the host
    /// without reading them; afterwards unused ones are purged.
    func testDeleteKeepsCredentialsForUndoThenPurges() async throws {
        let secrets = ProtectingSSHSecrets()
        let store = try SSHProfileStore(directory: directory(), secrets: secrets)
        let profile = SSHProfile(name: "undo", host: SSHHost(hostname: "undo.test", username: "user"))
        let other = SSHProfile(name: "other", host: SSHHost(hostname: "other.test", username: "user"))
        try await store.save(profile)
        try await store.save(other)
        try await store.setCredential(.password("undo-secret"), hostID: profile.host.id)
        try await store.setCredential(.password("other-secret"), hostID: other.host.id)

        try await store.delete(id: profile.id, keepingCredentials: true)
        XCTAssertEqual(secrets.isProtected("credential-\(profile.host.id.uuidString)"), true, "Kept for Undo")
        try await store.save(profile)
        let restored = try await store.savedCredentialHosts([profile.host.id])
        XCTAssertEqual(restored, [profile.host.id], "Undo restores the host with its protected credential")

        try await store.delete(id: profile.id, keepingCredentials: true)
        try await store.purgeUnusedCredentials()
        XCTAssertNil(secrets.isProtected("credential-\(profile.host.id.uuidString)"))
        XCTAssertEqual(secrets.isProtected("credential-\(other.host.id.uuidString)"), true, "Hosts still saved keep theirs")
    }
}
