#if os(iOS)
import Foundation
import Observation
import WitermCore

/// A paired terminal that stays connected after Back (Round 18): watching,
/// off screen, with its own renderer still taking the Mac's output, so
/// reopening it is instant (the same renderer and attachment, nothing to
/// redraw). Its model owns it; `PairedKeepAlive` limits how many there are.
@MainActor @Observable final class KeptPairedTerminal {
    enum State: Equatable {
        /// Was typing: the Mac's grid is set to the watching size and typing
        /// is let go (detach ACK), then it attaches to watch.
        case releasing
        /// Watching, connected.
        case live
        /// Let go in the background (detach ACK) or lost; the renderer and
        /// its screen stay, for `resume`.
        case parked
        /// A new watching link is on its way to the same renderer.
        case resuming
        /// Being disconnected; it's no longer listed as connected.
        case closing
    }

    let grant: DeviceGrant
    let session: LocalSessionInfo
    private(set) var state: State
    /// When it was left, for choosing which to disconnect at the limit.
    private(set) var leftAt = Date()
    @ObservationIgnored private(set) var host: PairedTerminalHost
    @ObservationIgnored private(set) var link: any PairedTerminalLink
    /// The grid the Mac last set, for resuming at it.
    @ObservationIgnored var grid: (columns: Int, rows: Int)
    /// The step under way (release, park or resume); the next one waits for it.
    @ObservationIgnored var work: Task<Void, Never>?

    init(grant: DeviceGrant, session: LocalSessionInfo, host: PairedTerminalHost, link: any PairedTerminalLink,
         grid: (columns: Int, rows: Int), state: State) {
        self.grant = grant
        self.session = session
        self.host = host
        self.link = link
        self.grid = grid
        self.state = state
    }

    var key: PairedTerminalKey { PairedTerminalKey(grantID: grant.id, sessionID: session.id) }
    /// Listed as Connected: anything but being disconnected.
    var connected: Bool { state != .closing }

    func set(_ state: State) { self.state = state }

    /// The watching renderer that replaces the typing one after a release.
    func adopt(host: PairedTerminalHost, link: any PairedTerminalLink) {
        self.host = host
        self.link = link
    }

    /// The same renderer, a new link (a resume in place).
    func resumed(with link: any PairedTerminalLink) {
        self.link = link
        host.replace(link)
    }
}

struct PairedTerminalKey: Hashable {
    let grantID: String
    let sessionID: String
}

/// How many paired terminals stay connected, across relay servers.
///
/// The relay server allows a device 4 tunnels at once (`maxClientTunnels`,
/// protocol/relay-v1.md), and every attachment holds one for as long as it
/// lasts, while listing a device's terminals (and, while watching, who types
/// there) needs one more for a moment. So at most 3 attachments live at once,
/// the one on screen included: opening a fourth disconnects the one left
/// longest ago (after the Mac's ACK, before the new one attaches) and the new
/// terminal says which. Memory is bounded the same way: each renderer keeps
/// its screen and 500 lines of scrollback.
@MainActor enum PairedKeepAlive {
    static let limit = 3

    private final class Weak { weak var model: RemoteTerminalModel?; init(_ model: RemoteTerminalModel) { self.model = model } }
    private static var models: [Weak] = []

    static func register(_ model: RemoteTerminalModel) {
        models.removeAll { $0.model == nil }
        models.append(Weak(model))
    }

    private static var all: [RemoteTerminalModel] { models.compactMap(\.model) }

    /// Attachments held now, on screen and kept.
    static var liveCount: Int { all.reduce(0) { $0 + $1.liveLinks } }

    /// Makes room for one more attachment: disconnects kept terminals, the
    /// one left longest ago first, until it fits. Returns the names of those
    /// disconnected and the detaches to wait for before attaching.
    static func makeRoom() -> (names: [String], releases: [Task<Void, Never>]) {
        let candidates = all.flatMap { model in model.kept.filter(\.connected).map { (model, $0) } }
        var names: [String] = [], releases: [Task<Void, Never>] = []
        for index in evictions(live: liveCount, leftAt: candidates.map(\.1.leftAt)) {
            let (model, entry) = candidates[index]
            names.append(entry.session.name)
            releases.append(model.disconnectKept(entry))
        }
        return (names, releases)
    }

    /// Which kept terminals go so one more attachment fits: those left
    /// longest ago first. `live` counts every attachment held now.
    static func evictions(live: Int, leftAt: [Date], limit: Int = limit) -> [Int] {
        let excess = live + 1 - limit
        guard excess > 0 else { return [] }
        return leftAt.indices.sorted { leftAt[$0] < leftAt[$1] }.prefix(excess).map { $0 }
    }

    /// Roughly what the renderers of kept terminals hold, in bytes.
    static var keptBytes: Int { all.flatMap(\.kept).reduce(0) { $0 + $1.host.approximateBytes } }
}

/// Lets a model's listings take a relay tunnel only while one is free: the
/// device's attachments hold the rest (`PairedKeepAlive`).
@MainActor final class TunnelGate {
    /// The relay server's limit per device (`maxClientTunnels`).
    static let tunnels = 4
    private let held: () -> Int
    private var inUse = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(held: @escaping () -> Int) { self.held = held }

    private var capacity: Int { max(1, Self.tunnels - held()) }

    func acquire() async {
        if inUse < capacity { inUse += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if !waiting.isEmpty, inUse <= capacity { waiting.removeFirst().resume(); return }
        inUse = max(0, inUse - 1)
    }
}
#endif
