import SwiftTerm
import XCTest
@testable import WitermMac

@MainActor final class TerminalActivityTests: XCTestCase {
    /// OSC 7 reports a URL; rows show the path, with the home folder as `~`.
    func testFolderComesFromTheReportedURL() {
        let activity = TerminalActivity()
        activity.directoryChanged("file://studio.local/Users/ada/code/api%20server")
        XCTAssertEqual(activity.directory, "/Users/ada/code/api server")
        XCTAssertEqual(activity.folder(home: "/Users/ada"), "~/code/api server")
        XCTAssertEqual(activity.folder(home: "/Users/ad"), "/Users/ada/code/api server", "Only whole folder names are folded")
        XCTAssertEqual(activity.folder(home: nil), "/Users/ada/code/api server")
        activity.directoryChanged("/srv/app")
        XCTAssertEqual(activity.directory, "/srv/app")
        activity.directoryChanged(nil)
        XCTAssertNil(activity.directory)
    }

    /// A title and folder say what runs where; without them, the last line does.
    func testSummaryPrefersTitleAndFolder() {
        let activity = TerminalActivity()
        XCTAssertNil(activity.summary(home: nil))
        activity.titleChanged("  npm run dev \n")
        XCTAssertEqual(activity.title, "npm run dev")
        activity.directoryChanged("file:///Users/ada/code/api")
        XCTAssertEqual(activity.summary(home: "/Users/ada"), "npm run dev · ~/code/api")
        activity.titleChanged("   ")
        XCTAssertNil(activity.title)
        XCTAssertEqual(activity.summary(home: "/Users/ada"), "~/code/api")
    }

    /// The last non-blank line at or above the cursor, not blank rows below it.
    func testLastLineSkipsBlankRowsAndIgnoresRowsBelowTheCursor() throws {
        let surface = NativeTerminalView.TerminalSurface(mode: .view, columns: 40, rows: 6)
        let terminal = surface.terminal.getTerminal()
        surface.terminal.feed(text: "compiled in 412 ms\r\nready on http://localhost:3000\r\n\r\n")
        XCTAssertEqual(TerminalActivity.lastLine(in: terminal), "ready on http://localhost:3000")
        surface.terminal.feed(text: "$ ")
        XCTAssertEqual(TerminalActivity.lastLine(in: terminal), "$")
        // Text below the cursor, as full-screen programs leave it, is not the newest line.
        surface.terminal.feed(text: "\u{1B}[5;1Hstatus bar\u{1B}[2;1H")
        XCTAssertEqual(TerminalActivity.lastLine(in: terminal), "ready on http://localhost:3000")
    }
}
