import Darwin
import Foundation
import WitermCore

/// Where a pane's history stands, by tmux's own counters: how many lines it
/// has scrolled into history so far, in which history (tmux starts a new one
/// when history is cleared or reflowed), and the pane's height.
struct PaneHistory: Equatable, Sendable {
    let alternate: Bool
    let generation: UInt64
    let added: UInt64
    let size: Int
    let rows: Int

    static let format = "#{alternate_on} #{history_generation} #{history_added} #{history_size} #{pane_height}"

    init?<Line: Collection>(_ line: Line) where Line.Element == UInt8 {
        let fields = String(decoding: line, as: UTF8.self).split(separator: " ")
        guard fields.count == 5, let generation = UInt64(fields[1]), let added = UInt64(fields[2]),
              let size = Int(fields[3]), let rows = Int(fields[4]), size >= 0, rows > 0 else { return nil }
        alternate = fields[0] == "1"
        self.generation = generation; self.added = added; self.size = size; self.rows = rows
    }

    init(alternate: Bool, generation: UInt64, added: UInt64, size: Int, rows: Int) {
        self.alternate = alternate; self.generation = generation; self.added = added; self.size = size; self.rows = rows
    }
}

/// Reads one pane's history for one renderer's tmux client. Each read is a
/// single tmux command, so its counters and lines describe the same moment.
struct HistoryReader: Sendable {
    let runner: CommandRunner
    let base: [String]
    let target: String
    let terminal: String

    func pane() throws -> PaneHistory {
        let output = try run(["display-message", "-p", "-t", target, PaneHistory.format])
        guard let pane = PaneHistory(output.prefix { $0 != 0x0a }) else { throw AgentFailure() }
        return pane
    }

    /// The newest `count` lines of history (fewer if history is shorter) and
    /// the screen's rows, with their colors, and the counters they go with.
    func lines(newest count: Int) throws -> (pane: PaneHistory, history: [Data], screen: [Data]) {
        let output = try run(["display-message", "-p", "-t", target, PaneHistory.format, ";",
                              "capture-pane", "-p", "-e", "-t", target, "-S", String(-max(count, 1)), "-E", "-1", ";",
                              "capture-pane", "-p", "-e", "-t", target], limit: TmuxEngine.captureLimit)
        var lines = output.split(separator: 0x0a, omittingEmptySubsequences: false).map { Data($0) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty, let pane = PaneHistory(lines.removeFirst()), lines.count >= pane.rows else { throw AgentFailure() }
        let screen = Array(lines.suffix(pane.rows))
        // With no history, tmux's capture is the screen's first line.
        let history = pane.size == 0 ? [] : Array(lines.dropLast(pane.rows))
        return (pane, history, screen)
    }

    /// Has tmux redraw this renderer's whole screen.
    func refresh() { _ = try? run(["refresh-client", "-t", terminal]) }

    private func run(_ arguments: [String], limit: Int = 65536) throws -> Data {
        let result = try runner.run(base + arguments, timeout: 2, limit: limit)
        guard result.status == 0 else { throw AgentFailure() }
        return result.output
    }
}

/// Where a VT stream stands after the bytes so far: other bytes may go in
/// only between escape sequences and whole UTF-8 characters. Also whether
/// the stream is inside a synchronized update (DEC mode 2026).
struct VTBoundary {
    private enum State { case ground, escape, escapeIntermediate, csi, string, stringEscape }
    private var state = State.ground
    private var continuation = 0
    private var parameters: [UInt8] = []
    private(set) var synchronized = false
    private static let synchronizedMode = Array("?2026".utf8)

    var atBoundary: Bool { state == .ground && continuation == 0 }

    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes { step(byte) }
    }

    private mutating func step(_ byte: UInt8) {
        // CAN and SUB end any sequence.
        if byte == 0x18 || byte == 0x1a { state = .ground; continuation = 0; return }
        switch state {
        case .ground:
            if continuation > 0 {
                if byte & 0xc0 == 0x80 { continuation -= 1; return }
                continuation = 0
            }
            switch byte {
            case 0x1b: state = .escape
            case 0xc0...0xdf: continuation = 1
            case 0xe0...0xef: continuation = 2
            case 0xf0...0xf7: continuation = 3
            default: break
            }
        case .escape:
            switch byte {
            case 0x5b: state = .csi; parameters.removeAll(keepingCapacity: true)
            case 0x5d, 0x50, 0x58, 0x5e, 0x5f: state = .string
            case 0x20...0x2f: state = .escapeIntermediate
            case 0x1b: break
            default: state = .ground
            }
        case .escapeIntermediate:
            if byte == 0x1b { state = .escape } else if !(0x20...0x2f).contains(byte) { state = .ground }
        case .csi:
            switch byte {
            case 0x40...0x7e:
                if parameters == Self.synchronizedMode {
                    if byte == 0x68 { synchronized = true } else if byte == 0x6c { synchronized = false }
                }
                state = .ground
            case 0x1b: state = .escape
            default: if parameters.count <= Self.synchronizedMode.count { parameters.append(byte) }
            }
        case .string:
            if byte == 0x07 { state = .ground } else if byte == 0x1b { state = .stringEscape }
        case .stringEscape:
            if byte == 0x5c { state = .ground } else { state = .escape; step(byte) }
        }
    }
}

