import UIKit

/// Runs the measurement scenarios named by `-scenarios a,b,c`, prints one
/// `RESULTS_JSON {...}` line, writes Documents/results.json, and exits.
/// Without `-scenarios`, loads `-stream` (default seq.bin) and stays
/// interactive.
@MainActor final class Runner {
    private let host: HostViewController
    private var results: [String: Any] = [:]
    private let args = ProcessInfo.processInfo.arguments
    private let probe = FrameProbe()
    private let driver = FrameDriver()

    init(host: HostViewController) { self.host = host }

    private func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private var config: EngineConfig {
        var c = EngineConfig()
        c.metal = args.contains("-metal")
        if let s = arg("-scrollback"), let n = Int(s) { c.scrollback = n }
        return c
    }

    private func log(_ s: String) { print("HARNESS \(s)"); fflush(stdout) }

    func run() async {
        // Let the window lay out before measuring anything.
        await frames(10)
        results["engine"] = engineBuildName + (config.metal ? "+metal" : "")
        results["footprintAtLaunchMB"] = mb(physFootprint())
        let screen = host.view.window?.windowScene?.screen
        results["screen"] = ["points": "\(screen?.bounds.size ?? .zero)", "scale": screen?.scale ?? 0,
                             "maxFPS": screen?.maximumFramesPerSecond ?? 0,
                             "terminalFrame": "\(host.terminalFrame.size)"]
        guard let list = arg("-scenarios") else {
            interactive()
            return
        }
        for name in list.split(separator: ",").map(String.init) {
            log("scenario \(name) begin")
            switch name {
            case "parse": parse()
            case "memory": await memory()
            case "ingest": await ingest()
            case "fling": await fling()
            case "pinch": await pinch()
            case "replay": await replay()
            case "evidence": await evidence()
            default: log("unknown scenario \(name)")
            }
            log("scenario \(name) end")
        }
        finish()
    }

    private func interactive() {
        guard let engine = makeEngine(config) else { return }
        host.install(engine)
        Streams.bytes(arg("-stream") ?? "seq.bin").chunks(16_384) { engine.feed($0) }
        engine.scrollToBottom()
        log("interactive \(engine.name) grid \(engine.grid)")
    }

    private func finish() {
        let data = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("results.json")
        try? data.write(to: url)
        print("RESULTS_JSON " + String(decoding: data, as: UTF8.self))
        fflush(stdout)
        exit(0)
    }

    // MARK: helpers

