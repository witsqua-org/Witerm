#if os(iOS) && DEBUG
import Foundation
import UIKit
import WitermCore

/// The remote fixture's Mac, so UI tests can open, type in, watch and leave
/// a paired terminal on the simulator without a Mac or a relay server. It
/// keeps each fixture terminal's grid and who types there as the Mac's
/// service does (docs/../protocol/local-agent-v1.md): typing attaches set
/// the grid; watching ones are told it; one device types at a time (the
/// fixture's Macs don't type alongside); a terminal someone else types in
/// refuses typing. Output is a numbered screen, so a grid that doesn't fill
/// the view shows. In memory only; nothing leaves the app.
///
/// While the app is in the background past the relay server's ping deadline
/// (15 s and 5 s), the server would have closed the tunnel: links still
/// open then fail on return, as a real one does.
@MainActor final class FixtureMac: NSObject {
    static let shared = FixtureMac()
    /// The relay server's ping interval plus its deadline.
    static let serverTimeout: TimeInterval = 20
    /// A relay round trip, roughly, so opening isn't instant.
    static let latency: Duration = .milliseconds(150)

    private var grids: [String: (columns: Int, rows: Int)] = [:]
    private var links: [String: [FixtureLink]] = [:]
    /// Links opened so far, for the layout probe: a resume opens one more.
    private(set) var opened = 0
    private var backgroundedAt: Date?
    /// What's typed on each terminal's current line, for `exit`.
    private var lines: [String: String] = [:]
    /// Terminals whose shell exited (Round 18): no longer listed.
    private var ended: Set<String> = []
    /// How long after `exit` the terminal ends, so a test can leave it first.
    static let exitDelay: Duration = .seconds(10)

    /// Grants whose Mac isn't connected to the relay server now.
    private(set) var offline: Set<String> = RemoteFixture.offline
    /// When each went offline, for tests that time how soon the list says so.
    private(set) var wentOffline: [String: Date] = [:]
    private var presenceWatchers: [UUID: AsyncStream<[String: Bool]>.Continuation] = [:]

    /// Round 19: `-witerm.debug.fixtureRedrawDelay <seconds>` sends each
    /// attach's earlier output at once, ending in a screenful of line feeds
    /// as the Mac's service does, and tmux's redraw only that much later, as
    /// over a slow relay: the screen is blank but for the cursor meanwhile.
    static let redrawDelay = UserDefaults.standard.double(forKey: "witerm.debug.fixtureRedrawDelay")
    /// Round 19: `-witerm.debug.fixtureOtherTyper <seconds>`: another
    /// device, "Alex’s iPad", types in Terminal 1 for that long after the
    /// fixture starts, at its own size (80 × 24), so this device watches its
    /// grid; then it stops, and this device may type again.
    static let otherTyperName = "Alex’s iPad"
    static let otherTyperSession = "fixture-s1"
    private var otherTyperUntil: Date?

