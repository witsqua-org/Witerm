import XCTest
@testable import WitermMac

/// Round 28: a terminal's long command finishing while it isn't shown here.
@MainActor final class Round28Tests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testALongCommandThatEndsIsMarkedFinished() {
        let model = LocalTerminalModel()
        model.noteCommands(["a": "npm"], live: ["a"], now: start)
        XCTAssertNil(model.finished["a"], "Still running")
        XCTAssertEqual(model.commands["a"], "npm")
        model.noteCommands([:], live: ["a"], now: start.addingTimeInterval(42))
        XCTAssertEqual(model.finished["a"], .init(command: "npm", at: start.addingTimeInterval(42)))
        XCTAssertNil(model.commands["a"])
        model.acknowledgeFinished("a")
        XCTAssertNil(model.finished["a"], "Opening it is seeing it")
    }

    func testAQuickCommandIsNotMarked() {
        let model = LocalTerminalModel()
        model.noteCommands(["a": "ls"], live: ["a"], now: start)
        model.noteCommands([:], live: ["a"], now: start.addingTimeInterval(LocalTerminalModel.finishWorthNoting - 1))
        XCTAssertNil(model.finished["a"])
    }

    func testANewCommandClearsTheMarkAndTimesItself() {
        let model = LocalTerminalModel()
        model.noteCommands(["a": "make"], live: ["a"], now: start)
        model.noteCommands([:], live: ["a"], now: start.addingTimeInterval(30))
        XCTAssertNotNil(model.finished["a"])
        model.noteCommands(["a": "vim"], live: ["a"], now: start.addingTimeInterval(31))
        XCTAssertNil(model.finished["a"], "Something new runs there")
        // A different command replacing the first restarts the clock.
        model.noteCommands(["a": "git"], live: ["a"], now: start.addingTimeInterval(60))
        model.noteCommands([:], live: ["a"], now: start.addingTimeInterval(65))
        XCTAssertNil(model.finished["a"], "git ran 5 seconds")
    }

    func testAnEndedTerminalDropsItsMark() {
        let model = LocalTerminalModel()
        model.noteCommands(["a": "make", "b": "make"], live: ["a", "b"], now: start)
        model.noteCommands([:], live: ["a"], now: start.addingTimeInterval(30))
        XCTAssertNotNil(model.finished["a"])
        XCTAssertNil(model.finished["b"], "b ended with its terminal")
        model.noteCommands([:], live: [], now: start.addingTimeInterval(31))
        XCTAssertTrue(model.finished.isEmpty)
    }

    func testFinishedWordsSayJustFinishedThenHowLongAgo() {
        let done = LocalTerminalModel.FinishedCommand(command: "npm", at: start)
        XCTAssertEqual(MacWorkspaceView.finishedText(done, now: start), "npm just finished")
        XCTAssertEqual(MacWorkspaceView.finishedText(done, now: start.addingTimeInterval(59)), "npm just finished")
        let later = MacWorkspaceView.finishedText(done, now: start.addingTimeInterval(180))
        XCTAssertTrue(later.hasPrefix("npm finished "), later)
        XCTAssertFalse(later.contains(" in "), "Never said as if it's still to come: \(later)")
    }
}