    private func frames(_ n: Int) async {
        var left = n
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            driver.run({ _ in left -= 1; return left > 0 }, done: { c.resume() })
        }
    }

    private func drive(_ step: @escaping (Double) -> Bool) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            driver.run(step, done: { c.resume() })
        }
    }

    private func encode<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func mb(_ bytes: UInt64) -> Double { mb(Int64(bytes)) }
    private func mb(_ bytes: Int64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
    private func delta(_ a: UInt64, _ b: UInt64) -> Double { mb(Int64(a) - Int64(b)) }

    private func freshEngine(_ c: EngineConfig? = nil) async -> TerminalEngine? {
        host.engine?.view.removeFromSuperview()
        host.engine = nil
        await frames(5)
        guard let engine = makeEngine(c ?? config) else { return nil }
        host.install(engine)
        await frames(5)
        return engine
    }

    // MARK: scenarios

    /// Raw parser throughput with no view: 16 KiB chunks, best of 5 runs.
    private func parse() {
        var out: [String: Any] = [:]
        for stream in ["seq.bin", "ls.bin", "htop.frames", "vim.frames"] {
            let bytes = Streams.flat(stream)
            for scrollback in [500, 10_000] {
                var times: [Double] = []
                var summary = ""
                for _ in 0..<5 {
                    guard let p = makeHeadless(cols: 45, rows: 40, scrollback: scrollback) else { return }
                    let t = now()
                    bytes.chunks(16_384) { p.feed($0) }
                    times.append(now() - t)
                    summary = p.summary()
                }
                let best = times.min()!
                out["\(stream)@\(scrollback)"] = [
                    "bytes": bytes.count, "bestMs": best * 1000, "medianMs": Stats(times).p50 * 1000,
                    "MBps": Double(bytes.count) / best / 1_048_576, "summary": summary,
                ]
            }
        }
        results["parse"] = out
    }

    /// Footprint added by an engine holding the seq and ls streams.
    private func memory() async {
        host.engine?.view.removeFromSuperview()
        host.engine = nil
        await frames(10)
        let before = physFootprint()
        guard let engine = await freshEngine() else {
            results["memory"] = ["engineMB": 0]
            return
        }
        let empty = physFootprint()
        Streams.bytes("seq.bin").chunks(16_384) { engine.feed($0) }
        await frames(10)
        let seq = physFootprint()
        Streams.bytes("ls.bin").chunks(16_384) { engine.feed($0) }
        await frames(10)
        let ls = physFootprint()
        results["memory"] = ["emptyEngineMB": delta(empty, before), "afterSeqMB": delta(seq, before),
                             "afterSeqAndLsMB": delta(ls, before), "grid": "\(engine.grid)",
                             "scrollback": config.scrollback]
    }

    /// Heavy output on screen: 64 KiB per frame of ls + 3 x seq (about 3.6 MB).
    private func ingest() async {
        guard let engine = await freshEngine() else { return }
        let bytes = Streams.bytes("ls.bin") + Streams.bytes("seq.bin") + Streams.bytes("seq.bin") + Streams.bytes("seq.bin")
        var offset = 0
        let start = now()
        probe.start(engine: engine)
        await drive { _ in
            let n = min(65_536, bytes.count - offset)
            bytes.withUnsafeBytes { engine.feed(UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + n)])) }
            offset += n
            return offset < bytes.count
        }
        await frames(2)
        let report = probe.stop()
        results["ingest"] = ["bytes": bytes.count, "wallMs": (now() - start) * 1000,
                             "frames": encode(report)]
    }

    /// Three fast flings up through scrollback, then three back down,
    /// with UIScrollView's normal deceleration (0.998 per ms).
    private func fling() async {
        guard let engine = await freshEngine() else { return }
        Streams.bytes("seq.bin").chunks(16_384) { engine.feed($0) }
        engine.scrollToBottom()
        await frames(20)
        let scroll = engine.scrollView
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        var flings: [[String: Any]] = []
        probe.start(engine: engine)
        for direction in [-1.0, -1.0, -1.0, 1.0, 1.0, 1.0] {
            var v = 16_000.0 * direction
            let startY = scroll.contentOffset.y
            let t = now()
            await drive { dt in
                let y = min(maxY, max(0, scroll.contentOffset.y + v * dt))
                scroll.contentOffset.y = y
                v *= pow(0.998, dt * 1000)
                return abs(v) > 20 && y > 0 && y < maxY
            }
            flings.append(["distancePt": abs(scroll.contentOffset.y - startY), "ms": (now() - t) * 1000])
        }
        let report = probe.stop()
        results["fling"] = ["contentHeightPt": scroll.contentSize.height, "flings": flings,
                            "retainedRows": Int(scroll.contentSize.height / engine.cellSize.height),
                            "frames": encode(report), "grid": "\(engine.grid)"]
    }

    /// A pinch to 1.5x in 10 frames (scaling the drawn view), a commit of
    /// the new font size, then back.
    private func pinch() async {
        guard let engine = await freshEngine() else { return }
        Streams.bytes("seq.bin").chunks(16_384) { engine.feed($0) }
        engine.scrollToBottom()
        await frames(20)
        var out: [[String: Any]] = []
        for (from, to) in [(14.0, 21.0), (21.0, 14.0)] {
            let before = engine.grid
            probe.start(engine: engine)
            var step = 0
            let target = to / from
            await drive { _ in
                step += 1
                let s = 1 + (target - 1) * Double(step) / 10
                engine.view.transform = CGAffineTransform(scaleX: s, y: s)
                return step < 10
            }
            let steps = probe.stop()
            probe.start(engine: engine)
            let t0 = now()
            engine.view.transform = .identity
            engine.view.frame = host.terminalFrame
            engine.commitFont(size: to)
            engine.view.layoutIfNeeded()
            let commitMs = (now() - t0) * 1000
            await frames(30)
            let lift = probe.stop()
            out.append(["from": from, "to": to, "gridBefore": "\(before)", "gridAfter": "\(engine.grid)",
                        "steps": encode(steps), "commitMs": commitMs, "liftFrames": encode(lift)])
        }
        results["pinch"] = out
    }

    /// Full-screen programs: one recorded frame fed per display frame.
    private func replay() async {
        var out: [String: Any] = [:]
        for stream in ["htop.frames", "vim.frames"] {
            guard let engine = await freshEngine() else { return }
            let frames = Streams.frames(stream)
            var i = 0
            probe.start(engine: engine)
            await drive { _ in
                frames[i].withUnsafeBytes { engine.feed($0) }
                i += 1
                return i < frames.count
            }
            await self.frames(2)
            out[stream] = encode(probe.stop())
        }
        results["replay"] = out
    }

    /// CJK/emoji rendering, text extraction, word selection, and (Ghostty)
    /// a fixed 120x40 grid scaled to the view. Pauses for screenshots.
    private func evidence() async {
        guard let engine = await freshEngine() else { return }
        Streams.bytes("cjk.bin").withUnsafeBytes { engine.feed($0) }
        await frames(10)
        var out: [String: Any] = ["rows": Array(engine.visibleRows().prefix(10)), "grid": "\(engine.grid)"]
        out["selectWordRow1Col3"] = engine.selectWord(row: 1, col: 3) ?? NSNull()
        await frames(10)
        log("SCREENSHOT_READY cjk")
        await frames(240)
        var watch = config
        watch.fixedGrid = (120, 40)
        if let fixed = await freshEngine(watch) {
            Streams.bytes("ls.bin").chunks(16_384) { fixed.feed($0) }
            fixed.scrollToBottom()
            await frames(10)
            out["watchGrid"] = "\(fixed.grid)"
            log("SCREENSHOT_READY watch")
            await frames(240)
        }
        results["evidence"] = out
    }
}
