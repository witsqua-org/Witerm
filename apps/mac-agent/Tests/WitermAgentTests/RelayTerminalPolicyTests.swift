import Foundation
import XCTest
import WitermCore
@testable import WitermAgent

final class RelayTerminalPolicyTests: XCTestCase {
    func testViewCannotControlOrResizeButCanListAndAttachView() throws {
        let id = UUID().uuidString.lowercased()
        let encoder = JSONEncoder()
        XCTAssertNoThrow(try RelayTerminalPolicy.request(encoder.encode(LocalAgentRequest(operation: .list)), attached: false, permission: .view))
        XCTAssertNoThrow(try RelayTerminalPolicy.request(encoder.encode(LocalAgentRequest(operation: .attach, sessionID: id, columns: 80, rows: 24, mode: .view)), attached: false, permission: .view))
        for request in [LocalAgentRequest(operation: .attach, sessionID: id, columns: 80, rows: 24, mode: .control),
                        LocalAgentRequest(operation: .input, data: Data("never sent".utf8)),
                        LocalAgentRequest(operation: .resize, columns: 80, rows: 24)] {
            XCTAssertThrowsError(try RelayTerminalPolicy.request(encoder.encode(request), attached: request.operation != .attach, permission: .view)) {
                XCTAssertEqual(($0 as? AgentFailure)?.code, .readOnly)
            }
        }
    }

    func testRemoteSurfaceExcludesCreateCloseAndUnexpectedFields() throws {
        let encoder = JSONEncoder()
        for operation in [LocalAgentOperation.create, .close, .share, .rename, .access, .guest] {
            XCTAssertThrowsError(try RelayTerminalPolicy.request(encoder.encode(LocalAgentRequest(operation: operation)), attached: false, permission: .control))
        }
        // A recipient may send only its invitation proof, never a peer or a key.
        XCTAssertNoThrow(try RelayTerminalPolicy.request(encoder.encode(LocalAgentRequest(operation: .redeem, proof: Data(count: 32))), attached: false, permission: .view))
        let forged = LocalRemotePeer(deviceID: UUID().uuidString.lowercased(), name: "Forged", pairingID: UUID().uuidString.lowercased())
        XCTAssertThrowsError(try RelayTerminalPolicy.request(encoder.encode(LocalAgentRequest(operation: .redeem, proof: Data(count: 32), peer: forged)), attached: false, permission: .view))
        XCTAssertThrowsError(try RelayTerminalPolicy.request(encoder.encode(LocalAgentRequest(operation: .list, peer: forged)), attached: false, permission: .control))
        XCTAssertThrowsError(try RelayTerminalPolicy.request(encoder.encode(LocalAgentRequest(operation: .redeem, proof: Data(count: 31))), attached: false, permission: .view))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(LocalAgentRequest(operation: .list))) as? [String: Any])
        raw["command"] = "not an API"
        XCTAssertThrowsError(try RelayTerminalPolicy.request(JSONSerialization.data(withJSONObject: raw), attached: false, permission: .control))
        XCTAssertThrowsError(try RelayTerminalPolicy.request(Data(repeating: 32, count: 49_153), attached: false, permission: .control))
    }
}
