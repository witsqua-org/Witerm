import Foundation
import XCTest

@testable import WitermCore

/// Round 18: the presence stream's messages, against the fixture the Go
/// server tests read too (`protocol/fixtures/relay-presence-v1.json`).
final class RelayPresenceTests: XCTestCase {
  private func fixture() throws -> [String: Any] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/relay-presence-v1.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func part(_ object: [String: Any], _ name: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: try XCTUnwrap(object[name]), options: [.sortedKeys])
  }

  func testWatchRequestMatchesTheFixture() throws {
    let object = try fixture()
    let watch = try XCTUnwrap(object["watch"] as? [String: Any])
    let ids = try XCTUnwrap(watch["grant_ids"] as? [String])
    let ours = try RelayPresence.watchRequest(grantIDs: ids)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: ours) as? NSDictionary, watch as NSDictionary)
    let limits = try XCTUnwrap(object["limits"] as? [String: Int])
    XCTAssertEqual(limits["max_grants"], RelayPresence.maxGrants)
    // More than the limit: only the first 16 are watched.
    let many = (0..<20).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
    let capped = try JSONSerialization.jsonObject(with: try RelayPresence.watchRequest(grantIDs: many)) as? [String: Any]
    XCTAssertEqual((capped?["grant_ids"] as? [String])?.count, RelayPresence.maxGrants)
    XCTAssertThrowsError(try RelayPresence.watchRequest(grantIDs: []))
    XCTAssertThrowsError(try RelayPresence.watchRequest(grantIDs: ["not-an-id"]))
    XCTAssertThrowsError(try RelayPresence.watchRequest(grantIDs: [ids[0], ids[0]]))
  }

  func testPresenceMessagesDecode() throws {
    let object = try fixture()
    let snapshot = try RelayPresence.decode(try part(object, "snapshot"))
    XCTAssertEqual(snapshot, ["11111111-1111-4111-8111-111111111111": true, "22222222-2222-4222-8222-222222222222": false])
    let update = try RelayPresence.decode(try part(object, "update"))
    XCTAssertEqual(update, ["11111111-1111-4111-8111-111111111111": false])
    for bad in [#"{"type":"other","hosts":[]}"#, #"{"type":"presence"}"#, #"{"type":"presence","hosts":[{"grant_id":"x","online":true}]}"#] {
      XCTAssertThrowsError(try RelayPresence.decode(Data(bad.utf8)), bad)
    }
  }
}
