import Foundation

/// One finger contact from the trackpad, in normalized coordinates (0...1, y grows away from the user).
public struct Touch: Equatable {
    public var id: Int32
    public var x: Double
    public var y: Double
    public var state: Int32

    public init(id: Int32, x: Double, y: Double, state: Int32 = 4) {
        self.id = id
        self.x = x
        self.y = y
        self.state = state
    }

    /// MultitouchSupport states 3 (make touch) and 4 (touching) mean the finger is down.
    public var isDown: Bool { state == 3 || state == 4 }
}

public enum GestureEvent: Equatable {
    case swipeBegan
    /// Vertical movement since the last event, in trackpad heights (positive = fingers moved up).
    case swipeChanged(Double)
    /// Release velocity in trackpad heights per second.
    case swipeEnded(velocity: Double)
    case tap(fingers: Int)
    case doubleTap(fingers: Int)
}

/// Turns raw multitouch frames into vertical swipes and multi-finger (double) taps.
/// Pure state machine so it can be unit tested with synthetic frames.
public final class GestureRecognizer {
    public var swipeEnabled = true
    public var swipeFingers = 3
    /// Movement (in trackpad heights) before a swipe is recognized.
    public var threshold = 0.02
    public var doubleTapEnabled = true
    public var tapFingers = 3
    public var tapMaxDuration = 0.3
    public var tapMaxMovement = 0.03
    public var doubleTapInterval = 0.4

    private enum Phase { case idle, possible, swiping, done }
    private var phase = Phase.idle
    private var start = (x: 0.0, y: 0.0)
    private var last = (x: 0.0, y: 0.0)
    private var ids = Set<Int32>()
    private var samples: [(t: Double, y: Double)] = []
    private var dropFrames = 0

    private var inSession = false
    private var sessionStart = 0.0
    private var maxCount = 0
    private var maxMovement = 0.0
    private var sessionSwiped = false
    private var startPositions: [Int32: (Double, Double)] = [:]
    private var lastTap: Double?

    public init() {}

    public var isSwiping: Bool { phase == .swiping }

    public func process(_ touches: [Touch], time: Double) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let down = touches.filter(\.isDown)
        let count = down.count

        // Tap bookkeeping for the whole touch session (first finger down -> last finger up).
        if count > 0 {
            if !inSession {
                inSession = true
                sessionStart = time
                maxCount = 0
                maxMovement = 0
                sessionSwiped = false
                startPositions = [:]
            }
            maxCount = max(maxCount, count)
            for t in down {
                if let s = startPositions[t.id] {
                    maxMovement = max(maxMovement, hypot(t.x - s.0, t.y - s.1))
                } else {
                    startPositions[t.id] = (t.x, t.y)
                }
            }
        }

        // Vertical swipe state machine.
        if swipeEnabled && count == swipeFingers {
            dropFrames = 0
            let c = centroid(down)
            let current = Set(down.map(\.id))
            switch phase {
            case .idle:
                phase = .possible
                start = c
                last = c
                ids = current
            case .possible:
                if current != ids {
                    start = c; last = c; ids = current
                    break
                }
                let dx = c.x - start.x
                let dy = c.y - start.y
                if abs(dy) > threshold && abs(dy) > abs(dx) * 1.5 {
                    phase = .swiping
                    sessionSwiped = true
                    events.append(.swipeBegan)
                    events.append(.swipeChanged(dy))
                    last = c
                    samples = [(time, c.y)]
                } else if abs(dx) > threshold && abs(dx) >= abs(dy) {
                    // Horizontal: leave it to macOS (switching Spaces).
                    phase = .done
                }
            case .swiping:
                if current != ids {
                    // A finger was swapped; re-anchor to avoid a jump.
                    ids = current
                    last = c
                    break
                }
                let dy = c.y - last.y
                last = c
                if dy != 0 { events.append(.swipeChanged(dy)) }
                samples.append((time, c.y))
                samples.removeAll { time - $0.t > 0.08 }
            case .done:
                break
            }
        } else {
            if phase == .swiping {
                // Tolerate a single noisy frame where one finger flickers.
                dropFrames += 1
                if count == 0 || dropFrames >= 2 || count > swipeFingers {
                    events.append(.swipeEnded(velocity: velocity()))
                    phase = .done
                }
            } else if phase == .possible {
                phase = .done
            }
            if count == 0 { phase = .idle }
        }

        // Taps are decided when every finger has left.
        if count == 0 && inSession {
            inSession = false
            let duration = time - sessionStart
            if doubleTapEnabled && maxCount == tapFingers && !sessionSwiped
                && duration <= tapMaxDuration && maxMovement <= tapMaxMovement {
                events.append(.tap(fingers: maxCount))
                if let lt = lastTap, time - lt <= doubleTapInterval {
                    events.append(.doubleTap(fingers: maxCount))
                    lastTap = nil
                } else {
                    lastTap = time
                }
            } else {
                lastTap = nil
            }
        }
        return events
    }

    private func centroid(_ touches: [Touch]) -> (x: Double, y: Double) {
        let n = Double(touches.count)
        return (touches.reduce(0) { $0 + $1.x } / n, touches.reduce(0) { $0 + $1.y } / n)
    }

    private func velocity() -> Double {
        guard let first = samples.first, let lastSample = samples.last, lastSample.t - first.t > 0.005 else { return 0 }
        return (lastSample.y - first.y) / (lastSample.t - first.t)
    }
}
