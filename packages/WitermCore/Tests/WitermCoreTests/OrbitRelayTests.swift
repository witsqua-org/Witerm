import Foundation
import XCTest

@testable import WitermCore

/// Round 32: Orbit from a paired device (relay-v1 `orbit`), against the
/// fixture the Go server's tests read too (`protocol/fixtures/relay-orbit-v1.json`).
final class OrbitRelayTests: XCTestCase {
  private func fixture() throws -> [String: Any] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/relay-orbit-v1.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func part(_ object: [String: Any], _ name: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: try XCTUnwrap(object[name]))
  }

  func testTheWireMatchesTheFixture() throws {
    let fixture = try fixture()
    let limits = try XCTUnwrap(fixture["limits"] as? [String: Any])
    XCTAssertEqual(limits["record_bytes"] as? Int, OrbitRelay.recordLimit)
    XCTAssertEqual(limits["reply_budget_bytes"] as? Int, OrbitRelay.replyBudget)
    XCTAssertEqual(limits["thread_limit"] as? Int, OrbitRelay.threadLimit)
    XCTAssertEqual(limits["detail_chars"] as? Int, OrbitRelay.detailLimit)
    XCTAssertEqual(Set(try XCTUnwrap(limits["operations"] as? [String])), Set(OrbitRelay.operations.map(\.rawValue)))

    let request = try RemoteWire.decoder().decode(LocalAgentRequest.self, from: part(fixture, "request"))
    XCTAssertEqual(request.operation, .orbit)
    let orbit = try XCTUnwrap(request.orbit)
    XCTAssertEqual(OrbitRelay.admit(orbit), orbit)
    XCTAssertEqual(orbit.operation, .send)
    XCTAssertEqual(orbit.text, "Run the unit tests first.")

    let response = try RemoteWire.decoder().decode(LocalAgentFrame.self, from: part(fixture, "response"))
    XCTAssertEqual(response.ok, true)
    let reply = try XCTUnwrap(response.orbit)
    XCTAssertEqual(reply.id, orbit.id)
    XCTAssertEqual(reply.thread?.summary.status, .running)
    XCTAssertEqual(reply.thread?.entries.map(\.text), ["Fix the failing build", "Run the unit tests first."])
    // A frame round-trips through the relay's own coders.
    XCTAssertEqual(try RemoteWire.decoder().decode(LocalAgentFrame.self, from: RemoteWire.encoder().encode(response)), response)

    let orbitRefusal = try RemoteWire.decoder().decode(LocalAgentFrame.self, from: part(fixture, "orbit_refusal"))
    XCTAssertEqual(orbitRefusal.ok, true)
    XCTAssertEqual(orbitRefusal.orbit?.error, .notFound)
    let deviceRefusal = try RemoteWire.decoder().decode(LocalAgentFrame.self, from: part(fixture, "device_refusal"))
    XCTAssertEqual(deviceRefusal.error, .readOnly)
    XCTAssertNil(deviceRefusal.orbit)
  }

  func testADeviceMayAskOnlyWhatOrbitRelayAdmits() throws {
    let thread = UUID().uuidString.lowercased()
    let admitted = [
      OrbitRequest(operation: .status), OrbitRequest(operation: .threads), OrbitRequest(operation: .thread, threadID: thread),
      OrbitRequest(operation: .start, text: "Why did the build fail?", kind: .chat),
      OrbitRequest(operation: .start, text: "Fix it", kind: .task, terminalID: UUID().uuidString.lowercased()),
      OrbitRequest(operation: .send, threadID: thread, text: "Go on"), OrbitRequest(operation: .stop, threadID: thread),
    ]
    for request in admitted { XCTAssertEqual(OrbitRelay.admit(request), request, "\(request.operation)") }
    let refused = [
      OrbitRequest(operation: .configure, apiKey: "sk-elsewhere"), OrbitRequest(operation: .configure, model: "other"),
      OrbitRequest(operation: .takeOver, threadID: thread, agent: "Phone"),
      OrbitRequest(operation: .finish, threadID: thread, text: "Done", agent: "Phone", success: true),
      OrbitRequest(operation: .delete, threadID: thread), OrbitRequest(operation: .clear),
      // Fields the operation doesn't take, or none where it needs one.
      OrbitRequest(operation: .status, apiKey: "sk-elsewhere"), OrbitRequest(operation: .threads, threadID: thread),
      OrbitRequest(operation: .send, threadID: thread, text: "Go on", agent: "Codex"),
      OrbitRequest(operation: .send, threadID: thread, text: "  \n"), OrbitRequest(operation: .send, text: "No thread"),
      OrbitRequest(operation: .start, text: "No kind"), OrbitRequest(operation: .thread, threadID: "not-an-id"),
      OrbitRequest(operation: .send, threadID: thread, text: String(repeating: "x", count: OrbitWire.textLimit + 1)),
      OrbitRequest(version: 2, operation: .status), OrbitRequest(id: "loud", operation: .status),
    ]
    for request in refused { XCTAssertNil(OrbitRelay.admit(request), "\(request.operation) admitted") }
  }

  /// A long thread fits one relay record: excerpts shortened, then the oldest
  /// entries left out and counted; a long list keeps its newest.
  func testRepliesFitOneRecord() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let summary = OrbitThreadSummary(
      id: UUID().uuidString.lowercased(), title: "Long task", kind: .task, status: .running, terminalID: nil,
      updatedAt: now, revision: 300, takenOverBy: nil)
    let entries = (0..<300).map { index in
      OrbitEntry(
        id: UUID().uuidString.lowercased(), at: now, kind: index % 2 == 0 ? .action : .assistant,
        text: index % 2 == 0 ? nil : "Answer \(index)", tool: index % 2 == 0 ? "run_command" : nil,
        terminal: "api", command: "swift test", detail: String(repeating: "output line\n", count: 160))
    }
    let thread = OrbitThreadDetail(
      summary: summary, plan: [], entries: entries, earlierEntries: 12,
      usage: OrbitUsage(inputTokens: 1, cachedTokens: 0, outputTokens: 1), memory: "Earlier work.")
    let fitted = OrbitRelay.fit(OrbitResponse(id: UUID().uuidString.lowercased(), ok: true, thread: thread))
    let detail = try XCTUnwrap(fitted.thread)
    let size = try RemoteWire.encoder().encode(LocalAgentFrame(id: UUID().uuidString.lowercased(), kind: .response, ok: true, orbit: fitted)).count
    XCTAssertLessThanOrEqual(size, OrbitRelay.recordLimit)
    XCTAssertGreaterThan(detail.entries.count, 10, "Kept too little")
    XCTAssertLessThan(detail.entries.count, 300)
    XCTAssertEqual(detail.entries.last?.id, entries.last?.id, "The newest entries stay")
    XCTAssertEqual(detail.earlierEntries + detail.entries.count, 12 + 300)
    XCTAssertTrue(detail.entries.allSatisfy { ($0.detail?.count ?? 0) <= OrbitRelay.detailLimit + 2 })
    XCTAssertEqual(detail.memory, "Earlier work.")

    // A short thread is left alone.
    let short = OrbitThreadDetail(
      summary: summary, plan: [], entries: Array(entries.prefix(2)), earlierEntries: 0,
      usage: OrbitUsage(inputTokens: 1, cachedTokens: 0, outputTokens: 1), memory: nil)
    let untouched = OrbitResponse(id: "x", ok: true, thread: short)
    XCTAssertEqual(OrbitRelay.fit(untouched), untouched)

    let many = (0..<200).map { index in
      OrbitThreadSummary(
        id: UUID().uuidString.lowercased(), title: "Thread \(index)", kind: .chat, status: .idle, terminalID: nil,
        updatedAt: now, revision: index, takenOverBy: nil)
    }
    let list = OrbitRelay.fit(OrbitResponse(id: "x", ok: true, threads: many))
    XCTAssertEqual(list.threads, Array(many.prefix(OrbitRelay.threadLimit)))
  }
}
