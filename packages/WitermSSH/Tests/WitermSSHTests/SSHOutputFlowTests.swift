import XCTest
@testable import WitermSSH

/// The shell's output never drops bytes: past the high water mark a read
/// waits, and it resumes once, when the reader is back under the low mark.
final class SSHOutputFlowTests: XCTestCase {
    func testReadsPauseAboveHighWaterAndResumeOnceBelowLowWater() {
        let flow = SSHOutputFlow()
        flow.produced(SSHOutputFlow.highWater)
        XCTAssertFalse(flow.isAboveHighWater)
        flow.produced(1)
        XCTAssertTrue(flow.isAboveHighWater)
        var resumed = 0
        XCTAssertTrue(flow.park { resumed += 1 })
        flow.consumed(SSHOutputFlow.highWater - SSHOutputFlow.lowWater)
        XCTAssertEqual(resumed, 0, "Still above the low mark")
        flow.consumed(1)
        XCTAssertEqual(resumed, 1)
        flow.consumed(1000)
        XCTAssertEqual(resumed, 1, "A read resumes once")
    }

    func testParkingWhenAlreadyCaughtUpReadsAtOnce() {
        let flow = SSHOutputFlow()
        flow.produced(SSHOutputFlow.lowWater)
        XCTAssertFalse(flow.park {}, "Under the low mark the caller reads now")
    }
}
