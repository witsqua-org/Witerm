#if os(iOS)
import Foundation
import UIKit
import WitermCore

/// Which grants came from a one-terminal invitation rather than pairing, so
/// Terminals can list them under Shared with You and Devices can leave them
/// out. Only grant IDs and when their access ends, in this device's
/// defaults: no keys, secrets or terminal content.
enum SharedTerminals {
    static let key = "witerm.sharedTerminalGrants"

    private static var stored: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Recorded when an invitation's grant is first joined (not when an
    /// existing pairing is used instead).
    static func record(_ grantID: String, until end: Date) {
        stored[grantID] = end.timeIntervalSince1970
    }

    @MainActor static func ids() -> Set<String> {
        var ids = Set(stored.keys)
        #if DEBUG
        if RemoteFixture.isActive { ids.insert(RemoteFixture.sharedGrantID) }
        #endif
        return ids
    }

    static func forget(_ grantID: String) {
        guard stored[grantID] != nil else { return }
        stored[grantID] = nil
    }

    /// Drops grants the relay server no longer lists, and ones whose access
    /// ended more than a day ago.
    static func prune(keeping listed: Set<String>, now: Date = Date()) {
        let kept = stored.filter { listed.contains($0.key) && $0.value > now.timeIntervalSince1970 - 86_400 }
        if kept.count != stored.count { stored = kept }
    }
}

/// A UI-test-only stand-in for paired devices and their terminals, so the
/// Terminals sections, Devices and Unpair's confirmation can be tested
/// without a Mac. On only in DEBUG builds launched with
/// `-witerm.debug.remoteFixture 1` and the relay server
/// `https://relay.fixture.invalid` (docs/verification.md). Everything stays
/// in memory: nothing reaches a relay server. Its terminals open through
/// `FixtureMac`, which stands in for the Macs' service (Round 17).
enum RemoteFixture {
    #if DEBUG
    static let isActive = UserDefaults.standard.bool(forKey: "witerm.debug.remoteFixture")
    #else
    static let isActive = false
    #endif
    static let serverAddress = "https://relay.fixture.invalid"
}

#if DEBUG
extension RemoteFixture {
    static let sharedGrantID = "fixture-grant-shared"

    private static func key(_ byte: UInt8) -> String { Data(repeating: byte, count: 32).base64EncodedString() }
    private static let phone = PairedDevice(id: "fixture-phone", name: "Fixture iPhone", platform: .ios, publicKey: key(10))
    static let studio = PairedDevice(id: "fixture-studio", name: "Studio", platform: .macos, publicKey: key(11))
    static let mini = PairedDevice(id: "fixture-mini", name: "Mini", platform: .macos, publicKey: key(12))
    static let laptop = PairedDevice(id: "fixture-laptop", name: "Old Laptop", platform: .macos, publicKey: key(13))
    static let guestHost = PairedDevice(id: "fixture-alex", name: "Alex’s MacBook", platform: .macos, publicKey: key(14))

    private static func grant(_ id: String, _ host: PairedDevice, _ permission: PairingPermission) -> DeviceGrant {
        DeviceGrant(id: id, pairingID: "pairing-\(id)", host: host, client: phone, permission: permission,
                    approvalSignature: "fixture", createdAt: Date(timeIntervalSince1970: 1_793_664_000))
    }

    @MainActor static let grants: [DeviceGrant] = {
        // Fixture machines take colors like real ones; give them back first.
        [studio, mini, laptop, guestHost].forEach { IdentityHue.forget($0.publicKey) }
        return [grant("fixture-grant-studio", studio, .control), grant("fixture-grant-mini", mini, .view),
                grant("fixture-grant-laptop", laptop, .control), grant(sharedGrantID, guestHost, .control)]
    }()

    static let offline: Set<String> = ["fixture-grant-laptop"]

    /// Launched with `-witerm.debug.remoteFixtureCleanup 1` (the UI tests'
    /// last step): gives the fixture machines' colors back.
    @MainActor static func cleanUpIfAsked() {
        guard UserDefaults.standard.bool(forKey: "witerm.debug.remoteFixtureCleanup") else { return }
        [studio, mini, laptop, guestHost].forEach { IdentityHue.forget($0.publicKey) }
    }

    private static func session(_ id: String, _ name: String, access: LocalAttachmentMode? = nil,
                                writers: [LocalWriterInfo]? = []) -> LocalSessionInfo {
        LocalSessionInfo(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_793_664_000), columns: 80, rows: 24,
                         access: access, writers: writers)
    }

    static let sessions: [String: [LocalSessionInfo]] = [
        "fixture-grant-studio": [session("fixture-s1", "Terminal 1"),
                                 session("fixture-s2", "build", writers: [LocalWriterInfo(name: nil)]),
                                 session("fixture-s3", "logs", access: .view)],
        "fixture-grant-mini": [session("fixture-m1", "server", access: .view)],
        sharedGrantID: [session("fixture-a1", "Demo")],
    ]
}
#endif
#endif
