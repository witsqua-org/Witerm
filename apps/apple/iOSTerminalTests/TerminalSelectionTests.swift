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
}
