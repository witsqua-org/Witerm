#if os(iOS)
import Foundation
import WitermCore

/// What a paired terminal's renderer and model use of a connection to one
/// of a Mac's terminals: its `events` (geometry and output, in order, from
/// one stream), typing, resizing, and letting go. `RemoteTerminalAttachment`
/// is the real one, through the relay server; DEBUG builds also have the
/// remote fixture's stand-in (`FixtureMac`), so UI tests can open a paired
/// terminal without a Mac.
protocol PairedTerminalLink: AnyObject, Sendable {
    /// Consumed once, by the renderer.
    var events: AsyncThrowingStream<LocalTerminalEvent, Error> { get }
    /// The terminal as the attach response described it.
    var session: LocalSessionInfo { get }
    func send(_ data: Data, automatic: Bool) async throws
    func resize(columns: Int, rows: Int) async throws
    /// Returns once the Mac acknowledged that this device let go.
    func detach() async throws
    func abort() async
    func disconnect() async
}

extension RemoteTerminalAttachment: PairedTerminalLink {}
#endif