/// Keeps one renderer's scrollback equal to its pane's tmux history.
///
/// A renderer's tmux client is never scrolled (its terminal type has no
/// scroll regions), so lines reach the renderer's scrollback only from here:
/// every line tmux scrolls into the pane's history, once and in order. That
/// includes lines tmux never scrolled on a client because it repainted the
/// screen instead, as it does for a program's synchronized output (Codex-like
/// tools insert their finished lines that way).
///
/// After output, at most every `delay`, it compares tmux's counters with
/// what this renderer has, and puts the new lines in: written over the top
/// of the screen and scrolled off it, then the screen drawn again, inside
/// one synchronized update, so nothing shows half done. tmux then redraws
/// the screen once more, which settles any output still on its way. When
/// tmux clears a pane's history, the renderer's scrollback is cleared too.
final class ScrollbackFill: @unchecked Sendable {
    static let delay: TimeInterval = 0.2
    /// The most line bytes one fill puts in; the rest follow in the next.
    static let maxBytes = 96 * 1024

    private let reader: HistoryReader
    private weak var connection: AgentConnection?
    private let queue = DispatchQueue(label: "com.witerm.agent.scrollback")
    // Lock order: a PTY output barrier, then this, then the connection's queue.
    private let lock = NSLock()
    private var boundary = VTBoundary()
    /// What the renderer's scrollback holds, as tmux counted it; nil until
    /// the next look starts from tmux's current counters.
    private var mark: PaneHistory?
    /// A fill ready for the next point between escape sequences.
    private var pending: (bytes: Data, mark: PaneHistory)?
    /// Changes when the renderer's grid does: a fill read before then is dropped.
    private var epoch = 0
    private var scheduled = false
    private var stopped = false

    init(reader: HistoryReader, connection: AgentConnection, mark: PaneHistory?) {
        self.reader = reader
        self.connection = connection
        self.mark = mark
    }

    /// From the PTY reader: tmux's output, then any fill that was waiting
    /// for a point between escape sequences.
    func forward(_ bytes: Data) -> Bool {
        if bytes.isEmpty { return true }
        lock.lock()
        guard let connection, !stopped else { lock.unlock(); return false }
        let ok = connection.enqueue(LocalAgentFrame(kind: .output, data: bytes))
        boundary.feed(bytes)
        let delivered = ok && deliverPending(to: connection)
        lock.unlock()
        if delivered { queue.async { [reader] in reader.refresh() } }
        schedule(after: Self.delay)
        return ok
    }

    /// Before the renderer is told a new grid, with its output paused.
    func geometryChanged() {
        lock.withLock { epoch += 1; pending = nil; mark = nil }
        schedule(after: Self.delay)
    }

    func stop() { lock.withLock { stopped = true; pending = nil } }

