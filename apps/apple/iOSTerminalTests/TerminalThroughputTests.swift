import Darwin
import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// Main-thread cost of a terminal under long output and scrolling, on the
/// renderer the SSH and paired terminals share. Numbers are printed as
/// `PERF name value` for the round's before/after table; the assertions are
/// generous ceilings that catch a regression by an order of magnitude, not
/// a few percent (the simulator's timing varies with the Mac's load).
@MainActor final class TerminalThroughputTests: XCTestCase {
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
        let session = LocalSessionInfo(id: UUID().uuidString, name: "SSH", createdAt: .now, columns: 80, rows: 24)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        surface.frame = CGRect(x: 0, y: 120, width: 402, height: 700)
        window.rootViewController?.view.addSubview(surface)
        surface.layoutIfNeeded()
        surface.terminal.layoutIfNeeded()
        return surface
    }

    /// One main-queue turn, as between two deliveries of SSH output.
    private func turn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    /// This process's memory as the system counts it (the Xcode gauge's number).
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// `seq 1 100000` as the shell sends it, fed the way `SSHTerminalCoordinator`
    /// delivers it: a batch per main-queue turn, each followed by the reading
    /// page's coalesced refresh, with one frame drawn per turn.
    func testLongOutputThroughputAndMemory() async {
        let surface = surface()
        let terminal = surface.terminal
        let output = Array((1...100_000).map { "\($0)\r\n" }.joined().utf8)
        let before = footprintMB()
        var feeding = 0.0, drawing = 0.0, turns = 0.0
        let start = now()
        var offset = 0
        let batch = 32 * 1024
        while offset < output.count {
            let end = min(output.count, offset + batch)
            let t0 = now()
            terminal.feed(byteArray: output[offset..<end])
            terminal.requestReadingRefresh(output: true)
            let t1 = now()
            await turn()
            let t2 = now()
            terminal.setNeedsDisplay()
            terminal.layer.displayIfNeeded()
            let t3 = now()
            feeding += t1 - t0; turns += t2 - t1; drawing += t3 - t2
            offset = end
        }
        let total = now() - start
        let after = footprintMB()
        let lines = Double(100_000)
        print(String(format: "PERF seq100k_total_ms %.0f", total))
        print(String(format: "PERF seq100k_feed_ms %.0f", feeding))
        print(String(format: "PERF seq100k_turn_ms %.0f", turns))
        print(String(format: "PERF seq100k_draw_ms %.0f", drawing))
        print(String(format: "PERF seq100k_lines_per_s %.0f", lines / (total / 1000)))
        print(String(format: "PERF seq100k_memory_growth_mb %.1f", after - before))
        XCTAssertTrue(surface.readingView.readingDocument.text.contains("100000"), "The view must follow the output to its end")
        XCTAssertLessThan(total, 60_000, "100,000 lines must not take a minute")
    }

    /// A finger drag through scrollback: every step moves the content offset,
    /// lays out, refreshes what VoiceOver would read, and draws a frame. The
    /// per-step cost is what's left of a 120 Hz frame (8.3 ms) for UIKit.
    func testScrollStepCost() async {
        let surface = surface()
        let terminal = surface.terminal
        terminal.feed(text: (1...3000).map { "line \($0) " + String(repeating: "x", count: 40) + "\r\n" }.joined())
        surface.layoutIfNeeded()
        await turn()
        let steps = 240
        let top = max(0, terminal.contentSize.height - terminal.bounds.height)
        var total = 0.0, worst = 0.0, layout = 0.0, turns = 0.0, draws = 0.0
        for step in 0..<steps {
            let t0 = now()
            terminal.contentOffset.y = top - CGFloat(step) * 9
            surface.layoutIfNeeded()
            let t1 = now()
            await turn()
            let t2 = now()
            terminal.layer.displayIfNeeded()
            let t3 = now()
            let elapsed = t3 - t0
            layout += t1 - t0; turns += t2 - t1; draws += t3 - t2
            total += elapsed; worst = max(worst, elapsed)
        }
        print(String(format: "PERF scroll_step_layout_ms %.2f", layout / Double(steps)))
        print(String(format: "PERF scroll_step_reading_ms %.2f", turns / Double(steps)))
        print(String(format: "PERF scroll_step_draw_ms %.2f", draws / Double(steps)))
        print(String(format: "PERF scroll_step_mean_ms %.2f", total / Double(steps)))
        print(String(format: "PERF scroll_step_worst_ms %.2f", worst))
        XCTAssertLessThan(total / Double(steps), 50, "A scroll step must not cost several frames")
    }
}
