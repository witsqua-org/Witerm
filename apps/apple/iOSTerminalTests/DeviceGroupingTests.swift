import Foundation
import WitermCore
import XCTest
@testable import WitermiOS

/// A device appears once per relay server, however many pairings it has.
@MainActor final class DeviceGroupingTests: XCTestCase {
    private func device(_ id: String, _ name: String) -> PairedDevice {
        PairedDevice(id: id, name: name, platform: .macos, publicKey: "key-\(id)")
    }

    private func grant(_ id: String, host: PairedDevice, permission: PairingPermission, at seconds: TimeInterval) -> DeviceGrant {
        DeviceGrant(id: id, pairingID: "pairing-\(id)", host: host,
                    client: PairedDevice(id: "phone", name: "Phone", platform: .ios, publicKey: "phone-key"),
                    permission: permission, approvalSignature: "", createdAt: Date(timeIntervalSince1970: seconds))
    }

    func testDevicePairedTwiceIsListedOnceWithItsWidestAccess() {
        let mac = device("mac", "Studio"), laptop = device("laptop", "Laptop")
        let grants = [grant("1", host: mac, permission: .view, at: 100),
                      grant("2", host: laptop, permission: .view, at: 150),
                      grant("3", host: mac, permission: .control, at: 50),
                      grant("4", host: mac, permission: .view, at: 300)]
        let devices = RemoteTerminalModel.devices(in: grants)
        XCTAssertEqual(devices.map(\.host.id), ["mac", "laptop"], "One row per device, in first-seen order")
        XCTAssertEqual(devices.first?.id, "3", "A pairing that can type wins over newer watch-only ones")
        XCTAssertEqual(devices.last?.id, "2")
    }

    func testNewestPairingWinsWhenAccessIsTheSame() {
        let mac = device("mac", "Studio")
        let devices = RemoteTerminalModel.devices(in: [grant("old", host: mac, permission: .control, at: 10),
                                                       grant("new", host: mac, permission: .control, at: 20)])
        XCTAssertEqual(devices.map(\.id), ["new"])
    }

    /// Unpairing the listed row ends every pairing with that device.
    func testUnpairEndsEveryPairingInTheGroup() {
        let mac = device("mac", "Studio"), laptop = device("laptop", "Laptop")
        let grants = [grant("1", host: mac, permission: .view, at: 1), grant("2", host: mac, permission: .control, at: 2),
                      grant("3", host: laptop, permission: .control, at: 3)]
        let listed = RemoteTerminalModel.devices(in: grants)[0]
        XCTAssertEqual(Set(RemoteTerminalModel.pairings(endedBy: listed, in: grants).map(\.id)), ["1", "2"])
    }
}