    private func schedule(after delay: TimeInterval) {
        let start = lock.withLock { () -> Bool in
            guard !scheduled, !stopped else { return false }
            scheduled = true
            return true
        }
        if start { queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.look() } }
    }

    /// Called with `lock` held.
    private func deliverPending(to connection: AgentConnection) -> Bool {
        guard let fill = pending, boundary.atBoundary else { return false }
        pending = nil
        return deliver(fill.bytes, mark: fill.mark, to: connection)
    }

    /// Called with `lock` held, between escape sequences.
    private func deliver(_ bytes: Data, mark next: PaneHistory, to connection: AgentConnection) -> Bool {
        // Inside tmux's own synchronized update, its end shows this too.
        let wrapped = boundary.synchronized ? bytes : Data("\u{1b}[?2026h".utf8) + bytes + Data("\u{1b}[?2026l".utf8)
        let frames = stride(from: 0, to: wrapped.count, by: 8192).map {
            LocalAgentFrame(kind: .output, data: wrapped.subdata(in: $0..<min($0 + 8192, wrapped.count)))
        }
        guard connection.enqueue(all: frames) else {
            // No room now: the lines stay in tmux's history for the next look.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.schedule(after: 0) }
            return false
        }
        mark = next
        return true
    }

    private func look() {
        let (start, epoch) = lock.withLock { () -> (PaneHistory?, Int) in scheduled = false; return (mark, self.epoch) }
        guard let now = try? reader.pane() else { return }
        // Full-screen programs add nothing to history.
        if now.alternate { return }
        guard let start, start.rows == now.rows else {
            // A new grid (or a first look): the renderer resized its own
            // scrollback; continue from here.
            lock.withLock { if self.epoch == epoch, mark == start { mark = now } }
            return
        }
        let cleared: Bool
        if start.generation == now.generation {
            guard now.added > start.added else { return }
            cleared = false
        } else {
            // A new history holding only lines added since was cleared; any
            // other new history was reflowed, as the renderer reflowed its own.
            guard now.added >= start.added, Int(clamping: now.added - start.added) >= now.size else {
                lock.withLock { if self.epoch == epoch, mark == start { mark = now } }
                return
            }
            cleared = true
        }
        let expected = cleared ? now.size : Int(clamping: now.added - start.added)
        guard let fill = read(since: start, cleared: cleared, expected: expected) else { schedule(after: Self.delay); return }
        let delivered = lock.withLock { () -> Bool in
            guard self.epoch == epoch, mark == start, !stopped, let connection else { return false }
            guard boundary.atBoundary else { pending = (fill.bytes, fill.mark); return false }
            return deliver(fill.bytes, mark: fill.mark, to: connection)
        }
        if delivered { reader.refresh() }
        if fill.more { schedule(after: 0.05) }
    }

    private func read(since start: PaneHistory, cleared: Bool, expected: Int) -> (bytes: Data, mark: PaneHistory, more: Bool)? {
        // Some slack for lines added since tmux was last asked.
        var wanted = min(expected + 64, TmuxEngine.historyLines)
        for _ in 0..<2 {
            guard let read = try? reader.lines(newest: wanted) else { return nil }
            let pane = read.pane
            guard !pane.alternate, pane.rows == start.rows, read.screen.count == pane.rows,
                  pane.added >= start.added else { return nil }
            let fresh = cleared || pane.generation != start.generation
            // In a cleared history every line is new.
            let added = fresh ? pane.size : Int(clamping: pane.added - start.added)
            if added > read.history.count, read.history.count < pane.size, wanted < TmuxEngine.historyLines {
                wanted = min(added + 64, TmuxEngine.historyLines)
                continue
            }
            // Lines tmux already let go at its limit are gone.
            let lines = Array(read.history.suffix(min(added, pane.size, read.history.count)))
            var taken = 0, bytes = 0
            for line in lines {
                guard taken == 0 || bytes + line.count <= Self.maxBytes else { break }
                bytes += line.count; taken += 1
            }
            let reached = PaneHistory(alternate: false, generation: pane.generation,
                                      added: pane.added - UInt64(lines.count - taken), size: pane.size, rows: pane.rows)
            return (Self.injection(lines: lines.prefix(taken), screen: read.screen, rows: pane.rows, clear: fresh),
                    reached, taken < lines.count)
        }
        return nil
    }

    /// VT bytes that put `lines` at the end of a renderer's scrollback,
    /// oldest first, and leave its screen showing `screen` with its cursor
    /// and colors as they were. Each batch of lines is written over the top
    /// of the screen, then scrolled off it by line feeds at the bottom row.
    static func injection<Lines: Collection>(lines: Lines, screen: [Data], rows: Int, clear: Bool) -> Data where Lines.Element == Data {
        var output = Data("\u{1b}7\u{1b}[r".utf8)
        if clear { output.append(contentsOf: Array("\u{1b}[3J".utf8)) }
        var batch: [Data] = []
        func flush() {
            for (row, line) in batch.enumerated() {
                output.append(contentsOf: Array("\u{1b}[\(row + 1);1H\u{1b}[0m\u{1b}[2K".utf8)); output.append(line)
            }
            output.append(contentsOf: Array("\u{1b}[0m\u{1b}[\(rows);1H".utf8))
            output.append(Data(repeating: 0x0a, count: batch.count))
            batch.removeAll(keepingCapacity: true)
        }
        for line in lines {
            batch.append(line)
            if batch.count == rows { flush() }
        }
        if !batch.isEmpty { flush() }
        for (row, line) in screen.prefix(rows).enumerated() {
            output.append(contentsOf: Array("\u{1b}[\(row + 1);1H\u{1b}[0m\u{1b}[2K".utf8)); output.append(line)
        }
        output.append(contentsOf: Array("\u{1b}[0m\u{1b}8".utf8))
        return output
    }
}
