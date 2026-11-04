import Foundation
import WitermCore
import XCTest
@testable import WitermiOS

/// Round 20: who is connected to a paired terminal, from the `attached` a
/// Mac lists for a paired device, and the words iOS shows for it: a count in
/// the title, and a list in Connected Devices. Never who types in the title.
@MainActor final class ConnectedDevicesTests: XCTestCase {
    private func text(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: .main) }

    private func decode(_ json: String) throws -> LocalSessionInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalSessionInfo.self, from: Data(json.utf8))
    }

    private let base = #""id":"7b0e7d44-35c5-4a8b-9d4b-2b1a9c0e6f11","name":"build","created_at":"2026-11-03T00:00:00Z","columns":80,"rows":24,"access":"control""#

    func testDecodesAttachedAndOlderMacsOmitIt() throws {
        let listed = try decode(#"{\#(base),"attached":[{"mode":"control","grid_owner":true},{"name":"iPhone","mode":"view","this_device":true}]}"#)
        XCTAssertEqual(listed.attached, [LocalConnectedDevice(name: nil, mode: .control, gridOwner: true),
                                         LocalConnectedDevice(name: "iPhone", mode: .view, thisDevice: true)])
        XCTAssertNil(try decode("{\(base)}").attached)
    }

    /// This device first, under its own words, then the Mac by its paired
    /// name, then the others in the Mac's order; this device's typing is
    /// what it does now, not what the list said.
    func testListsThisDeviceFirstThenTheMacThenTheOthers() {
        let attached = [LocalConnectedDevice(name: nil, mode: .view),
                        LocalConnectedDevice(name: "Alex’s iPad", mode: .control, gridOwner: true),
                        LocalConnectedDevice(name: "Nigel’s iPhone", mode: .control, thisDevice: true),
                        LocalConnectedDevice(name: "Sam’s iPhone", mode: .view)]
        let devices = ConnectedDevices.devices(attached, typingHere: false, thisName: "This iPhone", hostName: "Studio",
                                               sizesCurrent: true)
        XCTAssertEqual(devices?.map(\.name), ["This iPhone", "Studio", "Alex’s iPad", "Sam’s iPhone"])
        XCTAssertEqual(devices?.map(\.kind), [.thisDevice, .mac, .paired, .paired])
        XCTAssertEqual(devices?.map(\.typing), [false, false, true, false], "This device watches now")
        XCTAssertEqual(devices?.map(\.setsSize), [false, false, true, false])
        XCTAssertEqual(Set(devices?.map(\.id) ?? []).count, 4, "Rows need distinct identities")
    }

    /// The list counts this device even before the Mac lists it (a list
    /// made before it attached), and never twice.
    func testThisDeviceCountsOnceWhetherOrNotTheMacListedIt() {
        let mac = LocalConnectedDevice(name: nil, mode: .control, gridOwner: true)
        XCTAssertEqual(ConnectedDevices.devices([mac], typingHere: true, thisName: "This iPhone", hostName: "Studio",
                                                sizesCurrent: true)?.count, 2)
        let listed = [mac, LocalConnectedDevice(name: "iPhone", mode: .view, thisDevice: true)]
        XCTAssertEqual(ConnectedDevices.devices(listed, typingHere: true, thisName: "This iPhone", hostName: "Studio",
                                                sizesCurrent: true)?.count, 2)
        XCTAssertEqual(ConnectedDevices.devices([], typingHere: false, thisName: "This iPhone", hostName: "Studio",
                                                sizesCurrent: true)?.map(\.kind), [.thisDevice])
    }

    /// Whose grid it is shows only from a list made on the current link,
    /// and this device's only while it types.
    func testWhoseSizeIsNeverGuessed() {
        let mine = [LocalConnectedDevice(name: nil, mode: .control),
                    LocalConnectedDevice(name: "iPhone", mode: .control, gridOwner: true, thisDevice: true)]
        XCTAssertEqual(ConnectedDevices.devices(mine, typingHere: true, thisName: "This iPhone", hostName: "Studio",
                                                sizesCurrent: true)?.map(\.setsSize), [true, false])
        XCTAssertEqual(ConnectedDevices.devices(mine, typingHere: false, thisName: "This iPhone", hostName: "Studio",
                                                sizesCurrent: true)?.map(\.setsSize), [false, false],
                       "Stopped typing since the list: the grid is no longer this device's")
        XCTAssertEqual(ConnectedDevices.devices(mine, typingHere: true, thisName: "This iPhone", hostName: "Studio",
                                                sizesCurrent: false)?.map(\.setsSize), [false, false],
                       "A list from before this link")
    }

    /// An older Mac, or an invitation's grant: nothing to count or list.
    func testNoListWhenTheMacDoesNotSay() {
        XCTAssertNil(ConnectedDevices.devices(nil, typingHere: true, thisName: "This iPhone", hostName: "Studio", sizesCurrent: true))
        XCTAssertNil(ConnectedDevices.count(nil))
    }

    /// The title counts this device too, and says nothing when it's alone.
    func testCountIncludesThisDeviceAndIsQuietAlone() {
        func devices(_ others: Int) -> [ConnectedDevice]? {
            ConnectedDevices.devices((0..<others).map { LocalConnectedDevice(name: "Device \($0)", mode: .view) },
                                     typingHere: false, thisName: "This iPhone", hostName: "Studio", sizesCurrent: true)
        }
        XCTAssertNil(ConnectedDevices.count(devices(0)))
        XCTAssertEqual(ConnectedDevices.count(devices(1)), text("\(2) devices connected"))
        XCTAssertEqual(ConnectedDevices.count(devices(2)), text("\(3) devices connected"))
        XCTAssertFalse(ConnectedDevices.count(devices(2))?.contains("Typing") ?? true)
    }

    /// Round 21: Terminals' rows count as the title does, this device only
    /// while it's connected here, whatever the list said; nothing alone,
    /// and nothing from an older Mac (never a guess from who types).
    func testRowsCountAsTheTitleAndThisDeviceOnlyWhileConnected() {
        let mac = LocalConnectedDevice(name: nil, mode: .control, gridOwner: true)
        let iPad = LocalConnectedDevice(name: "Alex’s iPad", mode: .view)
        let listedHere = LocalConnectedDevice(name: "iPhone", mode: .view, thisDevice: true)
        XCTAssertEqual(ConnectedDevices.rowCount([mac, iPad], connectedHere: false), text("\(2) devices connected"))
        XCTAssertEqual(ConnectedDevices.rowCount([mac, iPad], connectedHere: true), text("\(3) devices connected"))
        XCTAssertNil(ConnectedDevices.rowCount([mac], connectedHere: false), "One device: no count")
        XCTAssertEqual(ConnectedDevices.rowCount([mac], connectedHere: true), text("\(2) devices connected"),
                       "Kept after Back: this device counts, as in the title")
        XCTAssertNil(ConnectedDevices.rowCount([mac, listedHere], connectedHere: false),
                     "A list from before this device left doesn't count it")
        XCTAssertEqual(ConnectedDevices.rowCount([mac, listedHere], connectedHere: true), text("\(2) devices connected"),
                       "Never twice")
        XCTAssertNil(ConnectedDevices.rowCount([listedHere], connectedHere: true), "Alone: no count")
        XCTAssertNil(ConnectedDevices.rowCount([], connectedHere: false))
        XCTAssertNil(ConnectedDevices.rowCount(nil, connectedHere: true), "An older Mac or an invitation: no count")
        // The row and the title agree for the open terminal.
        let title = ConnectedDevices.count(ConnectedDevices.devices([mac, iPad, listedHere], typingHere: false, thisName: "This iPhone",
                                                                    hostName: "Studio", sizesCurrent: true))
        XCTAssertEqual(ConnectedDevices.rowCount([mac, iPad, listedHere], connectedHere: true), title)
    }

    func testRowFactsSayTypingOrWatchingAndWhoseSize() {
        let typing = ConnectedDevice(id: "mac", kind: .mac, name: "Studio", typing: true, setsSize: true)
        XCTAssertEqual(ConnectedDevicesSheet.facts(typing), [text("Typing"), text("Sets the terminal size")])
        let watching = ConnectedDevice(id: "this", kind: .thisDevice, name: "This iPhone", typing: false, setsSize: false)
        XCTAssertEqual(ConnectedDevicesSheet.facts(watching), [text("Watching")])
    }
}
