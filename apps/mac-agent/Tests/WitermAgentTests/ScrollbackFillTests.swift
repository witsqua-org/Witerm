import Darwin
import Foundation
import XCTest
import WitermCore
@testable import WitermAgent

/// Just enough of a renderer to tell what ends up in its scrollback, with
/// SwiftTerm's rules: a line scrolled off the top of a region that starts at
/// the top row is kept; `CSI n S` and clearing the screen keep nothing;
/// `CSI 3 J` drops the scrollback. Colors and modes are ignored.
final class ScrollbackScreen {
    let columns: Int, rows: Int
    private var grid: [[Character]]
    private(set) var scrollback: [String] = []
    private var x = 0, y = 0, pendingWrap = false
    private var top = 0, bottom: Int
    private var saved = (x: 0, y: 0)
    private var last: Character = " "
    private var pending: [UInt8] = []

    init(columns: Int, rows: Int) {
        self.columns = columns; self.rows = rows; bottom = rows - 1
        grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    /// Scrollback, then the screen, without trailing blanks.
    var lines: [String] { scrollback + grid.map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) } }

    func feed(_ data: Data) {
        var bytes = pending + Array(data)
        pending.removeAll()
        var i = 0
        while i < bytes.count {
            let consumed = step(bytes, i)
            if consumed == 0 { pending = Array(bytes[i...]); break }
            i += consumed
        }
        bytes.removeAll()
    }

    /// Bytes used at `i`, or 0 when the sequence there isn't complete yet.
    private func step(_ b: [UInt8], _ i: Int) -> Int {
        let byte = b[i]
        switch byte {
        case 0x1b:
            guard i + 1 < b.count else { return 0 }
            switch b[i + 1] {
            case 0x5b: return csi(b, i)
            case 0x5d, 0x50, 0x58, 0x5e, 0x5f:
                var j = i + 2
                while j < b.count {
                    if b[j] == 0x07 { return j - i + 1 }
                    if b[j] == 0x1b { guard j + 1 < b.count else { return 0 }; if b[j + 1] == 0x5c { return j - i + 2 } }
                    j += 1
                }
                return 0
            case 0x37: saved = (x, y); return 2
            case 0x38: x = saved.x; y = saved.y; pendingWrap = false; return 2
            case 0x44: lineFeed(); return 2
            case 0x45: x = 0; lineFeed(); return 2
            case 0x4d: reverseIndex(); return 2
            case 0x28, 0x29, 0x2a, 0x2b, 0x23, 0x25, 0x20: return i + 2 < b.count ? 3 : 0
            default: return 2
            }
        case 0x0d: x = 0; pendingWrap = false; return 1
        case 0x0a, 0x0b, 0x0c: lineFeed(); return 1
        case 0x08: if x > 0 { x -= 1 }; pendingWrap = false; return 1
        case 0x09: x = min(columns - 1, (x / 8 + 1) * 8); return 1
        case 0x00..<0x20, 0x7f: return 1
        default:
            let length = byte < 0x80 ? 1 : byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : byte >= 0xc0 ? 2 : 1
            guard i + length <= b.count else { return 0 }
            let text = String(decoding: b[i..<(i + length)], as: UTF8.self)
            put(text.first ?? " ")
            return length
        }
    }

    private func csi(_ b: [UInt8], _ i: Int) -> Int {
        var j = i + 2
        while j < b.count, !(0x40...0x7e).contains(b[j]) { j += 1 }
        guard j < b.count else { return 0 }
        let body = String(decoding: b[(i + 2)..<j], as: UTF8.self)
        let final = b[j]
        let isPrivate = body.hasPrefix("?") || body.hasPrefix(">") || body.hasPrefix("=") || body.hasPrefix("<")
        let numbers = body.trimmingCharacters(in: CharacterSet(charactersIn: "?>=< $")).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func n(_ index: Int = 0, _ fallback: Int = 1) -> Int { index < numbers.count && numbers[index] > 0 ? numbers[index] : fallback }
        guard !isPrivate else { return j - i + 1 }
        switch final {
        case 0x41: y = max(top > y ? 0 : top, y - n()); pendingWrap = false
        case 0x42: y = min(y > bottom ? rows - 1 : bottom, y + n()); pendingWrap = false
        case 0x43: x = min(columns - 1, x + n()); pendingWrap = false
        case 0x44: x = max(0, x - n()); pendingWrap = false
        case 0x45: y = min(rows - 1, y + n()); x = 0; pendingWrap = false
        case 0x46: y = max(0, y - n()); x = 0; pendingWrap = false
        case 0x47, 0x60: x = min(columns - 1, n() - 1); pendingWrap = false
        case 0x48, 0x66: y = min(rows - 1, n(0) - 1); x = min(columns - 1, n(1) - 1); pendingWrap = false
        case 0x64: y = min(rows - 1, n() - 1); pendingWrap = false
        case 0x4a:
            switch numbers.first ?? 0 {
            case 0: clear(row: y, from: x); for row in (y + 1)..<rows { clear(row: row, from: 0) }
            case 1: for row in 0..<y { clear(row: row, from: 0) }; for column in 0...min(x, columns - 1) { grid[y][column] = " " }
            case 2: for row in 0..<rows { clear(row: row, from: 0) }
            case 3: scrollback.removeAll()
            default: break
            }
        case 0x4b:
            switch numbers.first ?? 0 {
            case 0: clear(row: y, from: x)
            case 1: for column in 0...min(x, columns - 1) { grid[y][column] = " " }
            default: clear(row: y, from: 0)
            }
        case 0x58: for column in x..<min(columns, x + n()) { grid[y][column] = " " }
        case 0x40:
            let count = min(n(), columns - x)
            grid[y].insert(contentsOf: Array(repeating: " ", count: count), at: x); grid[y].removeLast(count)
        case 0x50:
            let count = min(n(), columns - x)
            grid[y].removeSubrange(x..<(x + count)); grid[y].append(contentsOf: Array(repeating: " ", count: count))
        case 0x4c: if (top...bottom).contains(y) { for _ in 0..<n() { grid.remove(at: bottom); grid.insert(blank, at: y) } }; x = 0
        case 0x4d: if (top...bottom).contains(y) { for _ in 0..<n() { grid.remove(at: y); grid.insert(blank, at: bottom) } }; x = 0
        case 0x53: for _ in 0..<n() { grid.remove(at: top); grid.insert(blank, at: bottom) }
        case 0x54: for _ in 0..<n() { grid.remove(at: bottom); grid.insert(blank, at: top) }
        case 0x72:
            top = n(0) - 1; bottom = min(rows - 1, n(1, rows) - 1)
            if top >= bottom { top = 0; bottom = rows - 1 }
            x = 0; y = 0; pendingWrap = false
        case 0x62: for _ in 0..<n() { put(last) }
        default: break
        }
        return j - i + 1
    }

    private var blank: [Character] { Array(repeating: " ", count: columns) }
    private func clear(row: Int, from column: Int) { for c in min(column, columns)..<columns { grid[row][c] = " " } }

    private func put(_ character: Character) {
        if pendingWrap { x = 0; lineFeed(); pendingWrap = false }
        grid[y][x] = character
        last = character
        if x == columns - 1 { pendingWrap = true } else { x += 1 }
    }

    private func lineFeed() {
        pendingWrap = false
        if y == bottom {
            let gone = grid.remove(at: top)
            if top == 0 { scrollback.append(String(gone).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)) }
            grid.insert(blank, at: bottom)
        } else if y < rows - 1 { y += 1 }
    }

    private func reverseIndex() {
        pendingWrap = false
        if y == top { grid.remove(at: bottom); grid.insert(blank, at: top) } else if y > 0 { y -= 1 }
    }
}

