import Crypto
import Foundation
import XCTest
@testable import WitermSSH

final class TestSSHSecrets: SSHSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) -> Data? { lock.withLock { values[account] } }
    func create(_ data: Data, account: String) -> Bool {
        lock.withLock { guard values[account] == nil else { return false }; values[account] = data; return true }
    }
    func write(_ data: Data, account: String) { lock.withLock { values[account] = data } }
    func delete(_ account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
}

@MainActor final class SSHStorageTests: XCTestCase {
    private func key(_ value: UInt8 = 1, authority: String = "[example.test]:22") -> SSHHostKey {
        let algorithm = "ssh-ed25519"
        var bytes = Data([0, 0, 0, UInt8(algorithm.utf8.count)])
        bytes.append(contentsOf: algorithm.utf8)
        bytes.append(contentsOf: [0, 0, 0, 32])
        bytes.append(Data(repeating: value, count: 32))
        return SSHHostKey(authority: authority, algorithm: algorithm, publicKey: bytes.base64EncodedString(),
                          fingerprint: "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: ""))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-ssh-storage-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUnknownKeyMustBeExplicitlyTrustedAndChangedKeyCannotOverwrite() async throws {
        let secrets = TestSSHSecrets()
        let first = SSHKnownHosts(secrets: secrets), second = SSHKnownHosts(secrets: secrets)
        let initial = try await first.status(for: key())
        XCTAssertEqual(initial, .unknown)
        try await first.trust(key())
        let pinned = try await second.status(for: key())
        XCTAssertEqual(pinned, .trusted)
        let changed = try await second.status(for: key(2))
        XCTAssertEqual(changed, .changed(previousFingerprint: key().fingerprint))
        do { try await second.trust(key(2)); XCTFail("Changed key was accepted") }
        catch { XCTAssertEqual(error as? SSHFailure, .hostKeyChanged) }
        let remains = try await first.status(for: key())
        XCTAssertEqual(remains, .trusted)
    }

    func testTrustIsScopedByAuthorityAndRejectsForgedFingerprint() async throws {
        let hosts = SSHKnownHosts(secrets: TestSSHSecrets())
        try await hosts.trust(key())
        let otherPort = try await hosts.status(for: key(authority: "[example.test]:2222"))
        XCTAssertEqual(otherPort, .unknown)
        let original = key()
        let forged = SSHHostKey(authority: original.authority, algorithm: original.algorithm,
                                publicKey: original.publicKey, fingerprint: "SHA256:forged")
        do { _ = try await hosts.status(for: forged); XCTFail("Forged fingerprint accepted") }
        catch { XCTAssertEqual(error as? SSHFailure, .hostKeyRejected) }
    }

    func testConcurrentFirstUsePinsCannotReplaceEachOther() async throws {
        let secrets = TestSSHSecrets()
        let a = SSHKnownHosts(secrets: secrets), b = SSHKnownHosts(secrets: secrets)
        let k1 = key(), k2 = key(2)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await a.trust(k1) }
            group.addTask { try? await b.trust(k2) }
        }
        let first = try await a.status(for: k1), second = try await b.status(for: k2)
        XCTAssertTrue((first == .trusted) != (second == .trusted))
    }

    func testCredentialsNeverEnterProfileJSONAndEndpointEditForgetsThem() async throws {
        let path = try directory()
        let store = try SSHProfileStore(directory: path, secrets: TestSSHSecrets())
        var profile = SSHProfile(name: "测试", host: SSHHost(hostname: "example.test", username: "user"))
        try await store.save(profile)
        try await store.setCredential(.password("fixed-fixture-secret"), hostID: profile.host.id)
        let serialized = try String(contentsOf: path.appendingPathComponent("profiles.json"), encoding: .utf8)
        XCTAssertFalse(serialized.contains("fixed-fixture-secret"))
        let credential = try await store.credential(hostID: profile.host.id)
        guard case .password("fixed-fixture-secret") = credential else { return XCTFail("Credential missing") }
        profile.host.hostname = "other.test"
        try await store.save(profile)
        let after = try await store.credential(hostID: profile.host.id)
        XCTAssertNil(after)
        let permission = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent("profiles.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permission, 0o600)
    }

    func testDeleteRemovesSecretsAndUnknownHostCannotStoreCredential() async throws {
        let store = try SSHProfileStore(directory: directory(), secrets: TestSSHSecrets())
        let profile = SSHProfile(name: "测试", host: SSHHost(hostname: "example.test", username: "user"))
        try await store.save(profile)
        try await store.setCredential(.privateKey("fixture-key", passphrase: "fixture-passphrase"), hostID: profile.host.id)
        try await store.delete(id: profile.id)
        let profiles = try await store.profiles(), credential = try await store.credential(hostID: profile.host.id)
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertNil(credential)
        do { try await store.setCredential(.password("fixture"), hostID: UUID()); XCTFail("Unknown host credential accepted") }
        catch { XCTAssertEqual(error as? SSHFailure, .invalidConfiguration) }
    }

    func testInvalidProfileAndSymlinkStorageRejected() async throws {
        let host = SSHHost(hostname: "host\ninvalid", username: "user")
        XCTAssertThrowsError(try host.validate())
        XCTAssertThrowsError(try SSHHost(hostname: "host", port: 65536, username: "user").validate())
        let base = try directory(), actual = base.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        XCTAssertThrowsError(try SSHProfileStore(directory: link, secrets: TestSSHSecrets()))
    }

    func testExplicitForgetRequiresCurrentFingerprintAndDoesNotReplaceKey() async throws {
        let hosts = SSHKnownHosts(secrets: TestSSHSecrets())
        try await hosts.trust(key())
        do { try await hosts.forget(authority: key().authority, expectedFingerprint: key(2).fingerprint); XCTFail("Wrong fingerprint removed trust") }
        catch { XCTAssertEqual(error as? SSHFailure, .hostKeyChanged) }
        let before = try await hosts.storedKey(authority: key().authority)
        XCTAssertEqual(before, key())
        try await hosts.forget(authority: key().authority, expectedFingerprint: key().fingerprint)
        let after = try await hosts.status(for: key(2))
        XCTAssertEqual(after, .unknown)
    }

    func testSeparateStoresDoNotLoseConcurrentProfilesAndRemovedJumpCredentials() async throws {
        let path = try directory(), secrets = TestSSHSecrets()
        let a = try SSHProfileStore(directory: path, secrets: secrets)
        let b = try SSHProfileStore(directory: path, secrets: secrets)
        var first = SSHProfile(name: "一", host: SSHHost(hostname: "one.test", username: "user"),
                               jumpHosts: [SSHHost(hostname: "jump.test", username: "user")])
        let second = SSHProfile(name: "二", host: SSHHost(hostname: "two.test", username: "user"))
        let initialFirst = first
        async let one: Void = a.save(initialFirst)
        async let two: Void = b.save(second)
        _ = try await (one, two)
        let saved = try await a.profiles()
        XCTAssertEqual(Set(saved.map(\.id)), Set([first.id, second.id]))
        let jumpID = first.jumpHosts[0].id
        try await a.setCredential(.password("fixed-jump-secret"), hostID: jumpID)
        first.jumpHosts.removeAll()
        try await b.save(first)
        XCTAssertNil(secrets.read("credential-\(jumpID.uuidString)"))
    }
}
