import AppKit
import Foundation
import XCTest
@testable import WitermAgent

@MainActor
final class AgentPowerMonitorTests: XCTestCase {
    func testWorkspaceNotificationsUseTheirOwnCenterAndObserversAreReleased() async {
        let asleep = expectation(description: "sleep callback")
        let awake = expectation(description: "wake callback")
        var monitor: AgentPowerMonitor? = AgentPowerMonitor(
            willSleep: { asleep.fulfill() },
            didWake: { awake.fulfill() }
        )
        weak var weakMonitor = monitor
        // These process-local posts exercise wiring; they do not put the host
        // to sleep and must never be reported as a physical sleep test.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        let result = await XCTWaiter.fulfillment(of: [asleep, awake], timeout: 1)
        XCTAssertEqual(result, .completed)
        monitor = nil
        XCTAssertNil(weakMonitor)
    }
}
