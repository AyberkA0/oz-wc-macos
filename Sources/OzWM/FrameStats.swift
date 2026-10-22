import QuartzCore

/// Debug timing of layout frames (debug: true in the config): how long each frame's
/// layout pass blocked the main thread, summarized after every swipe/animation.
enum FrameStats {
    private static var times: [Double] = []
    private static var start: CFTimeInterval = 0

    static func measure(_ body: () -> Void) {
        guard Log.debugEnabled else { return body() }
        let t0 = CACurrentMediaTime()
        if times.isEmpty { start = t0 }
        body()
        // Reported (and emptied) after a swipe or animation; motion that isn't (a drag
        // scrolling the strip, a live resize) mustn't grow it for ever.
        if times.count >= 4096 { times.removeFirst(2048) }
        times.append((CACurrentMediaTime() - t0) * 1000)
    }

    static func report(_ label: String) {
        guard Log.debugEnabled, !times.isEmpty else { return }
        let sorted = times.sorted()
        let avg = times.reduce(0, +) / Double(times.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let span = CACurrentMediaTime() - start
        Log.info(String(format: "[perf] %@: %d frames in %.2fs (%.0f fps), main-thread layout avg %.2f ms, p95 %.2f ms, max %.2f ms",
                        label, times.count, span, Double(times.count) / max(span, 0.001), avg, p95, sorted.last!))
        times.removeAll()
    }
}
