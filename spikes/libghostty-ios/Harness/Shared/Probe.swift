import Darwin
import QuartzCore
import UIKit

/// CPU time used by the calling thread, in seconds.
func threadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = pthread_mach_thread_np(pthread_self())
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
    let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    return user + system
}

/// The process's physical footprint (what Xcode's memory gauge shows), in bytes.
func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

func now() -> Double { CACurrentMediaTime() }

struct Stats: Codable {
    var count: Int
    var mean: Double
    var p50: Double
    var p95: Double
    var max: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        func pct(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        p50 = pct(0.5)
        p95 = pct(0.95)
        max = sorted.last ?? 0
    }
}

struct FrameReport: Codable {
    var frames: Int
    var nominalMs: Double
    var intervalMs: Stats
    /// Intervals longer than 1.5 nominal frames.
    var hitches: Int
    /// Main-thread CPU used between consecutive display-link callbacks.
    var mainCPUms: Stats
    /// Renderer's own draw time per frame that drew (engine-instrumented).
    var drawMs: Double
    var draws: Int
}

/// Records display-link intervals and main-thread CPU per frame, from
/// start() to stop(). Runs on the main thread.
@MainActor final class FrameProbe: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var lastCPU: Double = 0
    private var intervals: [Double] = []
    private var cpu: [Double] = []
    private var nominal: Double = 1.0 / 60
    private var drawStart: (Double, Int) = (0, 0)
    private weak var engine: TerminalEngine?

    func start(engine: TerminalEngine?) {
        self.engine = engine
        intervals.removeAll(keepingCapacity: true)
        cpu.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        drawStart = (engine?.drawSeconds ?? 0, engine?.drawCount ?? 0)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let cpuNow = threadCPUSeconds()
        if lastTimestamp > 0 {
            intervals.append((link.timestamp - lastTimestamp) * 1000)
            cpu.append((cpuNow - lastCPU) * 1000)
        }
        nominal = link.duration > 0 ? link.duration : nominal
        lastTimestamp = link.timestamp
        lastCPU = cpuNow
    }

    func stop() -> FrameReport {
        link?.invalidate()
        link = nil
        let draws = (engine?.drawCount ?? 0) - drawStart.1
        let drawSeconds = (engine?.drawSeconds ?? 0) - drawStart.0
        let nominalMs = nominal * 1000
        return FrameReport(frames: intervals.count, nominalMs: nominalMs,
                           intervalMs: Stats(intervals),
                           hitches: intervals.filter { $0 > nominalMs * 1.5 }.count,
                           mainCPUms: Stats(cpu),
                           drawMs: draws > 0 ? drawSeconds * 1000 / Double(draws) : 0,
                           draws: draws)
    }
}

/// Calls `step` once per display frame with the time since the last call,
/// until it returns false.
@MainActor final class FrameDriver: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var step: ((Double) -> Bool)?
    private var done: (() -> Void)?

    func run(_ step: @escaping (Double) -> Bool, done: @escaping () -> Void) {
        self.step = step
        self.done = done
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = last > 0 ? link.timestamp - last : link.duration
        last = link.timestamp
        if step?(dt) != true {
            link.invalidate()
            self.link = nil
            step = nil
            let done = self.done
            self.done = nil
            done?()
        }
    }
}
