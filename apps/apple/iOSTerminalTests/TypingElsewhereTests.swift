import Foundation
import WitermCore
import XCTest
@testable import WitermiOS

/// Who else types in a paired terminal: the `writers` a Mac lists for a
/// paired device, and the words iOS chooses from them.
@MainActor final class TypingElsewhereTests: XCTestCase {
    private func decode(_ json: String) throws -> LocalSessionInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalSessionInfo.self, from: Data(json.utf8))
    }

    /// The app's own wording in the simulator's language, so the checks are
    /// about which words are chosen, in any language.
    private func text(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: .main) }

    private let base = #""id":"7B0E7D44-35C5-4A8B-9D4B-2B1A9C0E6F11","name":"build","created_at":"2026-11-03T00:00:00Z","columns":80,"rows":24,"access":"control""#

    func testDecodesWritersWithTheMacAsNil() throws {
        let session = try decode("{\(base),\"writers\":[{\"name\":\"iPad\"},{}]}")
        XCTAssertEqual(session.writers, [LocalWriterInfo(name: "iPad"), LocalWriterInfo(name: nil)])
    }

    func testOlderMacsOmitWriters() throws {
        XCTAssertNil(try decode("{\(base)}").writers)
        XCTAssertEqual(try decode("{\(base),\"writers\":[]}").writers, [])
    }

    func testSummaryNamesWritersAndTheMacByItsPairedName() {
        XCTAssertEqual(TypingElsewhere.summary([LocalWriterInfo(name: "iPad")], hostName: "Studio"), text("Typing on \("iPad")"))
        XCTAssertEqual(TypingElsewhere.summary([LocalWriterInfo(name: nil)], hostName: "Studio"), text("Typing on \("Studio")"))
        // Each name once, in the Mac's order.
        XCTAssertEqual(TypingElsewhere.names([LocalWriterInfo(name: nil), LocalWriterInfo(name: "iPad"), LocalWriterInfo(name: nil)],
                                             hostName: "Studio"), ["Studio", "iPad"])
        let two = TypingElsewhere.summary([LocalWriterInfo(name: "iPad"), LocalWriterInfo(name: nil)], hostName: "Studio")
        XCTAssertEqual(two, text("Typing on \(["iPad", "Studio"].formatted(.list(type: .and)))"))
    }

    func testNobodyElseOrUnknownSaysNothingInTheTitle() {
        XCTAssertNil(TypingElsewhere.summary([], hostName: "Studio"))
        XCTAssertNil(TypingElsewhere.summary(nil, hostName: "Studio"))
    }

    func testRefusalsAndNoticesFallBackWhenTheMacDidNotSay() {
        XCTAssertEqual(TypingElsewhere.busyTitle(nil, hostName: "Studio"), text("Typing on Another Device"))
        XCTAssertEqual(TypingElsewhere.busyTitle([LocalWriterInfo(name: nil)], hostName: "Studio"), text("Typing on \("Studio")"))
        XCTAssertEqual(TypingElsewhere.watchingNotice(nil, hostName: "Studio"), text("Another device is typing, so you’re watching."))
        let named = text("Typing on \("iPad")")
        XCTAssertEqual(TypingElsewhere.watchingNotice([LocalWriterInfo(name: "iPad")], hostName: "Studio"),
                       text("\(named), so you’re watching."))
        XCTAssertNotEqual(TypingElsewhere.watchingNotice([LocalWriterInfo(name: "iPad")], hostName: "Studio"),
                          TypingElsewhere.watchingNotice(nil, hostName: "Studio"))
    }

    /// Unpair ends every pairing this device holds with that device, the one
    /// asked for first, so an earlier pairing never keeps it listed.
    func testUnpairEndsEveryPairingWithThatDevice() {
        func device(_ id: String, _ name: String) -> PairedDevice {
            PairedDevice(id: id, name: name, platform: .macos, publicKey: "")
        }
        let phone = PairedDevice(id: "phone", name: "iPhone", platform: .ios, publicKey: "")
        func grant(_ id: String, _ host: PairedDevice) -> DeviceGrant {
            DeviceGrant(id: id, pairingID: "p-" + id, host: host, client: phone, permission: .control,
                        approvalSignature: "", createdAt: .now)
        }
        let studio = device("mac-1", "Studio"), laptop = device("mac-2", "Laptop")
        let older = grant("g1", studio), other = grant("g2", laptop), newer = grant("g3", studio)
        let ended = RemoteTerminalModel.pairings(endedBy: newer, in: [older, other, newer])
        XCTAssertEqual(ended.map(\.id), ["g3", "g1"])
        XCTAssertEqual(RemoteTerminalModel.pairings(endedBy: other, in: [older, other, newer]).map(\.id), ["g2"])
    }

    func testOnlyARefusedTypingNamesWhoTypes() {
        XCTAssertTrue(RemoteTerminalIssue(RelayError.sessionBusy).typingElsewhere)
        XCTAssertFalse(RemoteTerminalIssue(RelayError.readOnly).typingElsewhere)
        XCTAssertFalse(RemoteTerminalIssue(RelayError.offline).typingElsewhere)
    }
}
