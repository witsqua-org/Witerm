import Foundation
import XCTest

@testable import WitermCore

private final class TerminalEventCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func bump() { lock.withLock { value += 1 } }
  func count() -> Int { lock.withLock { value } }
}

final class TerminalEventStreamTests: XCTestCase {
  private let session = LocalSessionInfo(
    id: "11111111-1111-4111-8111-111111111111",
    name: "Shell", createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 111, rows: 39)

  func testSharedGeometryFixturePreservesSessionIdentityAndUnicodeBytes() async throws {
    struct Fixture: Decodable {
      let initial_session: LocalSessionInfo
      let events: [LocalAgentFrame]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = try RemoteWire.decoder().decode(
      Fixture.self,
      from: Data(
        contentsOf: root.appendingPathComponent("protocol/fixtures/terminal-geometry-v1.json")))
    XCTAssertEqual(fixture.initial_session.columns, 80)
    XCTAssertEqual(fixture.initial_session.rows, 24)
    let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage)
    var expected: [LocalTerminalEvent] = []
    for frame in fixture.events {
      XCTAssertEqual(frame.version, 1)
      XCTAssertNil(frame.id)
      XCTAssertNil(frame.ok)
      XCTAssertNil(frame.error)
      XCTAssertNil(frame.status)
      XCTAssertNil(frame.sessions)
      XCTAssertNil(frame.mode)
      switch frame.kind {
      case .geometry:
        let geometry = try XCTUnwrap(frame.session)
        XCTAssertNil(frame.data)
        try RemoteWire.validate(geometry)
        XCTAssertEqual(geometry.id, fixture.initial_session.id)
        XCTAssertEqual(geometry.name, fixture.initial_session.name)
        XCTAssertEqual(geometry.createdAt, fixture.initial_session.createdAt)
        expected.append(.geometry(geometry))
      case .output:
        XCTAssertNil(frame.session)
        expected.append(.output(try XCTUnwrap(frame.data)))
      default: XCTFail("unexpected geometry fixture event")
      }
    }
    XCTAssertEqual(expected.count, 4)
    guard case .geometry(let first) = expected[0], case .geometry(let second) = expected[2] else {
      return XCTFail("geometry must precede its repaint")
    }
    XCTAssertEqual(first.columns, 120)
    XCTAssertEqual(first.rows, 40)
    XCTAssertEqual(second.columns, 90)
    XCTAssertEqual(second.rows, 30)
    let clearHome = Data([27, 91, 50, 74, 27, 91, 72])
    XCTAssertEqual(expected[1], .output(clearHome + Data("observer-size:40x120\r\n".utf8)))
    XCTAssertEqual(expected[3], .output(clearHome + Data("观察 👩‍💻 e\u{301} 30x90\r\n".utf8)))
    for event in expected { _ = streams.yield(event) }
    streams.finish(throwing: nil)
    var actual: [LocalTerminalEvent] = []
    for try await event in streams.events() { actual.append(event) }
    XCTAssertEqual(actual, expected)
  }

  func testPreconsumerEventsAreBoundedOrderedAndRetainFinalError() async throws {
    let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage)
    let events: [LocalTerminalEvent] = (0..<64).map { index in
      index.isMultiple(of: 2) ? .output(Data([UInt8(index)])) : .geometry(session)
    }
    for event in events {
      guard case .enqueued = streams.yield(event) else {
        return XCTFail("bounded event was dropped")
      }
    }
    guard case .dropped = streams.yield(.output(Data([255]))) else {
      return XCTFail("65th event was accepted")
    }
    streams.finish(throwing: RelayError.backpressure)
    var received: [LocalTerminalEvent] = []
    do {
      for try await event in streams.events() { received.append(event) }
      XCTFail("overflow ended successfully")
    } catch { XCTAssertEqual(error as? RelayError, .backpressure) }
    XCTAssertEqual(received, events)
  }

  func testLegacyOutputIgnoresGeometryWithoutAnUnusedEventsQueue() async throws {
    let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage)
    var output = streams.output().makeAsyncIterator()
    _ = streams.output()  // Re-accessing the selected route keeps its queue.
    for _ in 0..<1000 {
      guard case .enqueued = streams.yield(.geometry(session)) else {
        return XCTFail("unused geometry route overflowed")
      }
    }
    let bytes = Data([0, 27, 91, 255])
    guard case .enqueued = streams.yield(.output(bytes)) else {
      return XCTFail("legacy bytes dropped")
    }
    streams.finish(throwing: nil)
    let first = try await output.next()
    let end = try await output.next()
    XCTAssertEqual(first, bytes)
    XCTAssertNil(end)
  }

  func testCrossRouteAccessFailsWithoutTerminatingTheSelectedConsumer() async throws {
    for selectEvents in [true, false] {
      let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage)
      let ended = TerminalEventCounter()
      streams.onTermination { ended.bump() }
      let bytes = Data([27, 91, 50, 74])
      if selectEvents {
        var primary = streams.events().makeAsyncIterator()
        var rejected = streams.output().makeAsyncIterator()
        do {
          _ = try await rejected.next()
          XCTFail("cross-route consumer accepted")
        } catch { XCTAssertEqual(error as? RelayError, .invalidMessage) }
        XCTAssertEqual(ended.count(), 0)
        _ = streams.yield(.output(bytes))
        let first = try await primary.next()
        XCTAssertEqual(first, .output(bytes))
      } else {
        var primary = streams.output().makeAsyncIterator()
        var rejected = streams.events().makeAsyncIterator()
        do {
          _ = try await rejected.next()
          XCTFail("cross-route consumer accepted")
        } catch { XCTAssertEqual(error as? RelayError, .invalidMessage) }
        XCTAssertEqual(ended.count(), 0)
        _ = streams.yield(.output(bytes))
        let first = try await primary.next()
        XCTAssertEqual(first, bytes)
      }
      streams.finish(throwing: nil)
      XCTAssertEqual(ended.count(), 1)
    }
  }
}
