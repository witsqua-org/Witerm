import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// Round 19: a paired terminal's new link (typing or watching again, or a
/// resume in place) gets the Mac's earlier output first, ending in a
/// screenful of line feeds, and tmux's redraw after it. Past a short wait
/// the renderer says it's catching up, over a still picture of the old
/// screen; a fast redraw never does. And whose grid a watching device shows.
@MainActor final class CatchUpTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private var frame: CGRect { CGRect(x: 0, y: 120, width: window.bounds.width, height: window.bounds.height - 154) }
    private let session = LocalSessionInfo(id: "catch", name: "Catch", createdAt: .now, columns: 45, rows: 20)

    /// What the Mac's service sends first on an attach with history.
    private func history(rows: Int) -> Data {
        Data(((1...30).map { "earlier \($0)\r\n" }.joined() + String(repeating: "\n", count: rows)).utf8)
    }

    private func redraw(rows: Int) -> Data {
        Data(("\u{1b}[H\u{1b}[2J" + (1..<rows).map { "row \($0)\r\n" }.joined() + "fixture$ ").utf8)
    }

    /// A shown host, and the one that replaces it for the same terminal.
    private func replacement() async throws -> (old: PairedTerminalHost, new: PairedTerminalHost, link: CatchUpStubLink, container: UIView) {
        let container = UIView(frame: frame)
        window.rootViewController?.view.addSubview(container)
        let oldLink = CatchUpStubLink(session: session)
        let old = PairedTerminalHost(id: UUID(), link: oldLink, mode: .view, fontSize: 14, routes: PairedTerminalRoutes())
        old.surface.frame = container.bounds
        container.addSubview(old.surface)
        oldLink.continuation.yield(.output(redraw(rows: session.rows)))
        try await pause(0.2)
        old.surface.layoutIfNeeded()
        let link = CatchUpStubLink(session: session)
        let new = PairedTerminalHost(id: UUID(), link: link, mode: .view, fontSize: 14, routes: PairedTerminalRoutes(), following: old)
        old.stop()
        new.surface.frame = container.bounds
        container.addSubview(new.surface)
        return (old, new, link, container)
    }

    private func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func testASlowRedrawSaysCatchingUpOverTheOldScreenUntilItArrives() async throws {
        let (_, host, link, container) = try await replacement()
        defer { host.stop(); container.removeFromSuperview() }
        XCTAssertTrue(host.surface.isCovered, "The old screen isn't kept under the new renderer")
        link.continuation.yield(.output(history(rows: session.rows)))
        try await pause(0.2)
        XCTAssertFalse(host.catchingUp, "Catching up… before the threshold")
        try await pause(0.4)
        XCTAssertTrue(host.catchingUp, "Blank but for the cursor past the threshold, and no note")
        XCTAssertTrue(host.surface.isCovered)
        link.continuation.yield(.output(redraw(rows: session.rows)))
        try await pause(0.1)
        XCTAssertFalse(host.catchingUp, "The note stayed after the redraw")
        try await pause(0.4)
        XCTAssertFalse(host.surface.isCovered, "The picture stayed after the redraw")
        XCTAssertEqual(host.surface.catchUpsShown, 1)
    }

    func testAFastRedrawNeverSaysCatchingUp() async throws {
        let (_, host, link, container) = try await replacement()
        defer { host.stop(); container.removeFromSuperview() }
        link.continuation.yield(.output(history(rows: session.rows)))
        link.continuation.yield(.output(redraw(rows: session.rows)))
        try await pause(0.7)
        XCTAssertFalse(host.catchingUp)
        XCTAssertEqual(host.surface.catchUpsShown, 0, "Catching up… flashed on a fast redraw")
        XCTAssertFalse(host.surface.isCovered)
    }

    /// A screen that's blank on the Mac too (a cleared full-screen program)
    /// stops saying so once the Mac has gone quiet.
    func testABlankScreenOnTheMacEndsCatchingUpOnceQuiet() async throws {
        let (_, host, link, container) = try await replacement()
        defer { host.stop(); container.removeFromSuperview() }
        link.continuation.yield(.output(history(rows: session.rows)))
        try await pause(0.6)
        XCTAssertTrue(host.catchingUp)
        link.continuation.yield(.output(Data("\u{1b}[H\u{1b}[2J".utf8)))
        try await pause(RemoteNativeTerminalView.LinkCoordinator.catchUpQuietLimit + 0.4)
        XCTAssertFalse(host.catchingUp, "Still catching up on a screen the Mac leaves blank")
    }

    /// A first open has nothing to keep and nothing to catch up to.
    func testAFirstOpenNeverSaysCatchingUp() async throws {
        let link = CatchUpStubLink(session: session)
        let host = PairedTerminalHost(id: UUID(), link: link, mode: .view, fontSize: 14, routes: PairedTerminalRoutes())
        defer { host.stop() }
        link.continuation.yield(.output(history(rows: session.rows)))
        try await pause(0.7)
        XCTAssertFalse(host.catchingUp)
        XCTAssertFalse(host.surface.isCovered)
    }

    func testScreenHasTextLooksAtTheScreenNotTheScrollback() {
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .view, session: session, fontSize: 14, isInteractive: true)
        let core = surface.terminal.getTerminal()
        XCTAssertFalse(RemoteNativeTerminalView.LinkCoordinator.screenHasText(core))
        surface.terminal.feed(byteArray: Array(history(rows: core.rows))[...])
        XCTAssertFalse(RemoteNativeTerminalView.LinkCoordinator.screenHasText(core), "History scrolled off the screen counts as blank")
        surface.terminal.feed(text: "$ ")
        XCTAssertTrue(RemoteNativeTerminalView.LinkCoordinator.screenHasText(core))
    }

    // MARK: Sized for

    func testWatchingAGridThatIsntThisScreensOwnSizeIsNoticed() async throws {
        let container = UIView(frame: frame)
        window.rootViewController?.view.addSubview(container)
        defer { container.removeFromSuperview() }
        let wide = LocalSessionInfo(id: "wide", name: "Wide", createdAt: .now, columns: 80, rows: 24)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .view, session: wide, fontSize: 14, isInteractive: true)
        var told: [Bool] = []
        surface.otherGridChanged = { told.append($0) }
        surface.frame = container.bounds
        container.addSubview(surface)
        surface.layoutIfNeeded()
        XCTAssertTrue(surface.watchesOtherGrid, "80 × 24 isn't this screen's size")
        // Set to this screen's own size, as when it stops typing.
        let own = surface.watchingFit
        surface.applyGeometry(LocalSessionInfo(id: "wide", name: "Wide", createdAt: .now, columns: own.columns, rows: own.rows))
        surface.layoutIfNeeded()
        XCTAssertFalse(surface.watchesOtherGrid)
        XCTAssertEqual(told, [true, false])
        // Typing is never "another device's size".
        let typing = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: wide, fontSize: 14, isInteractive: true)
        typing.frame = container.bounds
        container.addSubview(typing)
        typing.layoutIfNeeded()
        XCTAssertFalse(typing.watchesOtherGrid)
    }
    // Round 19's "Sized for *device*" wording is gone (Round 20): whose
    // size it is lives in Connected Devices (`ConnectedDevicesTests`).
}

/// A link whose events the test feeds.
private final class CatchUpStubLink: PairedTerminalLink, @unchecked Sendable {
    let session: LocalSessionInfo
    let events: AsyncThrowingStream<LocalTerminalEvent, Error>
    let continuation: AsyncThrowingStream<LocalTerminalEvent, Error>.Continuation

    init(session: LocalSessionInfo) {
        self.session = session
        (events, continuation) = AsyncThrowingStream.makeStream(of: LocalTerminalEvent.self, throwing: Error.self)
    }

    func send(_ data: Data, automatic: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func detach() async throws { continuation.finish() }
    func abort() async { continuation.finish() }
    func disconnect() async { continuation.finish() }
}