@MainActor
final class ScrollbackFillTests: XCTestCase {
    private let tmuxPath = "/opt/homebrew/bin/tmux"

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/witerm-agent-test-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private actor Renderer {
        let screen: ScrollbackScreen
        private var stream = Data()
        init(columns: Int, rows: Int) { screen = ScrollbackScreen(columns: columns, rows: rows) }
        func append(_ data: Data) { screen.feed(data); if stream.count < 64 << 20 { stream.append(data) } }
        func contains(_ text: String) -> Bool { stream.range(of: Data(text.utf8)) != nil }
        func lines() -> [String] { screen.lines }
        func scrollback() -> [String] { screen.scrollback }
    }

    private func waitFor(_ text: String, in renderer: Renderer, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await renderer.contains(text) { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("\(text) never reached the renderer")
        throw AgentFailure()
    }

    func testBoundaryFollowsSequencesAcrossChunks() {
        var boundary = VTBoundary()
        boundary.feed(Array("plain".utf8)); XCTAssertTrue(boundary.atBoundary)
        boundary.feed(Array("\u{1b}[38;5".utf8)); XCTAssertFalse(boundary.atBoundary)
        boundary.feed(Array(";196m".utf8)); XCTAssertTrue(boundary.atBoundary)
        boundary.feed(Array("\u{1b}]0;title".utf8)); XCTAssertFalse(boundary.atBoundary)
        boundary.feed(Array("\u{1b}\\".utf8)); XCTAssertTrue(boundary.atBoundary)
        let wide = Array("宽".utf8)
        boundary.feed(wide.prefix(2)); XCTAssertFalse(boundary.atBoundary)
        boundary.feed(wide.suffix(1)); XCTAssertTrue(boundary.atBoundary)
        boundary.feed(Array("\u{1b}(".utf8)); XCTAssertFalse(boundary.atBoundary)
        boundary.feed(Array("B".utf8)); XCTAssertTrue(boundary.atBoundary)
        boundary.feed(Array("\u{1b}[?2026h".utf8)); XCTAssertTrue(boundary.synchronized)
        boundary.feed(Array("\u{1b}[?20".utf8)); XCTAssertFalse(boundary.atBoundary)
        boundary.feed(Array("26l".utf8)); XCTAssertFalse(boundary.synchronized); XCTAssertTrue(boundary.atBoundary)
        boundary.feed(Array("\u{1b}[31".utf8)); boundary.feed([0x18]); XCTAssertTrue(boundary.atBoundary)
    }

    func testInjectionPushesLinesAndRestoresTheScreen() {
        let screen = ScrollbackScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1b}[1;1Hrow one\u{1b}[2;1Hrow two\u{1b}[3;3H".utf8))
        // More lines than rows go in batches; the screen comes back as tmux has it.
        let lines = (1...6).map { Data("pushed \($0)".utf8) }
        let now = ["row two", "fresh", "", "prompt"].map { Data($0.utf8) }
        screen.feed(ScrollbackFill.injection(lines: lines, screen: now, rows: 4, clear: false))
        XCTAssertEqual(screen.scrollback, (1...6).map { "pushed \($0)" })
        XCTAssertEqual(Array(screen.lines.suffix(4)), ["row two", "fresh", "", "prompt"])
        // The cursor is where it was: the next text lands at row 3, column 3.
        screen.feed(Data("X".utf8))
        XCTAssertEqual(screen.lines[6 + 2], "  X")
        screen.feed(ScrollbackFill.injection(lines: [Data("after".utf8)], screen: now, rows: 4, clear: true))
        XCTAssertEqual(screen.scrollback, ["after"])
    }

    /// Round 24: every line that leaves a renderer's screen is in its
    /// scrollback exactly once and in order, whether the program scrolls the
    /// whole screen, scrolls a region that starts at the top, or does that
    /// inside synchronized output as Codex's inline mode does (tmux then
    /// repaints the screen rather than scrolling it). Before, the last case
    /// lost all but about a screenful of every reply in a live window.
    func testRendererScrollbackKeepsEveryLineOnceInOrder() async throws {
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        let tmux = CommandRunner(executable: tmuxPath, environment: configuration.environment)
        let socket = url.appendingPathComponent("tmux.sock").path
        defer { broker.stop(); _ = try? tmux.run(["-S", socket, "kill-server"]) }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await client.create(name: "Fill", columns: 80, rows: 12)
        let attachment = try await client.attach(sessionID: session.id, columns: 80, rows: 12, history: true)
        let renderer = Renderer(columns: 80, rows: 12)
        let reading = Task { for try await data in attachment.output { await renderer.append(data) } }
        defer { reading.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        // A command line in a real terminal keeps the ordinary terminal type.
        let plain = try await client.attach(sessionID: session.id, columns: 80, rows: 12, mode: .view)
        let plainReading = Task { for try await _ in plain.output {} }
        defer { plainReading.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        let terms = try tmux.run(["-S", socket, "list-clients", "-F", "#{client_termname}"])
        XCTAssertEqual(Set(String(decoding: terms.output, as: UTF8.self).split(separator: "\n").map(String.init)),
                       ["xterm-witerm", "xterm-256color"])
        await plain.disconnect()

        // A program like Codex: finished lines go in above a three-row prompt
        // by scrolling rows 1-9, two at a time; SYNC with synchronized output.
        // Three empty lines first keep PLAIN_60 above the prompt's rows.
        let script = url.appendingPathComponent("turns.sh")
        try Data("""
        i=1; while [ $i -le 60 ]; do echo PLAIN_$i; i=$((i+1)); done; printf '\n\n\n'
        insert() { b=1; while [ $b -le 20 ]; do
          printf "$2\\033[1;9r\\033[9H\\n$1_%d\\n$1_%d\\033[r\\033[10H\\033[KPROMPT\\033[11H\\033[K\\033[12H\\033[K$3" $((b*2-1)) $((b*2))
          sleep 0.03; b=$((b+1)); done; }
        insert SYNC '\\033[?2026h' '\\033[?2026l'
        insert REGION '' ''
        printf '\\033[12H\\n'; i=1; while [ $i -le 30 ]; do echo AFTER_$i; i=$((i+1)); done
        echo FILL_''DONE

        """.utf8).write(to: script)
        try await attachment.send(Data("sh \(script.path)\n".utf8))
        try await waitFor("FILL_DONE", in: renderer)
        try await Task.sleep(for: .milliseconds(1200))

        let shown = await renderer.lines().filter { $0.wholeMatch(of: /(PLAIN|SYNC|REGION|AFTER)_\d+/) != nil }
        let expected = (1...60).map { "PLAIN_\($0)" } + (1...40).map { "SYNC_\($0)" } + (1...40).map { "REGION_\($0)" } + (1...30).map { "AFTER_\($0)" }
        XCTAssertEqual(shown.count, expected.count, "Lines missing or repeated: \(Set(expected).subtracting(shown).count) missing")
        XCTAssertEqual(shown, expected)
        await attachment.disconnect()
        try await client.close(sessionID: session.id)
    }

    /// A renderer opened after the output gets the earlier lines directly
    /// above tmux's screen: no blank line where they meet (Round 24 had one,
    /// from scrolling a whole screen of line feeds after the last line's CRLF).
    /// Both with more earlier lines than rows and with fewer.
    func testEarlierOutputMeetsTheScreenWithoutAGap() async throws {
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        let tmux = CommandRunner(executable: tmuxPath, environment: configuration.environment)
        let socket = url.appendingPathComponent("tmux.sock").path
        defer { broker.stop(); _ = try? tmux.run(["-S", socket, "kill-server"]) }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        for count in [40, 12] {
            let session = try await client.create(name: "Gap \(count)", columns: 80, rows: 10)
            let writer = try await client.attach(sessionID: session.id, columns: 80, rows: 10)
            let written = Renderer(columns: 80, rows: 10)
            let writing = Task { for try await data in writer.output { await written.append(data) } }
            try await writer.send(Data("clear; i=1; while [ $i -le \(count) ]; do echo GAP_$i; i=$((i+1)); done; echo GAP_''DONE\n".utf8))
            try await waitFor("GAP_DONE", in: written)
            try await writer.detach()
            writing.cancel()
            let attachment = try await client.attach(sessionID: session.id, columns: 80, rows: 10, mode: .view, history: true)
            let renderer = Renderer(columns: 80, rows: 10)
            let reading = Task { for try await data in attachment.output { await renderer.append(data) } }
            try await waitFor("GAP_DONE", in: renderer)
            try await Task.sleep(for: .milliseconds(400))
            let lines = await renderer.lines()
            let first = try XCTUnwrap(lines.firstIndex(of: "GAP_1"), "\(count) lines")
            XCTAssertEqual(Array(lines[first...].prefix(count)), (1...count).map { "GAP_\($0)" },
                           "Earlier output and the screen don't meet after \(count) lines")
            reading.cancel()
            await attachment.disconnect()
            try await client.close(sessionID: session.id)
        }
    }

    /// Clearing the screen and its history (as `clear` does) clears the
    /// renderer's scrollback too; what follows fills it again.
    func testClearedHistoryClearsTheRendererScrollback() async throws {
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else { throw XCTSkip("tmux is required") }
        let url = try directory()
        let configuration = try AgentConfiguration(stateDirectory: url, shellPath: "/bin/sh")
        let broker = try AgentBroker(configuration: configuration)
        try broker.start()
        let tmux = CommandRunner(executable: tmuxPath, environment: configuration.environment)
        let socket = url.appendingPathComponent("tmux.sock").path
        defer { broker.stop(); _ = try? tmux.run(["-S", socket, "kill-server"]) }
        let client = LocalAgentClient(socketURL: url.appendingPathComponent("agent.sock"))
        let session = try await client.create(name: "Clear", columns: 80, rows: 10)
        let attachment = try await client.attach(sessionID: session.id, columns: 80, rows: 10, history: true)
        let renderer = Renderer(columns: 80, rows: 10)
        let reading = Task { for try await data in attachment.output { await renderer.append(data) } }
        defer { reading.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        try await attachment.send(Data("i=1; while [ $i -le 40 ]; do echo BEFORE_$i; i=$((i+1)); done; echo FIRST_''DONE\n".utf8))
        try await waitFor("FIRST_DONE", in: renderer)
        try await Task.sleep(for: .milliseconds(600))
        let first = await renderer.scrollback()
        XCTAssertTrue(first.contains("BEFORE_1"), "The renderer never got the first lines")
        try await attachment.send(Data("printf '\\033[H\\033[2J\\033[3J'; i=1; while [ $i -le 25 ]; do echo AFTER_$i; i=$((i+1)); done; echo SECOND_''DONE\n".utf8))
        try await waitFor("SECOND_DONE", in: renderer)
        try await Task.sleep(for: .milliseconds(800))
        let lines = await renderer.lines()
        XCTAssertFalse(lines.contains { $0.hasPrefix("BEFORE_") }, "Cleared lines stayed in the renderer's scrollback")
        XCTAssertEqual(lines.filter { $0.wholeMatch(of: /AFTER_\d+/) != nil }, (1...25).map { "AFTER_\($0)" })
        await attachment.disconnect()
        try await client.close(sessionID: session.id)
    }
}
