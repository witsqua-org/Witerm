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

  func testPreconsumerEventsWaitInOrderAndRetainFinalError() async throws {
    let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage)
    // Early events are kept, however many: the producer waits on bytes, not count.
    let events: [LocalTerminalEvent] = (0..<1000).map { index in
      index.isMultiple(of: 2) ? .output(Data([UInt8(index % 256)])) : .geometry(session)
    }
    for event in events {
      guard case .enqueued = streams.yield(event) else {
        return XCTFail("an early event was dropped")
      }
    }
    streams.finish(throwing: RelayError.backpressure)
    var received: [LocalTerminalEvent] = []
    do {
      for try await event in streams.events() { received.append(event) }
      XCTFail("the error was lost")
    } catch { XCTAssertEqual(error as? RelayError, .backpressure) }
    XCTAssertEqual(received, events)
  }

  func testAProducerThatDoesntWaitIsRefusedPastTheHardLimit() {
    let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage, byteLimit: 64 * 1024)
    var accepted = 0
    for _ in 0..<200 {
      guard case .enqueued = streams.yield(.output(Data(repeating: 65, count: 8192))) else { break }
      accepted += 1
    }
    XCTAssertGreaterThan(accepted, 8)
    XCTAssertLessThan(accepted, 200)
  }

  /// A burst many times the limit, from a reader thread that waits for room,
  /// arrives whole and in order at a consumer slower than the producer, and
  /// the queue never holds much more than the limit.
  func testWaitingProducerDeliversABurstWholeAndInOrder() async throws {
    let limit = 32 * 1024
    let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage, byteLimit: limit)
    let chunks = 2000
    let producer = Thread {
      for index in 0..<chunks {
        var chunk = Data(repeating: UInt8(index % 251), count: 1000)
        chunk[0] = UInt8(index & 0xff)
        chunk[1] = UInt8(index >> 8)
        if index.isMultiple(of: 50) { _ = streams.yield(.geometry(self.session)) }
        guard case .enqueued = streams.yield(.output(chunk)) else { return }
        guard streams.waitForRoom() else { return }
      }
      streams.finish(throwing: nil)
    }
    producer.start()
    var next = 0
    var geometries = 0
    for try await event in streams.events() {
      switch event {
      case .output(let data):
        XCTAssertEqual(Int(data[0]) | Int(data[1]) << 8, next, "out of order")
        next += 1
        if next.isMultiple(of: 100) { try await Task.sleep(for: .milliseconds(2)) }
      case .geometry: geometries += 1
      }
    }
    XCTAssertEqual(next, chunks, "output was lost")
    XCTAssertEqual(geometries, chunks / 50)
  }

  func testATaskProducerWaitsForRoomAndAStalledConsumerIsLetGo() async throws {
    let streams = LocalTerminalStreams(
      conflictError: RelayError.invalidMessage, byteLimit: 4096, stallLimit: .milliseconds(300))
    var iterator = streams.events().makeAsyncIterator()
    for _ in 0..<10 { _ = streams.yield(.output(Data(repeating: 1, count: 1000))) }
    // Over the limit: waiting ends when the consumer takes enough.
    let waiting = Task { await streams.room() }
    for _ in 0..<8 { _ = try await iterator.next() }
    let roomed = await waiting.value
    XCTAssertTrue(roomed)
    for _ in 0..<10 { _ = streams.yield(.output(Data(repeating: 1, count: 1000))) }
    // A consumer that takes nothing is given up on, on both kinds of wait.
    let stalled = await streams.room()
    XCTAssertFalse(stalled)
    XCTAssertFalse(streams.waitForRoom())
  }

  func testACancelledConsumerReleasesAWaitingProducer() async throws {
    let streams = LocalTerminalStreams(conflictError: RelayError.invalidMessage, byteLimit: 1024)
    let ended = TerminalEventCounter()
    streams.onTermination { ended.bump() }
    let consumer = Task {
      var count = 0
      for try await _ in streams.events() {
        count += 1
        try await Task.sleep(for: .seconds(60))
      }
      return count
    }
    for _ in 0..<10 { _ = streams.yield(.output(Data(repeating: 1, count: 1000))) }
    let producer = Task.detached { streams.waitForRoom() }
    try await Task.sleep(for: .milliseconds(100))
    consumer.cancel()
    let released = await producer.value
    XCTAssertTrue(released)
    guard case .terminated = streams.yield(.output(Data([1]))) else {
      return XCTFail("a gone consumer still queues")
    }
    XCTAssertEqual(ended.count(), 1)
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