    override private init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(returning), name: UIApplication.willEnterForegroundNotification, object: nil)
        // Round 18: `-witerm.debug.fixtureOfflineAfter <seconds>` takes Studio
        // offline that long after the fixture starts, as when a Mac's relay
        // connection drops: its links fail and it refuses new ones.
        let typing = UserDefaults.standard.double(forKey: "witerm.debug.fixtureOtherTyper")
        if typing > 0 {
            otherTyperUntil = Date().addingTimeInterval(typing)
            grids[Self.otherTyperSession] = (80, 24)
        }
        let after = UserDefaults.standard.double(forKey: "witerm.debug.fixtureOfflineAfter")
        if after > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(after))
                self.goOffline("fixture-grant-studio")
            }
        }
    }

    /// The relay server's presence stream, as the fixture's Macs come and go.
    func presenceChanges() -> AsyncStream<[String: Bool]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [String: Bool].self)
        presenceWatchers[id] = continuation
        continuation.onTermination = { _ in Task { @MainActor in FixtureMac.shared.presenceWatchers[id] = nil } }
        return stream
    }

    /// `grantID`'s Mac drops off the relay server.
    func goOffline(_ grantID: String) {
        guard !offline.contains(grantID) else { return }
        offline.insert(grantID)
        wentOffline[grantID] = Date()
        let sessions = Set((RemoteFixture.sessions[grantID] ?? []).map(\.id))
        for link in links.values.flatMap({ $0 }) where sessions.contains(link.session.id) {
            end(link, error: RelayError.transport)
        }
        for watcher in presenceWatchers.values { watcher.yield([grantID: false]) }
    }

    /// A grant's terminals as its Mac lists them now: the grid in use.
    func sessions(for grantID: String) -> [LocalSessionInfo] {
        (RemoteFixture.sessions[grantID] ?? []).filter { !ended.contains($0.id) }.map { listed in
            let grid = grids[listed.id] ?? (listed.columns, listed.rows)
            var writers = listed.writers
            if listed.id == Self.otherTyperSession, let until = otherTyperUntil, Date() < until {
                writers = (writers ?? []) + [LocalWriterInfo(name: Self.otherTyperName)]
            }
            return LocalSessionInfo(id: listed.id, name: listed.name, createdAt: listed.createdAt, columns: grid.columns,
                                    rows: grid.rows, access: listed.access, writers: writers)
        }
    }

    func attach(grant: DeviceGrant, sessionID: String, columns: Int, rows: Int, mode: LocalAttachmentMode,
                history: Bool) async throws -> FixtureLink {
        try await Task.sleep(for: Self.latency)
        guard !offline.contains(grant.id) else { throw RelayError.offline }
        guard let listed = sessions(for: grant.id).first(where: { $0.id == sessionID }) else { throw RelayError.sessionUnavailable }
        if mode == .control {
            guard grant.permission == .control, listed.access != .view else { throw RelayError.readOnly }
            // Someone else types there (the fixture's Mac, or another link).
            let typing = links[sessionID, default: []].contains { $0.mode == .control }
            guard listed.writers?.isEmpty != false, !typing else { throw RelayError.sessionBusy }
        }
        var grid = (columns: listed.columns, rows: listed.rows)
        let changed = mode == .control && (grid.columns != columns || grid.rows != rows)
        if changed { grid = (columns, rows) }
        grids[sessionID] = grid
        let info = LocalSessionInfo(id: listed.id, name: listed.name, createdAt: listed.createdAt,
                                    columns: grid.columns, rows: grid.rows)
        let link = FixtureLink(session: info, mode: mode)
        links[sessionID, default: []].append(link)
        opened += 1
        if changed { link.continuation.yield(.geometry(info)) }
        if history {
            var earlier = (1...80).map { "earlier output \($0)\r\n" }.joined()
            // The service scrolls its history above the screen tmux redraws.
            if Self.redrawDelay > 0 { earlier += String(repeating: "\n", count: info.rows) }
            link.continuation.yield(.output(Data(earlier.utf8)))
        }
        if Self.redrawDelay > 0 {
            Task { @MainActor [link] in
                try? await Task.sleep(for: .seconds(Self.redrawDelay))
                if link.open { link.continuation.yield(.output(self.redraw(info))) }
            }
        } else {
            link.continuation.yield(.output(redraw(info)))
        }
        return link
    }

    /// A typing link's new grid: every link on the terminal gets it, then
    /// the redraw, as tmux does.
    func resize(columns: Int, rows: Int, from link: FixtureLink) throws {
        guard link.open else { throw RelayError.transport }
        guard link.mode == .control else { throw RelayError.readOnly }
        let id = link.session.id
        guard grids[id].map({ $0.columns != columns || $0.rows != rows }) ?? true else { return }
        grids[id] = (columns, rows)
        let info = LocalSessionInfo(id: id, name: link.session.name, createdAt: link.session.createdAt, columns: columns, rows: rows)
        for other in links[id] ?? [] {
            other.continuation.yield(.geometry(info))
            if Self.redrawDelay > 0 {
                Task { @MainActor [other] in
                    try? await Task.sleep(for: .seconds(Self.redrawDelay))
                    if other.open { other.continuation.yield(.output(self.redraw(info))) }
                }
            } else {
                other.continuation.yield(.output(redraw(info)))
            }
        }
    }

    /// Typing echoes to everyone on the terminal; Return gives a new prompt.
    func input(_ data: Data, automatic: Bool, from link: FixtureLink) throws {
        guard link.open else { throw RelayError.transport }
        guard link.mode == .control else { throw RelayError.readOnly }
        guard !automatic else { return }
        var echo = Data()
        let id = link.session.id
        for byte in data {
            if byte == 0x0d {
                echo.append(contentsOf: Array("\r\nfixture$ ".utf8))
                // `exit` ends the terminal a moment later, as its shell would.
                if lines[id] == "exit" { endLater(id) }
                lines[id] = ""
            } else if byte >= 0x20 && byte < 0x7f {
                echo.append(byte)
                lines[id, default: ""].append(Character(UnicodeScalar(byte)))
            }
        }
        guard !echo.isEmpty else { return }
        for other in links[link.session.id] ?? [] { other.continuation.yield(.output(echo)) }
    }

    /// Detach (acknowledged) or a closed connection: the link ends and
    /// typing there is free again.
    func release(_ link: FixtureLink, acknowledged: Bool) async throws {
        if acknowledged { try await Task.sleep(for: Self.latency) }
        guard link.open else { if acknowledged { throw RelayError.transport } else { return } }
        end(link, error: nil)
    }

    /// The terminal's shell exits: every link on it ends, and it's no
    /// longer listed, as on a Mac.
    private func endLater(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.exitDelay)
            ended.insert(id)
            for link in links[id] ?? [] { end(link, error: nil) }
        }
    }

    private func end(_ link: FixtureLink, error: Error?) {
        link.open = false
        links[link.session.id]?.removeAll { $0 === link }
        if let error { link.continuation.finish(throwing: error) } else { link.continuation.finish() }
    }

    private func redraw(_ info: LocalSessionInfo) -> Data {
        var screen = "\u{1b}[H\u{1b}[2J"
        for row in 1..<max(2, info.rows) { screen += "row \(row) of \(info.rows)\r\n" }
        screen += "fixture$ "
        return Data(screen.utf8)
    }

    @objc private func backgrounded() { backgroundedAt = Date() }

    /// Back after longer than the server waits for a pong: the server
    /// closed every tunnel meanwhile.
    @objc private func returning() {
        defer { backgroundedAt = nil }
        guard let since = backgroundedAt, Date().timeIntervalSince(since) > Self.serverTimeout else { return }
        for link in links.values.flatMap({ $0 }) { end(link, error: RelayError.transport) }
    }
}

/// One fixture attachment. Its state is only touched on the main actor.
final class FixtureLink: PairedTerminalLink, @unchecked Sendable {
    let session: LocalSessionInfo
    let events: AsyncThrowingStream<LocalTerminalEvent, Error>
    let continuation: AsyncThrowingStream<LocalTerminalEvent, Error>.Continuation
    let mode: LocalAttachmentMode
    /// Main actor only.
    var open = true

    init(session: LocalSessionInfo, mode: LocalAttachmentMode) {
        self.session = session
        self.mode = mode
        (events, continuation) = AsyncThrowingStream.makeStream(of: LocalTerminalEvent.self, throwing: Error.self)
    }

    func send(_ data: Data, automatic: Bool) async throws {
        try await FixtureMac.shared.input(data, automatic: automatic, from: self)
    }

    func resize(columns: Int, rows: Int) async throws {
        try await FixtureMac.shared.resize(columns: columns, rows: rows, from: self)
    }

    func detach() async throws { try await FixtureMac.shared.release(self, acknowledged: true) }
    func abort() async { try? await FixtureMac.shared.release(self, acknowledged: false) }
    func disconnect() async { try? await detach() }
}
#endif
