import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// Selection looks and moves like selection elsewhere in iOS: the tint's
/// highlight behind text that keeps its color, and handles that drag the
/// start or end while a drag anywhere else scrolls.
@MainActor final class TerminalSelectionTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func surface() -> RemoteNativeTerminalView.TerminalSurface {
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Selection", createdAt: .now, columns: 40, rows: 20)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        surface.frame = CGRect(x: 0, y: 120, width: 402, height: 600)
        window.rootViewController?.view.addSubview(surface)
        surface.layoutIfNeeded()
        surface.terminal.layoutIfNeeded()
        return surface
    }

    func testSelectionUsesTheTintAndKeepsTheTextColor() {
        let terminal = surface().terminal
        let tint = terminal.tintColor.resolvedColor(with: terminal.traitCollection)
        XCTAssertEqual(terminal.selectionHandleColor, tint)
        XCTAssertEqual(terminal.selectedTextForegroundColor, terminal.nativeForegroundColor)
        var alpha: CGFloat = 0
        terminal.selectedTextBackgroundColor.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertLessThan(alpha, 0.5, "The highlight must let the text show through")
    }

    func testHandlesAreFoundAtTheSelectionsEndsOnly() {
        let terminal = surface().terminal
        terminal.feed(text: "alpha bravo charlie\r\n")
        let frame = terminal.getOptimalFrameSize(), core = terminal.getTerminal()
        let cell = CGSize(width: frame.width / CGFloat(core.cols), height: frame.height / CGFloat(core.rows))
        XCTAssertNil(terminal.selectionHandle(near: .zero), "No selection, no handles")
        // "bravo": columns 6 to 11 on the first row.
        terminal.beginSelection(at: CGPoint(x: cell.width * 7.5, y: cell.height / 2))
        XCTAssertEqual(terminal.selection.getSelectedText(), "bravo")
        XCTAssertEqual(terminal.selectionHandle(near: CGPoint(x: cell.width * 6, y: 0)), .start)
        XCTAssertEqual(terminal.selectionHandle(near: CGPoint(x: cell.width * 11, y: cell.height)), .end)
        XCTAssertNil(terminal.selectionHandle(near: CGPoint(x: cell.width * 30, y: cell.height * 10)),
                     "A drag away from the handles scrolls")
    }

    /// Round 15: a handle is grabbed only within the 44 pt square centered on
    /// its knob, never from the text next to it.
    func testHandlesAreGrabbedOnlyOnTheirKnobs() throws {
        let terminal = surface().terminal
        terminal.feed(text: "\r\nalpha bravo charlie\r\n")
        let frame = terminal.getOptimalFrameSize(), core = terminal.getTerminal()
        let cell = CGSize(width: frame.width / CGFloat(core.cols), height: frame.height / CGFloat(core.rows))
        // "alpha bravo charlie" on the second row; select "charlie" (columns 12 to 19).
        terminal.beginSelection(at: CGPoint(x: cell.width * 14.5, y: cell.height * 1.5))
        XCTAssertEqual(terminal.selection.getSelectedText(), "charlie")
        let knobs = try XCTUnwrap(terminal.selectionKnobs())
        XCTAssertEqual(knobs.start.x, cell.width * 12, accuracy: 0.01)
        XCTAssertEqual(knobs.start.y, cell.height - 6, accuracy: 0.01, "The start's knob hangs above the row")
        XCTAssertEqual(knobs.end.x, cell.width * 19, accuracy: 0.01)
        XCTAssertEqual(knobs.end.y, cell.height * 2 + 6, accuracy: 0.01, "The end's knob hangs below the row")
        XCTAssertEqual(terminal.selectionHandle(near: knobs.start), .start)
        XCTAssertEqual(terminal.selectionHandle(near: knobs.end), .end)
        XCTAssertEqual(terminal.selectionHandle(near: CGPoint(x: knobs.start.x - 21, y: knobs.start.y + 21)), .start, "The target is 44 pt")
        XCTAssertEqual(terminal.selectionHandle(near: CGPoint(x: knobs.end.x + 21, y: knobs.end.y - 21)), .end, "The target is 44 pt")
        // On the selected text, about 30 pt from a knob: the old target (22 pt
        // plus half a row from the text's corner) took these.
        XCTAssertNil(terminal.selectionHandle(near: CGPoint(x: knobs.start.x + 25, y: knobs.start.y + 6 + cell.height * 0.8)))
        XCTAssertNil(terminal.selectionHandle(near: CGPoint(x: knobs.start.x + 10, y: knobs.start.y + 30)))
        XCTAssertNil(terminal.selectionHandle(near: CGPoint(x: knobs.end.x - 25, y: knobs.end.y - 6 - cell.height * 0.8)))
        // The edit menu is placed beside the selection and its knobs.
        let bounds = try XCTUnwrap(terminal.selectionBounds())
        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(knobs.start))
        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(knobs.end))
        XCTAssertLessThan(bounds.height, cell.height + 25, "One row, with its knobs")
    }

    /// Round 15: only SwiftTerm's mouse drag may begin besides scrolling, and
    /// only while the program asks for the mouse; a plain shell never does.
    func testDragsReachTheProgramOnlyInMouseMode() throws {
        let terminal = surface().terminal
        func foreignPans() -> [UIPanGestureRecognizer] {
            (terminal.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
                .filter { $0 !== terminal.panGestureRecognizer && !terminal.allowsMouseDrag($0) }
        }
        XCTAssertEqual(terminal.getTerminal().mouseMode, .off)
        let plain = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        XCTAssertFalse(plain.contains { terminal.allowsMouseDrag($0) }, "A plain shell has no mouse drag")
        // A program turns on mouse reporting (as tmux `mouse on` does).
        terminal.feed(text: "\u{1b}[?1002h")
        XCTAssertNotEqual(terminal.getTerminal().mouseMode, .off)
        let pans = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        let mouse = try XCTUnwrap(pans.first { terminal.allowsMouseDrag($0) }, "SwiftTerm's mouse drag must be found")
        XCTAssertTrue(terminal.gestureRecognizerShouldBegin(mouse))
        // Turned off again: the drag scrolls.
        terminal.feed(text: "\u{1b}[?1002l")
        XCTAssertEqual(terminal.getTerminal().mouseMode, .off)
        XCTAssertFalse(terminal.allowsMouseDrag(mouse))
        // With no selection, nothing but scrolling begins.
        let beginning = foreignPans().filter { terminal.gestureRecognizerShouldBegin($0) }
        XCTAssertTrue(beginning.isEmpty, "No other drag begins in a plain shell: \(beginning)")
        // A watched (view-only) terminal never sends the mouse.
        terminal.feed(text: "\u{1b}[?1002h")
        terminal.disableInput()
        let again = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        XCTAssertFalse(again.contains { terminal.allowsMouseDrag($0) }, "Without control, drags never reach the program")
    }

    /// Round 15: the long press takes UIKit's 0.5 s, not 0.35 s.
    func testLongPressWaitsForTheSystemDuration() {
        let terminal = surface().terminal
        let presses = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }.filter(\.isEnabled)
        XCTAssertEqual(presses.count, 1)
        XCTAssertEqual(presses.first?.minimumPressDuration ?? 0, 0.5, accuracy: 0.001)
    }
}
