#if os(macOS)
import AppKit
import Foundation
import WitermCore

/// A UI-test-only stand-in for the relay server's pairing data, so the
/// device Edit sheet and the Approve step's "Also unpair the older…" choice
/// can be tested without a phone. On only in DEBUG builds launched with
/// `-witerm.debug.pairingFixture 1` (docs/verification.md); never shown or
/// mentioned in the UI.
///
/// While on, every `DevicePairingModel` reads and changes this in-memory
/// list instead of the relay server: this Mac, "Fixture iPhone" (can watch
/// and type, paired under an earlier identity), and "Fixture iPad" (can only
/// watch). Showing a QR code brings a request from "Fixture iPhone" under a
/// new identity a moment later. What a device may open stays in memory too:
/// nothing reaches the relay server or the background service's device
/// access list, and the fixture's colors are given back when the app quits.
enum PairingFixture {
    #if DEBUG
    static let isActive = UserDefaults.standard.bool(forKey: "witerm.debug.pairingFixture")
    #else
    static let isActive = false
    #endif
}

#if DEBUG
extension PairingFixture {
    /// 32 bytes of one value, as a device public key (base64).
    private static func key(_ byte: UInt8) -> String { Data(repeating: byte, count: 32).base64EncodedString() }

    static let me = PairedDevice(id: "fixture-this-mac", name: Host.current().localizedName ?? "This Mac",
                                 platform: .macos, publicKey: key(1))
    static let olderPhone = PairedDevice(id: "fixture-phone-older", name: "Fixture iPhone", platform: .ios, publicKey: key(2))
    static let tablet = PairedDevice(id: "fixture-tablet", name: "Fixture iPad", platform: .ios, publicKey: key(3))
    static let newPhone = PairedDevice(id: "fixture-phone-new", name: "Fixture iPhone", platform: .ios, publicKey: key(4))

    private static func grant(_ client: PairedDevice, _ permission: PairingPermission, days: Double) -> DeviceGrant {
        DeviceGrant(id: "grant-\(client.id)", pairingID: "pairing-\(client.id)", host: me, client: client,
                    permission: permission, approvalSignature: "fixture",
                    createdAt: Date(timeIntervalSince1970: 1_793_664_000 - days * 86_400))
    }

    /// The pairings, shared by every model in this process.
    @MainActor private(set) static var grants: [DeviceGrant] = {
        start()
        return [grant(olderPhone, .control, days: 30), grant(tablet, .view, days: 10)]
    }()

    /// What each fixture device may open, in memory only.
    @MainActor static var accesses: [String: LocalDeviceAccess] = [:]

    @MainActor static func approve(_ request: DevicePairing, permission: PairingPermission, removing ids: Set<String>) -> DevicePairing {
        guard let client = request.client else { return request }
        let made = grant(client, permission, days: 0)
        grants = grants.filter { !ids.contains($0.id) && $0.client.id != client.id } + [made]
        return DevicePairing(id: request.id, status: .approved, expiresAt: request.expiresAt, host: me, client: client, grant: made)
    }

    @MainActor static func revoke(_ id: String) { grants.removeAll { $0.id == id } }

    static func request(_ status: PairingStatus) -> DevicePairing {
        DevicePairing(id: "fixture-request", status: status, expiresAt: Date().addingTimeInterval(600), host: me,
                      client: status == .waiting ? nil : newPhone, grant: nil)
    }

    static func ended(_ pairing: DevicePairing, _ status: PairingStatus) -> DevicePairing {
        DevicePairing(id: pairing.id, status: status, expiresAt: pairing.expiresAt, host: pairing.host,
                      client: pairing.client, grant: pairing.grant)
    }

    /// Fixture devices take colors like real ones; give them back now and at quit.
    @MainActor private static func start() {
        let keys = [me, olderPhone, tablet, newPhone].map(\.publicKey)
        keys.forEach(IdentityHue.forget)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { keys.forEach(IdentityHue.forget) }
        }
    }
}
#endif
#endif
