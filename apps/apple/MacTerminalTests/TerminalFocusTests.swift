import AppKit
import WitermCore
import XCTest
@testable import WitermMac

/// When a Mac terminal takes the keyboard: as soon as it's shown after an
/// explicit action, never while the sidebar is being browsed, and only after
/// a sheet over its window has closed. In-memory windows only.
@MainActor final class TerminalFocusTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        addTeardownBlock { await MainActor.run { window.close() } }
        return window
    }

    private func terminal(mode: LocalAttachmentMode = .control) -> MacTerminalTextView {
        let view = MacTerminalTextView(mode: mode, columns: 80, rows: 24)
        view.frame = view.getOptimalFrameSize()
        return view
    }

    private func settle(_ seconds: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testShownTerminalTakesFocus() {
        let window = window()
        let view = terminal()
        window.contentView?.addSubview(view)
        settle()
        XCTAssertTrue(window.firstResponder === view)
    }

    func testBrowsingLeavesFocusUntilRequested() {
        let window = window()
        let sidebar = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(sidebar)
        window.makeFirstResponder(sidebar)
        let view = terminal()
        view.focusWhenShown = false
        window.contentView?.addSubview(view)
        settle()
        XCTAssertTrue(window.firstResponder === sidebar, "Arrowing through the sidebar must keep focus there; \(String(describing: window.firstResponder))")
        view.requestFocus()
        settle()
        XCTAssertTrue(window.firstResponder === view)
    }

    func testViewOnlyTerminalNeverTakesFocus() {
        let window = window()
        let view = terminal(mode: .view)
        view.requestFocus()
        window.contentView?.addSubview(view)
        settle()
        XCTAssertFalse(window.firstResponder === view)
    }

    func testFocusWaitsForTheSheetToClose() throws {
        let window = window()
        window.orderFront(nil)
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        settle(0.2)
        guard window.attachedSheet != nil else { throw XCTSkip("This run can't attach a sheet") }
        let sidebar = NSTableView()
        window.contentView?.addSubview(sidebar)
        let view = terminal()
        window.contentView?.addSubview(view)
        settle()
        window.makeFirstResponder(sidebar)
        XCTAssertFalse(window.firstResponder === view, "Focus moved while a sheet covered the window")
        window.endSheet(sheet)
        settle(0.6)
        XCTAssertTrue(window.firstResponder === view)
    }
}
