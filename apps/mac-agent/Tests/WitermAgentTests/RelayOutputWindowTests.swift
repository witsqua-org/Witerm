import Foundation
import XCTest
@testable import WitermCore
@testable import WitermAgent

/// Collects what a window lets out, as the bridge's sender does.
private actor RecordTap {
    private(set) var records: [Data] = []
    private var task: Task<Void, Never>?
    private(set) var finished = false
    private(set) var failure: Error?

    func start(_ window: RelayOutputWindow) {
        task = Task {
            do {
                while let record = try await window.nextRecord() { self.append(record) }
                self.finish(nil)
            } catch { self.finish(error) }
        }
    }
    private func append(_ record: Data) { records.append(record) }
    private func finish(_ error: Error?) { finished = true; failure = error }

    func frames() throws -> [LocalAgentFrame] {
        try records.map { try RemoteWire.decoder().decode(LocalAgentFrame.self, from: $0) }
    }
}

private let session = LocalSessionInfo(id: "77777777-7777-4777-8777-777777777777", name: "Window",
                                       createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)

private func chunk(_ index: Int, _ size: Int = 8000) -> Data {
    Data((0..<size).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0) })
}

final class RelayOutputWindowTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    /// Without acknowledgements at most 8 records and 128 KiB leave; each
    /// acknowledgement lets more out; consecutive output merges into 16 KiB
    /// records, and geometry keeps its place between them.
    func testWindowBoundsWhatIsUnacknowledgedAndKeepsOrder() async throws {
        let window = RelayOutputWindow()
        let tap = RecordTap()
        await tap.start(window)
        var expected: [LocalTerminalEvent] = []
        let producer = Task {
            for index in 0..<64 {
                let event: LocalTerminalEvent = index % 9 == 8
                    ? .geometry(LocalSessionInfo(id: session.id, name: session.name, createdAt: session.createdAt,
                                                 columns: 80 + index, rows: 24))
                    : .output(chunk(index))
                try await window.push(event)
            }
            await window.end()
        }
        for index in 0..<64 {
            expected.append(index % 9 == 8
                ? .geometry(LocalSessionInfo(id: session.id, name: session.name, createdAt: session.createdAt,
                                             columns: 80 + index, rows: 24))
                : .output(chunk(index)))
        }
        try await settle()
        var stats = await window.stats
        XCTAssertGreaterThan(stats.sentFrames, 0)
        XCTAssertLessThanOrEqual(stats.peakRecords, RelayFlowControl.windowRecords)
        XCTAssertLessThanOrEqual(stats.peakBytes, RelayFlowControl.windowBytes)
        let stuck = stats.sentFrames
        try await settle()
        stats = await window.stats
        XCTAssertEqual(stats.sentFrames, stuck, "Nothing more leaves without an acknowledgement")
        // Acknowledge whatever went out until everything has.
        var finished = false
        for _ in 0..<500 {
            try await window.acknowledge(await window.stats.sentFrames)
            try await Task.sleep(for: .milliseconds(5))
            if await tap.finished { finished = true; break }
        }
        XCTAssertTrue(finished)
        _ = try await producer.value
        stats = await window.stats
        XCTAssertLessThanOrEqual(stats.peakRecords, RelayFlowControl.windowRecords)
        XCTAssertLessThanOrEqual(stats.peakBytes, RelayFlowControl.windowBytes)
        // Rebuild the stream from the records: same bytes, same geometry places.
        var bytes = Data()
        var geometry: [(Int, Int)] = []
        for frame in try await tap.frames() {
            switch frame.kind {
            case .output:
                let data = try XCTUnwrap(frame.data)
                XCTAssertLessThanOrEqual(data.count, RelayFlowControl.recordData)
                bytes.append(data)
            case .geometry: geometry.append((bytes.count, try XCTUnwrap(frame.session).columns))
            default: XCTFail("unexpected frame")
            }
        }
        var expectedBytes = Data()
        var expectedGeometry: [(Int, Int)] = []
        for event in expected {
            switch event {
            case .output(let data): expectedBytes.append(data)
            case .geometry(let info): expectedGeometry.append((expectedBytes.count, info.columns))
            }
        }
        XCTAssertEqual(bytes, expectedBytes)
        XCTAssertEqual(geometry.map(\.0), expectedGeometry.map(\.0))
        XCTAssertEqual(geometry.map(\.1), expectedGeometry.map(\.1))
        XCTAssertLessThan(stats.sentFrames, expected.count, "Output should have been merged")
    }

    func testAcknowledgementsNeverGoBackOrPassWhatWasSent() async throws {
        let window = RelayOutputWindow()
        try await window.push(.output(Data("one".utf8)))
        _ = try await window.nextRecord()
        await XCTAssertThrowsErrorAsync(try await window.acknowledge(2))
        let second = RelayOutputWindow()
        try await second.push(.output(Data("one".utf8)))
        _ = try await second.nextRecord()
        try await second.acknowledge(1)
        await XCTAssertThrowsErrorAsync(try await second.acknowledge(0))
        // A failed window refuses more output.
        await XCTAssertThrowsErrorAsync(try await second.push(.output(Data("two".utf8))))
    }

    func testStallsOnlyWhileOutputWaitsForAnAcknowledgement() async throws {
        var limits = RelayOutputWindow.Limits()
        limits.stall = .milliseconds(200)
        let window = RelayOutputWindow(limits: limits)
        try await Task.sleep(for: .milliseconds(300))
        var stalled = await window.stalled()
        XCTAssertFalse(stalled, "Idle isn't stalled")
        try await window.push(.output(Data("x".utf8)))
        _ = try await window.nextRecord()
        try await Task.sleep(for: .milliseconds(300))
        stalled = await window.stalled()
        XCTAssertTrue(stalled)
        try await window.acknowledge(1)
        stalled = await window.stalled()
        XCTAssertFalse(stalled)
    }

    /// The producer waits once enough is waiting, unless a local request
    /// needs the local reader to reach its reply.
    func testPushWaitsAtPullAheadExceptDuringALocalRequest() async throws {
        var limits = RelayOutputWindow.Limits()
        limits.pullAhead = 16_000
        let window = RelayOutputWindow(limits: limits)
        try await window.push(.output(chunk(0)))
        let done = ManagedFlag()
        let producer = Task {
            // The second push reaches the limit and is held there.
            try await window.push(.output(chunk(1)))
            done.set()
        }
        try await settle()
        XCTAssertFalse(done.value, "The producer must wait at the pull-ahead limit")
        var peak = await window.stats.peakPending
        XCTAssertEqual(peak, 16_000)
        await window.beginLocalRequest()
        try await producer.value
        XCTAssertTrue(done.value)
        // While the request is outstanding nothing holds the producer.
        for index in 2..<10 { try await window.push(.output(chunk(index))) }
        peak = await window.stats.peakPending
        XCTAssertEqual(peak, 80_000)
        await window.endLocalRequest()
        await window.close()
    }

    func testDiscardStopsSendingAndNeverHoldsTheProducer() async throws {
        var limits = RelayOutputWindow.Limits()
        limits.pullAhead = 8 * 1024
        let window = RelayOutputWindow(limits: limits)
        try await window.push(.output(chunk(0)))
        let blocked = Task { try await window.push(.output(chunk(1))) }
        try await settle()
        await window.discard()
        try await blocked.value
        for index in 0..<100 { try await window.push(.output(chunk(index))) }
        let next = try await window.nextRecord()
        XCTAssertNil(next)
    }

    func testSplitsOnlyAChunkLargerThanARecord() async throws {
        var limits = RelayOutputWindow.Limits()
        limits.recordData = 4096
        let window = RelayOutputWindow(limits: limits)
        let big = chunk(7, 10_000)
        try await window.push(.output(big))
        await window.end()
        var bytes = Data()
        while let record = try await window.nextRecord() {
            let frame = try RemoteWire.decoder().decode(LocalAgentFrame.self, from: record)
            let data = try XCTUnwrap(frame.data)
            XCTAssertLessThanOrEqual(data.count, 4096)
            bytes.append(data)
            try await window.acknowledge(await window.stats.sentFrames)
        }
        XCTAssertEqual(bytes, big)
        let frames = await window.stats.sentFrames
        XCTAssertEqual(frames, 3)
    }

    /// Records stay within the encrypted record limit even for output made of
    /// bytes whose Base64 is all slashes, which JSON would otherwise escape.
    func testWorstCaseOutputFitsARecord() async throws {
        let window = RelayOutputWindow()
        try await window.push(.output(Data(repeating: 0xff, count: 8192)))
        try await window.push(.output(Data(repeating: 0xff, count: 8192)))
        let record = try await window.nextRecord()
        let size = try XCTUnwrap(record).count
        XCTAssertLessThanOrEqual(size, 49_152)
        XCTAssertLessThan(size, 22_000)
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Sendable,
                               file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
