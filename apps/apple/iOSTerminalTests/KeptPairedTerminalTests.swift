import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// Round 18: the keyboard button floats over the terminal instead of
/// reserving a strip (the owner's "obstruction at the bottom"), and stays
/// off the cursor; a paired terminal's renderer keeps taking output off
/// screen; the limits on terminals kept connected after Back.
@MainActor final class KeptPairedTerminalTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        // No keyboard on screen.
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: window.windowScene?.screen,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: window.bounds.maxY, width: window.bounds.width, height: 0))])
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func settle(_ surface: RemoteNativeTerminalView.TerminalSurface) async {
        for _ in 0..<3 {
            surface.setNeedsLayout()
            surface.layoutIfNeeded()
            surface.terminal.layoutIfNeeded()
            await Task.yield()
        }
    }

    private func cellSize(_ surface: RemoteNativeTerminalView.TerminalSurface) -> CGSize {
        let grid = surface.terminal.getOptimalFrameSize(), core = surface.terminal.getTerminal()
        return CGSize(width: grid.width / CGFloat(core.cols), height: grid.height / CGFloat(core.rows))
    }

    private var frame: CGRect { CGRect(x: 0, y: 120, width: window.bounds.width, height: window.bounds.height - 154) }

    /// With the keyboard down the text takes the whole view and the button
    /// sits over it: Round 16's strip kept 60 pt under the text, three rows.
    func testKeyboardButtonFloatsOverTheTextAndReservesNoSpace() async throws {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Float", createdAt: .now, columns: 45, rows: 40)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        surface.setKeyboardButton({}, identifier: "sshKeyboard")
        surface.frame = frame
        window.rootViewController?.view.addSubview(surface)
        await settle(surface)
        let button = try XCTUnwrap(surface.shownKeyboardButtonFrame, "The keyboard button shows with the keyboard down")
        XCTAssertEqual(surface.readingView.frame.height, surface.bounds.height, accuracy: 0.5, "No strip under the text")
        XCTAssertEqual(surface.terminal.getTerminal().rows, Int(surface.bounds.height / cellSize(surface).height), "Every row that fits")
        XCTAssertLessThanOrEqual(button.maxY, surface.readingView.frame.maxY, "The button sits over the text, not under it")
        XCTAssertGreaterThan(button.minY, surface.readingView.frame.maxY - 60, "At the bottom right")
        surface.removeFromSuperview()
    }

    /// Round 22: with the keyboard down the keyboard button shows whenever
    /// the keyboard can come up, also on a paired terminal that still types
    /// (before, only a watching one passed an action, so a keyboard that
    /// went down while typing left no button), and it brings the keyboard
    /// up itself. A terminal that can only watch gets none.
    func testKeyboardButtonShowsWhenTheKeyboardIsDownWhileTyping() async throws {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Typing", createdAt: .now, columns: 45, rows: 40)
        let typing = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        typing.setKeyboardButton(nil, identifier: "remoteKeyboard")
        typing.frame = frame
        window.rootViewController?.view.addSubview(typing)
        await settle(typing)
        XCTAssertNotNil(typing.shownKeyboardButtonFrame, "Typing with the keyboard down: no keyboard button")
        typing.removeFromSuperview()
        let watching = RemoteNativeTerminalView.TerminalSurface(mode: .view, session: session, fontSize: 14, isInteractive: true)
        watching.setKeyboardButton(nil, identifier: "remoteKeyboard")
        watching.frame = frame
        window.rootViewController?.view.addSubview(watching)
        await settle(watching)
        XCTAssertNil(watching.shownKeyboardButtonFrame, "Can only watch: no keyboard button")
        watching.setKeyboardButton({}, identifier: "remoteKeyboard", pending: true)
        await settle(watching)
        XCTAssertNotNil(watching.shownKeyboardButtonFrame, "Asking the Mac: the button stays, with its spinner")
        watching.removeFromSuperview()
    }

    /// Round 22: a typing grid leaves its part row at the top, as a
    /// watched one does, so the last row sits on the bottom edge either way
    /// and switching between them moves no row.
    func testTypingAndWatchingGridsEndOnTheBottomEdge() async throws {
        let probe = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: LocalSessionInfo(
            id: "p", name: "p", createdAt: .now, columns: 45, rows: 40), fontSize: 14, isInteractive: true)
        let cell = cellSize(probe)
        // A height with a part row left over.
        let view = CGRect(x: 0, y: 120, width: window.bounds.width, height: (cell.height * 30.4).rounded())
        let typing = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: LocalSessionInfo(
            id: UUID().uuidString, name: "T", createdAt: .now, columns: 45, rows: 30), fontSize: 14, isInteractive: true)
        typing.frame = view
        window.rootViewController?.view.addSubview(typing)
        await settle(typing)
        let rows = typing.terminal.getTerminal().rows
        XCTAssertEqual(rows, 30)
        let typingBottom = typing.convert(CGPoint(x: 0, y: typing.terminal.frame.minY + CGFloat(rows) * cell.height), from: typing.terminal.superview)
        XCTAssertEqual(typingBottom.y, typing.bounds.maxY, accuracy: 1, "The typing grid's last row isn't on the bottom edge")
        let watching = RemoteNativeTerminalView.TerminalSurface(mode: .view, session: LocalSessionInfo(
            id: UUID().uuidString, name: "W", createdAt: .now, columns: 45, rows: rows), fontSize: 14, isInteractive: true)
        watching.frame = view
        window.rootViewController?.view.addSubview(watching)
        await settle(watching)
        XCTAssertEqual(watching.terminal.frame.minY, typing.terminal.frame.minY, accuracy: 0.5, "Typing and watching rows differ")
        typing.removeFromSuperview()
        watching.removeFromSuperview()
    }

    /// The button never covers the cursor, and prefers blank cells; only
    /// the button moves, never the grid.
    func testKeyboardButtonStaysOffTheCursor() async throws {
        let cell: CGSize = {
            let probe = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: LocalSessionInfo(
                id: "p", name: "p", createdAt: .now, columns: 45, rows: 40), fontSize: 14, isInteractive: true)
            return cellSize(probe)
        }()
        let rows = Int(frame.height / cell.height)
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Cursor", createdAt: .now, columns: 45, rows: rows)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .view, session: session, fontSize: 14, isInteractive: true)
        surface.setKeyboardButton({}, identifier: "remoteKeyboard")
        surface.frame = frame
        window.rootViewController?.view.addSubview(surface)
        await settle(surface)
        let resting = try XCTUnwrap(surface.shownKeyboardButtonFrame)
        // A full last line, with the cursor at its end, under the button.
        let line = String(repeating: "x", count: 43)
        surface.terminal.feed(text: "\u{1b}[\(rows);1H" + line)
        surface.refreshReadingDocument(outputChanged: true)
        await settle(surface)
        let moved = try XCTUnwrap(surface.shownKeyboardButtonFrame)
        let core = surface.terminal.getTerminal(), size = cellSize(surface)
        let cursor = core.getCursorLocation()
        let top = CGFloat(core.getTopVisibleRow()) * size.height
        let cursorCell = surface.convert(surface.terminal.convert(CGRect(x: CGFloat(cursor.x) * size.width, y: top + CGFloat(cursor.y) * size.height,
                                                                        width: size.width, height: size.height), to: nil), from: nil)
        XCTAssertFalse(moved.intersects(cursorCell), "The button covers the cursor: \(moved) over \(cursorCell)")
        XCTAssertLessThan(moved.minY, resting.minY, "It moved up, out of the way")
        XCTAssertEqual(core.rows, rows, "The grid never changes for the button")
        // Cleared again: back to its resting place.
        surface.terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        surface.refreshReadingDocument(outputChanged: true)
        await settle(surface)
        XCTAssertEqual(surface.shownKeyboardButtonFrame, resting)
        surface.removeFromSuperview()
    }

    /// A paired terminal's renderer lives in its host, not in a view: off
    /// screen it still takes the Mac's output (which is what acknowledges
    /// it, so the relay's flow control never stalls a kept terminal).
    func testHostTakesOutputOffScreen() async throws {
        let link = StubLink(session: LocalSessionInfo(id: "kept", name: "Kept", createdAt: .now, columns: 45, rows: 20))
        let host = PairedTerminalHost(id: UUID(), link: link, mode: .view, fontSize: 14, routes: PairedTerminalRoutes())
        XCTAssertNil(host.surface.window)
        link.continuation.yield(.output(Data("kept-output-marker".utf8)))
        for _ in 0..<20 { await Task.yield() }
        let text = String(data: host.surface.terminal.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("kept-output-marker"), "Off screen, the renderer took nothing")
        // Shown again: the same surface goes into the view, nothing redrawn.
        let container = UIView(frame: frame)
        window.rootViewController?.view.addSubview(container)
        container.addSubview(host.surface)
        XCTAssertTrue(String(data: host.surface.terminal.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("kept-output-marker") == true)
        host.stop()
        container.removeFromSuperview()
        XCTAssertGreaterThan(host.approximateBytes, 0)
        // 5,000 lines of scrollback (Round 24, for long conversations): at
        // most 3 kept renderers, so under 48 MiB at this size.
        XCTAssertLessThan(host.approximateBytes, 16 << 20, "A kept renderer is bounded")
    }

    /// At the limit, opening one more disconnects the kept terminal left
    /// longest ago; below it, none.
    func testKeptTerminalsBeyondTheLimitGoOldestFirst() {
        let now = Date()
        let leftAt = [now.addingTimeInterval(-10), now.addingTimeInterval(-30), now.addingTimeInterval(-20)]
        XCTAssertEqual(PairedKeepAlive.evictions(live: 2, leftAt: Array(leftAt.prefix(2))), [])
        XCTAssertEqual(PairedKeepAlive.evictions(live: 3, leftAt: leftAt), [1], "The one left longest ago")
        XCTAssertEqual(PairedKeepAlive.evictions(live: 4, leftAt: leftAt), [1, 2])
        XCTAssertEqual(PairedKeepAlive.limit, 3, "One of the relay's 4 tunnels per device stays free for listing")
    }

    /// Listings wait for a free tunnel while attachments hold the rest.
    func testListingsWaitForAFreeTunnel() async {
        var held = 3
        let gate = TunnelGate { held }
        await gate.acquire()
        var second = false
        let waiting = Task { @MainActor in await gate.acquire(); second = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(second, "Only one tunnel is free beside three attachments")
        gate.release()
        await waiting.value
        XCTAssertTrue(second)
        gate.release()
        held = 0
        await gate.acquire(); await gate.acquire()
        gate.release(); gate.release()
    }
}

/// A link whose events the test feeds.
private final class StubLink: PairedTerminalLink, @unchecked Sendable {
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
