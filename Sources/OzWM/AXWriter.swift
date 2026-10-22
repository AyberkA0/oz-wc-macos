import Cocoa
import Foundation

/// Applies window moves off the main thread: one serial queue per app, and only the
/// newest target per window is kept. A slow or busy app (Electron, a beachballing
/// process, the 250 ms AX timeout) then delays only its own windows, never the
/// scrolling or the other apps.
final class AXWriter {
    private struct Job {
        let pid: pid_t
        let element: AXUIElement
        var origin: CGPoint
        var size: CGSize
        var setSize: Bool
        /// Report back if the app refuses this height (shrinking at the top edge).
        var checkMinHeight: Bool
    }

    /// Main thread: the app kept the window taller than asked.
    var onMinHeight: ((CGWindowID, CGFloat) -> Void)?

    private let lock = NSLock()
    private var pending: [CGWindowID: Job] = [:]
    private var draining = Set<pid_t>()
    private var queues: [pid_t: DispatchQueue] = [:]

    /// Moves (and if `setSize`, resizes) the window to `frame` soon.
    func move(_ id: CGWindowID, pid: pid_t, element: AXUIElement, to frame: CGRect,
              setSize: Bool, checkMinHeight: Bool = false) {
        lock.lock()
        if var job = pending[id] {
            job.origin = frame.origin
            job.size = frame.size
            job.setSize = job.setSize || setSize
            job.checkMinHeight = checkMinHeight
            pending[id] = job
        } else {
            pending[id] = Job(pid: pid, element: element, origin: frame.origin, size: frame.size,
                              setSize: setSize, checkMinHeight: checkMinHeight)
        }
        let start = draining.insert(pid).inserted
        lock.unlock()
        if start { queue(pid).async { [weak self] in self?.drain(pid) } }
    }

    /// Runs `work` on the app's queue, after its pending moves (keeps focus changes ordered).
    func perform(pid: pid_t, _ work: @escaping () -> Void) {
        queue(pid).async(execute: work)
    }

    /// Drops a pending move (the window is being placed some other way).
    func cancel(_ id: CGWindowID) {
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
    }

    func hasPending(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return draining.contains(pid)
    }

    /// Blocks until every queued move has been applied. Only used at rest (before reading
    /// frames back, or on quit), never while scrolling.
    func waitUntilIdle() {
        for q in Array(queues.values) { q.sync {} }
    }

    func forget(pid: pid_t) {
        queues.removeValue(forKey: pid)
        lock.lock()
        latency.removeValue(forKey: pid)
        lastSlowReport.removeValue(forKey: pid)
        lock.unlock()
    }

    private func queue(_ pid: pid_t) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "oz.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    private var lastSlowReport: [pid_t: CFTimeInterval] = [:]  // guarded by `lock`
    /// Worst recent move time per app (ms) and when it was measured, guarded by `lock`.
    /// A peak that fades (half-life 20 s) rather than an average: apps like WhatsApp are
    /// fast most of the time but stall for ~100 ms now and then, and those spikes are
    /// exactly what makes a window lag behind.
    private var latency: [pid_t: (ms: Double, at: CFTimeInterval)] = [:]
    private static let halfLife = 20.0

    /// Recent worst time (ms) this app took to move a window; 0 until measured.
    func moveLatency(pid: pid_t) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let l = latency[pid] else { return 0 }
        return l.ms * pow(0.5, (CACurrentMediaTime() - l.at) / AXWriter.halfLife)
    }

    private func record(pid: pid_t, ms: Double) {
        lock.lock()
        let now = CACurrentMediaTime()
        let faded = latency[pid].map { $0.ms * pow(0.5, (now - $0.at) / AXWriter.halfLife) } ?? 0
        if ms >= faded { latency[pid] = (ms, now) }
        lock.unlock()
    }

    /// An app took long to apply a move: that window lags behind the others.
    private func reportSlow(pid: pid_t, ms: Double) {
        lock.lock()
        let now = CACurrentMediaTime()
        let report = now - (lastSlowReport[pid] ?? 0) > 5
        if report { lastSlowReport[pid] = now }
        lock.unlock()
        guard report else { return }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        Log.info(String(format: "[slow] %@ took %.0f ms to move a window", name, ms))
    }

    private func drain(_ pid: pid_t) {
        while true {
            lock.lock()
            let ids = pending.filter { $0.value.pid == pid }.map(\.key)
            guard !ids.isEmpty else {
                draining.remove(pid)
                lock.unlock()
                return
            }
            var jobs: [(CGWindowID, Job)] = []
            for id in ids { if let j = pending.removeValue(forKey: id) { jobs.append((id, j)) } }
            lock.unlock()

            for (id, job) in jobs {
                let t0 = CACurrentMediaTime()
                // Size, move, size again: a resize can be clamped by the old position.
                if job.setSize { AX.setSize(job.element, job.size) }
                AX.setPosition(job.element, job.origin)
                if job.setSize { AX.setSize(job.element, job.size) }
                let ms = (CACurrentMediaTime() - t0) * 1000
                record(pid: pid, ms: ms)
                if ms > 40 { reportSlow(pid: pid, ms: ms) }
                if job.checkMinHeight, let actual = AX.size(job.element), actual.height > job.size.height + 4 {
                    let h = actual.height
                    DispatchQueue.main.async { [weak self] in self?.onMinHeight?(id, h) }
                }
            }
        }
    }
}

/// Calls `onFrame` once per display refresh while running (CADisplayLink, macOS 14),
/// so layout happens exactly once per frame the screen can show.
final class FrameDriver: NSObject {
    var onFrame: (() -> Void)?
    private var link: CADisplayLink?

    func start() {
        if link == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            let l = screen.displayLink(target: self, selector: #selector(step(_:)))
            // Unasked, macOS paces the link as it sees fit (measured: 35 fps on a 120 Hz
            // ProMotion screen): ask for the screen's full rate.
            let fps = Float(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    func pause() {
        link?.isPaused = true
    }

    @objc private func step(_ link: CADisplayLink) {
        onFrame?()
    }
}
