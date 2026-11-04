import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// Round 14: the terminal leaves the keyboard's space itself, from where the
/// keyboard is now, instead of a height worked out once for the orientation
/// it was shown in.
@MainActor final class TerminalKeyboardInsetTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        postKeyboard(CGRect(x: 0, y: window.bounds.maxY, width: window.bounds.width, height: 0))
        window.isHidden = true
        window = nil
    }

    private func postKeyboard(_ frame: CGRect) {
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: window.windowScene?.screen,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)])
    }

    private func settle(_ surface: RemoteNativeTerminalView.TerminalSurface) async {
        for _ in 0..<3 {
            surface.setNeedsLayout()
            surface.layoutIfNeeded()
            surface.terminal.layoutIfNeeded()
            await Task.yield()
        }
    }

    private func cellHeight(_ surface: RemoteNativeTerminalView.TerminalSurface) -> CGFloat {
        surface.terminal.getOptimalFrameSize().height / CGFloat(surface.terminal.getTerminal().rows)
    }

    /// A docked keyboard covers the bottom of the screen: the text ends at
    /// its top, the rows are the whole cells above it, and they come back
    /// once it has gone.
    func testGridFitsAboveTheKeyboardAndGetsItsRowsBack() async throws {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Inset", createdAt: .now, columns: 45, rows: 40)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        let height = window.bounds.height
        surface.frame = CGRect(x: 0, y: 120, width: window.bounds.width, height: height - 120 - 34)
        window.rootViewController?.view.addSubview(surface)
        await settle(surface)
        let full = surface.terminal.getTerminal().rows
        XCTAssertEqual(surface.readingView.frame.maxY, surface.bounds.maxY, accuracy: 0.5)

        let keyboard = CGRect(x: 0, y: height - 336, width: window.bounds.width, height: 336)
        postKeyboard(keyboard)
        await settle(surface)
        let above = keyboard.minY - surface.frame.minY
        XCTAssertEqual(surface.readingView.frame.maxY, above, accuracy: 0.5, "The text must end at the keyboard's top")
        XCTAssertEqual(surface.terminal.getTerminal().rows, Int(above / cellHeight(surface)), "Whole rows above the keyboard")

        postKeyboard(CGRect(x: 0, y: height, width: window.bounds.width, height: 336))
        await settle(surface)
        XCTAssertEqual(surface.terminal.getTerminal().rows, full, "The rows come back once the keyboard has gone")
        XCTAssertEqual(surface.readingView.frame.maxY, surface.bounds.maxY, accuracy: 0.5)
    }

    // MARK: The overlap, from the frames measured on the iPhone 18 Pro

    private let portrait = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
    /// The terminal under the navigation bar, down to the home indicator.
    private let portraitView = CGRect(x: 0, y: 118, width: 402, height: 722)
    /// The terminal with the bar hidden for typing, inside the safe area.
    private let landscapeView = CGRect(x: 62, y: 2, width: 750, height: 380)
    private let portraitKeyRow = CGRect(x: 0, y: 822, width: 402, height: 52)
    private let landscapeKeyRow = CGRect(x: 0, y: 350, width: 874, height: 52)

    private func overlap(_ view: CGRect, _ screen: CGRect, keyRow: CGRect?, keyRowWindow: CGRect? = nil,
                         reported: CGRect?, for reportedScreen: CGRect? = nil) -> CGFloat? {
        TerminalKeyboardOverlap.bottom(view: view, screen: screen, keyRow: keyRow, keyRowWindow: (keyRowWindow ?? screen).size,
                                       reported: reported.map { ($0, (reportedScreen ?? screen).size) })
    }

    /// With a hardware keyboard only the key row shows, and the text ends on it.
    func testKeyRowAloneCoversOnlyItsOwnHeight() {
        XCTAssertEqual(overlap(portraitView, portrait, keyRow: portraitKeyRow, reported: portraitKeyRow), 18)
        XCTAssertEqual(overlap(landscapeView, landscape, keyRow: landscapeKeyRow, reported: landscapeKeyRow), 32)
    }

    /// Rotating with the key row up reports nothing: the last report is
    /// from the other orientation. The key row where it is now decides.
    func testRotatingWithTheKeyRowUpUsesWhereTheKeyRowIsNow() {
        // Portrait → landscape: the portrait report would put the keyboard off
        // screen, leaving the terminal 32 pt under the key row.
        XCTAssertEqual(overlap(landscapeView, landscape, keyRow: landscapeKeyRow, reported: portraitKeyRow, for: portrait), 32)
        // Landscape → portrait: the landscape report (top at 350) would leave
        // 490 pt of the screen empty (45 × 13 instead of 45 × 41).
        XCTAssertEqual(overlap(portraitView, portrait, keyRow: portraitKeyRow, reported: landscapeKeyRow, for: landscape), 18)
        // This view has rotated but the key row's window hasn't yet: not
        // known, so the last value stays rather than a grid for the old
        // orientation flashing (45 × 13 for 28 ms in the first fixed build).
        XCTAssertNil(overlap(portraitView, portrait, keyRow: landscapeKeyRow, keyRowWindow: landscape,
                             reported: landscapeKeyRow, for: landscape))
        XCTAssertNil(overlap(landscapeView, landscape, keyRow: portraitKeyRow, keyRowWindow: portrait,
                             reported: portraitKeyRow, for: portrait))
        // A stale report alone is ignored, never applied.
        XCTAssertEqual(overlap(landscapeView, landscape, keyRow: nil, reported: portraitKeyRow, for: portrait), 0)
    }

    /// The software keyboard: the key row sits on it and tops it.
    func testKeyRowOnTheSoftwareKeyboardTopsIt() {
        let row = CGRect(x: 0, y: 486, width: 402, height: 52)
        XCTAssertEqual(overlap(portraitView, portrait, keyRow: row, reported: CGRect(x: 0, y: 486, width: 402, height: 388)), 354)
        // Before a report in this orientation, the key row alone still says where it is.
        let landscapeRow = CGRect(x: 0, y: 150, width: 874, height: 52)
        XCTAssertEqual(overlap(landscapeView, landscape, keyRow: landscapeRow, reported: CGRect(x: 0, y: 486, width: 402, height: 388), for: portrait), 232)
    }

    /// Another field's keyboard (the find bar's) counts only when reported
    /// for this orientation, and nothing counts once it has gone.
    func testOtherKeyboardsAndHiddenOnes() {
        let keyboard = CGRect(x: 0, y: 538, width: 402, height: 336)
        XCTAssertEqual(overlap(portraitView, portrait, keyRow: nil, reported: keyboard), 302)
        XCTAssertEqual(overlap(landscapeView, landscape, keyRow: nil, reported: keyboard, for: portrait), 0)
        XCTAssertEqual(overlap(portraitView, portrait, keyRow: nil, reported: CGRect(x: 0, y: 874, width: 402, height: 0)), 0)
        XCTAssertEqual(overlap(portraitView, portrait, keyRow: nil, reported: nil), 0)
        // Hiding moves the key row below the screen at once, and it leaves
        // its window about 0.4 s later, when UIKit says the keyboard hid and
        // the navigation bar returns. Until then the last value stands, so
        // the rows come back with the bar in one resize.
        let leaving = CGRect(x: 0, y: 402, width: 874, height: 52), gone = CGRect(x: 0, y: 402, width: 874, height: 0)
        XCTAssertNil(overlap(landscapeView, landscape, keyRow: leaving, reported: gone))
        XCTAssertEqual(overlap(landscapeView, landscape, keyRow: nil, reported: gone), 0)
        XCTAssertEqual(TerminalKeyboardOverlap.bottom(view: landscapeView, screen: landscape, keyRow: leaving,
                                                      reported: (gone, landscape.size), hiddenSinceKeyRowMoved: true), 0)
    }

    /// An undocked iPad keyboard floats away from the bottom and covers no
    /// band of the terminal; the overlap never exceeds the view.
    func testFloatingKeyboardAndBounds() {
        let pad = CGRect(x: 0, y: 0, width: 1180, height: 820)
        let view = CGRect(x: 0, y: 74, width: 1180, height: 726)
        XCTAssertEqual(overlap(view, pad, keyRow: CGRect(x: 400, y: 300, width: 320, height: 52),
                               reported: CGRect(x: 400, y: 300, width: 320, height: 260)), 0)
        XCTAssertEqual(overlap(view, pad, keyRow: CGRect(x: 0, y: 768, width: 1180, height: 52), reported: nil), 32)
        XCTAssertEqual(overlap(CGRect(x: 0, y: 700, width: 402, height: 100), portrait, keyRow: nil,
                               reported: CGRect(x: 0, y: 500, width: 402, height: 374)), 100)
        XCTAssertEqual(overlap(CGRect(x: 0, y: 0, width: 402, height: 300), portrait, keyRow: nil,
                               reported: CGRect(x: 0, y: 500, width: 402, height: 374)), 0)
    }

    /// A view-only grid keeps the Mac's size whatever the keyboard does;
    /// only the part it can scroll through gets shorter.
    func testReadOnlyGridKeepsItsSizeAboveTheKeyboard() async throws {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Inset", createdAt: .now, columns: 80, rows: 24)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .view, session: session, fontSize: 14, isInteractive: true)
        surface.frame = CGRect(x: 0, y: 120, width: window.bounds.width, height: window.bounds.height - 154)
        window.rootViewController?.view.addSubview(surface)
        await settle(surface)
        postKeyboard(CGRect(x: 0, y: window.bounds.height - 336, width: window.bounds.width, height: 336))
        await settle(surface)
        XCTAssertEqual(surface.terminal.getTerminal().cols, 80)
        XCTAssertEqual(surface.terminal.getTerminal().rows, 24)
    }

    /// Round 17, the black half screen: a typing view with the keyboard up
    /// fits the rows above it, and hiding the keyboard switched to watching
    /// the Mac's grid, still that size, so half the screen stayed empty. The
    /// size this view watches at is the whole view less the keyboard
    /// button's strip, whatever the keyboard does meanwhile, and a watched
    /// grid of that size fills the text area.
    func testWatchingFitIsTheKeyboardHiddenSizeAndFillsTheView() async throws {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Fit", createdAt: .now, columns: 45, rows: 40)
        let typing = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        let frame = CGRect(x: 0, y: 120, width: window.bounds.width, height: window.bounds.height - 154)
        typing.frame = frame
        window.rootViewController?.view.addSubview(typing)
        await settle(typing)
        postKeyboard(CGRect(x: 0, y: window.bounds.height - 336, width: window.bounds.width, height: 336))
        await settle(typing)
        let cell = cellHeight(typing)
        let above = typing.terminal.getTerminal().rows
        let fit = typing.watchingFit
        // Round 18: the keyboard button floats over the text, so no strip.
        XCTAssertEqual(fit.rows, Int(frame.height / cell), "The whole view")
        XCTAssertGreaterThan(fit.rows, above + 10, "Not the rows above the keyboard")
        XCTAssertEqual(fit.columns, typing.terminal.getTerminal().cols, "The keyboard never changes the width")

        let watched = LocalSessionInfo(id: session.id, name: "Fit", createdAt: .now, columns: fit.columns, rows: fit.rows)
        let watching = RemoteNativeTerminalView.TerminalSurface(mode: .view, session: watched, fontSize: 14, isInteractive: true)
        watching.setKeyboardButton({}, identifier: "remoteKeyboard")
        postKeyboard(CGRect(x: 0, y: window.bounds.height, width: window.bounds.width, height: 336))
        watching.frame = frame
        window.rootViewController?.view.addSubview(watching)
        await settle(watching)
        let blank = watching.readingView.frame.height - watching.terminal.frame.height
        XCTAssertGreaterThanOrEqual(blank, -1, "The grid runs below the text area")
        XCTAssertLessThan(blank, cell, "\(blank) pt blank under the watched grid")
        typing.removeFromSuperview(); watching.removeFromSuperview()
    }
}
