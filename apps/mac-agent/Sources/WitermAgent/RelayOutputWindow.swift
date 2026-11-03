import Foundation
import WitermCore

/// Flow control for one relayed attachment whose device acknowledges what its
/// renderer takes (relay-v1 `flow` 1).
///
/// The relay closes a tunnel when either leg queues more than 16 messages or
/// 256 KiB, and it can't slow a sender down without breaking both sides'
/// heartbeats. So the Mac limits itself: it keeps at most `records`
/// unacknowledged terminal frames, totalling at most `bytes` of encrypted
/// WebSocket messages, in flight to the device. Whatever the local service
/// produces meanwhile waits here, merged into records of up to `recordData`
/// output bytes, and once `pullAhead` is waiting the bridge stops taking the
/// attachment's events: the local service then stops reading the pane, and
/// tmux coalesces the screen, as for a slow window on this Mac. Output is
/// never dropped, duplicated or reordered, and geometry keeps its place
/// between output bytes.
///
/// A local request (input, resize, detach) answers behind the output queued
/// before it, so while one is outstanding the bridge keeps taking events
/// regardless; that holds at most what the local service had queued
/// (`AgentConnection.deliveryLimit`) and socket buffers, bounded by
/// `hardPending`.
actor RelayOutputWindow {
    struct Limits: Sendable {
        var records = RelayFlowControl.windowRecords
        var bytes = RelayFlowControl.windowBytes
        var recordData = RelayFlowControl.recordData
        var pullAhead = 64 * 1024
        var hardPending = 4 * 1024 * 1024
        var stall: Duration = .seconds(RelayFlowControl.stallSeconds)
    }

    /// What the window has seen, for tests and bounds checks. Byte counts.
    struct Stats: Sendable, Equatable {
        var sentFrames = 0
        var acknowledgedFrames = 0
        var sentOutput = 0
        var peakRecords = 0
        var peakBytes = 0
        var peakPending = 0
        var largestRecord = 0
    }

    enum Failure: Error, Equatable { case invalidAcknowledgement, stalled, overflow, closed }

    let limits: Limits
    private var pending: [LocalTerminalEvent] = []
    private var head = 0
    private var pendingBytes = 0
    private var inFlight: [(frame: Int, bytes: Int)] = []
    private var inFlightHead = 0
    private var inFlightBytes = 0
    private var localRequests = 0
    private var inputEnded = false
    private var discarding = false
    private var failure: Error?
    private var lastProgress = ContinuousClock.now
    private var pushWaiter: CheckedContinuation<Void, Error>?
    private var recordWaiter: CheckedContinuation<Void, Error>?
    /// The sender waits for output rather than for room.
    private var senderNeedsData = false
    private(set) var stats = Stats()

    /// Sees each event as it enters the window, in order. Tests only.
    private let observe: (@Sendable (LocalTerminalEvent) -> Void)?

    init(limits: Limits = Limits(), observe: (@Sendable (LocalTerminalEvent) -> Void)? = nil) {
        self.limits = limits
        self.observe = observe
    }

    private static func cost(_ event: LocalTerminalEvent) -> Int {
        switch event {
        case .output(let data): data.count
        case .geometry: 256
        }
    }

    private var inFlightCount: Int { inFlight.count - inFlightHead }

    /// Moves `events` through the window to `send`, one encoded record at a
    /// time. Returns once the events ended and everything was sent, or, after
    /// `discard`, once the events ended (a local detach still needs its
    /// reader to reach the reply). Throws `Failure.stalled` once output has
    /// waited `limits.stall` for an acknowledgement.
    nonisolated func run(_ events: AsyncThrowingStream<LocalTerminalEvent, Error>,
                         send: @escaping @Sendable (Data) async throws -> Void) async throws {
        enum Part: Sendable { case pumped, sent }
        try await withThrowingTaskGroup(of: Part.self) { group in
            group.addTask {
                for try await event in events {
                    try Task.checkCancellation()
                    try await self.push(event)
                }
                await self.end()
                return .pumped
            }
            group.addTask {
                while let record = try await self.nextRecord() { try await send(record) }
                return .sent
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    if await self.stalled() { throw Failure.stalled }
                }
            }
            var finished = 0
            while finished < 2, try await group.next() != nil { finished += 1 }
            group.cancelAll()
        }
    }

    // MARK: Producer (the local attachment's events)

    /// Takes one event from the local service, waiting while enough is
    /// already waiting and no local request needs the reader to move on.
    func push(_ event: LocalTerminalEvent) async throws {
        if let failure { throw failure }
        guard !discarding else { return }
        if case .output(let data) = event, data.isEmpty { return }
        observe?(event)
        pending.append(event)
        pendingBytes += Self.cost(event)
        stats.peakPending = max(stats.peakPending, pendingBytes)
        if senderNeedsData { wakeRecord() }
        guard pendingBytes <= limits.hardPending else {
            fail(Failure.overflow)
            throw Failure.overflow
        }
        while pendingBytes >= limits.pullAhead, localRequests == 0, !discarding, failure == nil {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pushWaiter = $0 }
            } onCancel: {
                Task { await self.fail(CancellationError()) }
            }
        }
        if let failure { throw failure }
    }

    /// The local events ended; what's waiting is still sent.
    func end() {
        inputEnded = true
        wakeRecord()
    }

    // MARK: Local requests

    func beginLocalRequest() {
        localRequests += 1
        wakePush()
    }

    func endLocalRequest() {
        localRequests = max(0, localRequests - 1)
    }

    /// The device asked to leave: it acknowledges nothing more and renders
    /// nothing after the detach reply, so nothing more is sent, and the
    /// local reader is never held back again.
    func discard() {
        discarding = true
        pending.removeAll()
        head = 0
        pendingBytes = 0
        wakePush()
        wakeRecord()
    }

    // MARK: Sender (the encrypted channel)

    /// The next record to send, encoded, once the window has room for it; nil
    /// when the events ended and everything was sent, or after `discard`.
    /// Consecutive output is merged up to `recordData`; geometry is its own
    /// record, in order.
    func nextRecord() async throws -> Data? {
        while true {
            if let failure { throw failure }
            if discarding { return nil }
            if head < pending.count {
                let record = try build()
                let wire = record.data.count + 16  // ChaChaPoly tag
                if inFlightCount == 0 || (inFlightCount < limits.records && inFlightBytes + wire <= limits.bytes) {
                    commit(record, wire: wire)
                    return record.data
                }
                // Room comes with an acknowledgement; more output alone
                // doesn't change the answer.
                senderNeedsData = false
            } else if inputEnded {
                return nil
            } else {
                senderNeedsData = true
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { recordWaiter = $0 }
            } onCancel: {
                Task { await self.fail(CancellationError()) }
            }
        }
    }

    private struct Record {
        let data: Data
        /// Whole events taken from the front of the queue.
        let events: Int
        /// Or, when the front chunk alone exceeds a record, how much of it.
        let split: Int
        let output: Int
    }

    private func build() throws -> Record {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Predictable sizes: Base64 never grows past 4/3 for its slashes.
        encoder.outputFormatting = .withoutEscapingSlashes
        if case .geometry(let session) = pending[head] {
            return Record(data: try encoder.encode(LocalAgentFrame(kind: .geometry, session: session)),
                          events: 1, split: 0, output: 0)
        }
        var data = Data()
        var index = head
        while index < pending.count, case .output(let chunk) = pending[index] {
            let room = limits.recordData - data.count
            if chunk.count > room {
                // Split a chunk only when it alone exceeds a record.
                guard data.isEmpty else { break }
                data = Data(chunk.prefix(room))
                return Record(data: try encoder.encode(LocalAgentFrame(kind: .output, data: data)),
                              events: 0, split: room, output: room)
            }
            data.append(chunk)
            index += 1
        }
        return Record(data: try encoder.encode(LocalAgentFrame(kind: .output, data: data)),
                      events: index - head, split: 0, output: data.count)
    }

    private func commit(_ record: Record, wire: Int) {
        if record.split > 0, case .output(let chunk) = pending[head] {
            pending[head] = .output(Data(chunk.dropFirst(record.split)))
            pendingBytes -= record.split
        } else {
            for event in pending[head..<(head + record.events)] { pendingBytes -= Self.cost(event) }
            head += record.events
        }
        let outputBytes = record.output
        if head > 256, head * 2 > pending.count {
            pending.removeFirst(head)
            head = 0
        }
        if inFlightCount == 0 { lastProgress = .now }
        stats.sentFrames += 1
        stats.sentOutput += outputBytes
        stats.largestRecord = max(stats.largestRecord, wire)
        inFlight.append((stats.sentFrames, wire))
        inFlightBytes += wire
        stats.peakRecords = max(stats.peakRecords, inFlightCount)
        stats.peakBytes = max(stats.peakBytes, inFlightBytes)
        if pendingBytes < limits.pullAhead { wakePush() }
    }

    // MARK: Acknowledgements

    /// `consumed` counts every terminal frame the device has handed to its
    /// renderer since the attach reply. It never goes back and never passes
    /// what was sent.
    func acknowledge(_ consumed: Int) throws {
        guard consumed >= stats.acknowledgedFrames, consumed <= stats.sentFrames else {
            fail(Failure.invalidAcknowledgement)
            throw Failure.invalidAcknowledgement
        }
        guard consumed > stats.acknowledgedFrames else { return }
        stats.acknowledgedFrames = consumed
        lastProgress = .now
        while inFlightHead < inFlight.count, inFlight[inFlightHead].frame <= consumed {
            inFlightBytes -= inFlight[inFlightHead].bytes
            inFlightHead += 1
        }
        if inFlightHead > 64, inFlightHead * 2 > inFlight.count {
            inFlight.removeFirst(inFlightHead)
            inFlightHead = 0
        }
        wakeRecord()
    }

    /// True once output has waited `limits.stall` for an acknowledgement.
    func stalled() -> Bool {
        guard failure == nil, !discarding, inFlightCount > 0 else { return false }
        return ContinuousClock.now - lastProgress >= limits.stall
    }

    // MARK: Ending

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        pending.removeAll()
        head = 0
        pendingBytes = 0
        let push = pushWaiter, record = recordWaiter
        pushWaiter = nil
        recordWaiter = nil
        push?.resume(throwing: error)
        record?.resume(throwing: error)
    }

    func close() { fail(Failure.closed) }

    private func wakePush() {
        let waiter = pushWaiter
        pushWaiter = nil
        waiter?.resume()
    }

    private func wakeRecord() {
        let waiter = recordWaiter
        recordWaiter = nil
        waiter?.resume()
    }
}
