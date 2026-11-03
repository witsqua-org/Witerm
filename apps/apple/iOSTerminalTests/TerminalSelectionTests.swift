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

    /// Round 15: a one-finger drag never sends a held mouse button. In a
    /// plain shell it scrolls Witerm's scrollback; for a program that asked
    /// for the mouse it's the wheel, sent at the finger in the program's
    /// encoding; a watched terminal only scrolls.
    func testSwipesAreTheWheelInMouseModeAndScrollOtherwise() throws {
        let terminal = surface().terminal
        let spy = MouseSpy()
        terminal.terminalDelegate = spy
        let wheel = try XCTUnwrap(terminal.wheelRecognizer)
        func beginning() -> [UIPanGestureRecognizer] {
            (terminal.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
                .filter { terminal.gestureRecognizerShouldBegin($0) }
        }
        XCTAssertEqual(terminal.getTerminal().mouseMode, .off)
        XCTAssertEqual(beginning(), [terminal.panGestureRecognizer], "A plain shell's drag scrolls, and nothing else begins")
        terminal.wheel(by: 200)
        XCTAssertTrue(spy.bytes.isEmpty, "No wheel without the mouse")

        // A program turns on mouse reporting with SGR coordinates, as tmux `mouse on` does.
        terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        XCTAssertNotEqual(terminal.getTerminal().mouseMode, .off)
        XCTAssertEqual(beginning(), [wheel], "Only the wheel begins: no scrolling, and no SwiftTerm button drag")
        let frame = terminal.getOptimalFrameSize(), core = terminal.getTerminal()
        let row = frame.height / CGFloat(core.rows)
        terminal.wheel(by: row * 2.5)
        let text = String(decoding: spy.bytes, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\u{1b}[<64;").count - 1, 2, "Two rows down is two wheel-up steps: \(text.debugDescription)")
        XCTAssertFalse(text.contains("\u{1b}[<0;") || text.contains("\u{1b}[<32;"), "Never a button press or a held-button drag")
        spy.bytes.removeAll()
        // Half a row is still carried from the 2.5 rows above.
        terminal.wheel(by: -row * 1.6)
        XCTAssertEqual(String(decoding: spy.bytes, as: UTF8.self).components(separatedBy: "\u{1b}[<65;").count - 1, 1, "Up a row is one wheel-down step")

        // Turned off again: the drag scrolls.
        terminal.feed(text: "\u{1b}[?1002l")
        XCTAssertEqual(beginning(), [terminal.panGestureRecognizer])
        // A watched (view-only) terminal never sends the mouse.
        terminal.feed(text: "\u{1b}[?1002h")
        terminal.disableInput()
        XCTAssertEqual(beginning(), [terminal.panGestureRecognizer], "Without control, a drag only scrolls")
        spy.bytes.removeAll()
        terminal.wheel(by: row * 3)
        XCTAssertTrue(spy.bytes.isEmpty)
    }

    /// Round 15, the owner's report: in a paired terminal, typing at a plain
    /// shell, a swipe selected text. The Mac service's tmux (3.6 and later
    /// default `mouse` to on, even with -f /dev/null) asks for the mouse in
    /// the very stream the phone draws, so SwiftTerm's drag sent a held
    /// button and tmux made a copy-mode selection. A paired terminal's
    /// touches stay Witerm's whatever the stream asks.
    func testPairedTerminalsKeepTouchesWhenTheirTmuxAsksForTheMouse() {
        let terminal = surface().terminal
        terminal.passesMouseToPrograms = false
        let spy = MouseSpy()
        terminal.terminalDelegate = spy
        // What tmux 3.8's client sent on attaching, as captured from the service's options.
        terminal.feed(text: "\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006h\u{1b}[?1000h\u{1b}[?1002h")
        XCTAssertNotEqual(terminal.getTerminal().mouseMode, .off, "The stream itself turns mouse reporting on")
        XCTAssertFalse(terminal.reportsMouse)
        let beginning = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
            .filter { terminal.gestureRecognizerShouldBegin($0) }
        XCTAssertEqual(beginning, [terminal.panGestureRecognizer], "A swipe scrolls Witerm's scrollback, as when watching")
        terminal.wheel(by: 200)
        XCTAssertTrue(spy.bytes.isEmpty, "Nothing reaches the Mac's tmux as the mouse")
    }

    /// Round 15: SwiftTerm calls the view's delegate methods (the mouse mode,
    /// the selection) while it's still being made, before it has a terminal;
    /// the DEBUG gesture log once crashed there. Every mode must build, take
    /// output that sets the mouse and a selection, and lay out.
    func testTerminalsBuildInEveryModeWithTheGestureLog() {
        for (mode, interactive) in [(LocalAttachmentMode.control, true), (.control, false), (.view, false)] {
            let session = LocalSessionInfo(id: UUID().uuidString, name: "Modes", createdAt: .now, columns: 40, rows: 20)
            let surface = RemoteNativeTerminalView.TerminalSurface(mode: mode, session: session, fontSize: 14, isInteractive: interactive)
            surface.frame = CGRect(x: 0, y: 120, width: 402, height: 600)
            window.rootViewController?.view.addSubview(surface)
            surface.layoutIfNeeded()
            surface.terminal.feed(text: "alpha bravo\r\n\u{1b}[?1002h\u{1b}[?1006h")
            surface.terminal.beginSelection(at: CGPoint(x: 10, y: 5))
            XCTAssertTrue(surface.terminal.selection.active, "\(mode) \(interactive)")
            surface.terminal.feed(text: "\u{1b}[?1002l")
            surface.removeFromSuperview()
        }
    }

    /// Round 15: the long press takes UIKit's 0.5 s, not 0.35 s.
    func testLongPressWaitsForTheSystemDuration() {
        let terminal = surface().terminal
        let presses = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }.filter(\.isEnabled)
        XCTAssertEqual(presses.count, 1)
        XCTAssertEqual(presses.first?.minimumPressDuration ?? 0, 0.5, accuracy: 0.001)
    }
}

@MainActor private final class MouseSpy: NSObject, @preconcurrency TerminalViewDelegate {
    var bytes = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
