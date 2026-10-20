import Accelerate
import Cocoa
import QuartzCore

@_silgen_name("CGSHWCaptureWindowList")
private func CGSHWCaptureWindowList(_ cid: Int32, _ windows: UnsafeMutablePointer<UInt32>,
                                    _ count: UInt32, _ options: UInt32) -> CFArray?

/// Captures a window's own content, including the parts that are off screen (our parked
/// windows live almost entirely off screen). This is the private SkyLight call AltTab uses
/// for thumbnails: unlike ScreenCaptureKit it does not turn on the purple screen-recording
/// indicator in the menu bar. Still needs the Screen Recording permission.
enum WindowCapture {
    private static let ignoreClipShape: UInt32 = 1 << 11
    private static let fullWindow: UInt32 = 1 << 15

    /// A window-server connection of our own for capturing. A capture holds its connection's
    /// lock for its whole duration; on the main connection that blocked the main thread's
    /// Core Animation commits (measured: 0.5 s stalls, and a hitch on every live-peek frame).
    private static let connection: Int32 = {
        typealias NewConnection = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> Int32
        if let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
           let sym = dlsym(sky, "SLSNewConnection") {
            var cid: Int32 = 0
            if unsafeBitCast(sym, to: NewConnection.self)(0, &cid) == 0, cid != 0 { return cid }
        }
        return Spaces.connection
    }()

    /// ~16 ms; call it off the main thread.
    static func image(_ id: CGWindowID) -> CGImage? {
        var wid = id
        return (CGSHWCaptureWindowList(connection, &wid, 1, ignoreClipShape | fullWindow) as? [CGImage])?.first
    }
}

/// macOS refuses to put a window above the menu bar, so a row can't really
/// scroll off the top edge. While the strip is moving we instead hide the real
/// window and draw a snapshot of it in our own borderless window, clipped at
/// the top edge, so it looks like it slides off just like at the bottom.
/// Snapshots of windows that are sliding off the top edge. Captures happen only on
/// demand, the moment a window starts to peek, so macOS's screen-recording indicator
/// stays off the rest of the time. The capture reads the window's own content whatever
/// its position, so a window can be captured while moving or parked off screen, as
/// long as it has its real (unshrunk) size.
final class SnapshotCache {
    private struct Entry {
        let image: CGImage
        let size: CGSize
        let time: CFTimeInterval
        /// Taken while the window was on screen. A parked (off-screen) window loses the
        /// wallpaper tint macOS gives window backgrounds, so its capture looks greyer.
        let onScreen: Bool
    }
    private var entries: [CGWindowID: Entry] = [:]
    private var inFlight = Set<CGWindowID>()
    private var failedAt: [CGWindowID: CFTimeInterval] = [:]
    private var requestedPermission = false
    private let queue = DispatchQueue(label: "oz.snapshots", qos: .userInteractive)

    /// Main thread: a requested snapshot is ready.
    var onReady: ((CGWindowID) -> Void)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func requestPermissionOnce() {
        guard !requestedPermission, !SnapshotCache.hasPermission else { return }
        requestedPermission = true
        CGRequestScreenCaptureAccess()
    }

    /// Latest snapshot, but only if it was taken at this size (else it would be stretched).
    func image(_ id: CGWindowID, size: CGSize) -> CGImage? {
        guard let e = entries[id], abs(e.size.width - size.width) <= 3,
              abs(e.size.height - size.height) <= 3 else { return nil }
        return e.image
    }

    /// The latest snapshot has the window's true on-screen colours.
    func isOnScreenCapture(_ id: CGWindowID) -> Bool { entries[id]?.onScreen ?? false }

    func age(_ id: CGWindowID) -> CFTimeInterval {
        entries[id].map { CACurrentMediaTime() - $0.time } ?? .infinity
    }

    func isCapturing(_ id: CGWindowID) -> Bool { inFlight.contains(id) }

    func remove(_ id: CGWindowID) { entries.removeValue(forKey: id) }

    func clear() { entries.removeAll() }

    /// Captures the window now (in the background, ~20 ms) at the given point size.
    func capture(_ id: CGWindowID, size: CGSize, onScreen: Bool) {
        guard SnapshotCache.hasPermission, !inFlight.contains(id),
              CACurrentMediaTime() - (failedAt[id] ?? 0) > 1 else { return }
        inFlight.insert(id)
        queue.async { [weak self] in
            var image = WindowCapture.image(id)
            if let img = image, SnapshotCache.isBlank(img) { image = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight.remove(id)
                guard let image else {
                    // Don't retry every frame (each attempt lights the recording indicator).
                    self.failedAt[id] = CACurrentMediaTime()
                    Log.debug("snapshot \(id) unusable")
                    return
                }
                self.entries[id] = Entry(image: image, size: size, time: CACurrentMediaTime(), onScreen: onScreen)
                self.onReady?(id)
            }
        }
    }

    /// 8x8 thumbnail bytes: cheap way to tell whether two frames differ.
    static func signature(_ image: CGImage) -> [UInt8] {
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return pixels
    }

    /// True if the image is (almost) fully transparent.
    private static func isBlank(_ image: CGImage) -> Bool {
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var alpha = 0
        for i in stride(from: 3, to: pixels.count, by: 4) { alpha += Int(pixels[i]) }
        return alpha < n * n * 255 / 4
    }
}

/// Re-captures a (parked) window at a fixed frame rate, so a peeking window keeps
/// playing video, scrolling text, etc. instead of showing a still.
final class LiveMirror {
    let id: CGWindowID
    /// Main thread: (frame, tiny signature for change detection).
    var onFrame: ((CGImage, [UInt8]) -> Void)?
    private let fps: Double
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var reference: [UInt8]?
    private var bias: [Int16]?

    /// True-colour snapshot of the window: every frame's colours are measured against it
    /// and corrected (see ColorShift) before delivery.
    func setReference(_ image: CGImage?) {
        let grid = image.flatMap(ColorShift.grid)
        lock.lock(); reference = grid; lock.unlock()
    }
    private static let queue = DispatchQueue(label: "oz.mirror", qos: .userInteractive)

    init(id: CGWindowID, fps: Double) {
        self.id = id
        self.fps = min(max(fps, 1), 60)
    }

    func start() {
        let id = self.id
        let t = DispatchSource.makeTimerSource(queue: LiveMirror.queue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(4))
        // Frames never pile up: the handler runs serially and skips ticks while busy.
        t.setEventHandler { [weak self] in
            guard var image = WindowCapture.image(id) else { return }
            if let self {
                self.lock.lock(); let ref = self.reference; self.lock.unlock()
                // Re-measured every frame: the window parks a moment after streaming starts,
                // and only a parked window loses its tint. Unclear readings (the content
                // itself changed a lot) keep the previous correction.
                if let ref, let grid = ColorShift.grid(image) {
                    switch ColorShift.measure(reference: ref, frame: grid) {
                    case .shift(let s): self.bias = s
                    case .none: self.bias = nil
                    case .unclear: break
                    }
                }
                if let b = self.bias, let corrected = ColorShift.apply(b, to: image) { image = corrected }
            }
            let signature = SnapshotCache.signature(image)
            DispatchQueue.main.async { self?.onFrame?(image, signature) }
        }
        t.resume()
        timer = t
        Log.debug("live mirror \(id) started at \(Int(fps)) fps")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onFrame = nil
    }
}

/// The wallpaper tint a window loses while parked off screen is, in practice, a small constant
/// shift of the encoded channel values (measured on Finder: R -1, G +4, B +5). We measure it
/// once per stream (true-colour snapshot vs first parked frame) and add it back to every frame.
enum ColorShift {
    enum Reading { case shift([Int16]), none, unclear }

    /// Median per-channel difference `reference - frame` in the frames' byte order (B, G, R, A),
    /// accepted only when most of the window agrees on it: a uniform tint, not new content.
    static func measure(reference a: [UInt8], frame b: [UInt8]) -> Reading {
        guard a.count == b.count, !a.isEmpty else { return .unclear }
        var shift: [Int16] = []
        for c in 0..<3 {
            var d: [Int] = []
            for i in stride(from: c, to: a.count, by: 4) { d.append(Int(a[i]) - Int(b[i])) }
            d.sort()
            let median = d[d.count / 2]
            let agreeing = d.filter { abs($0 - median) <= 1 }.count
            guard agreeing * 10 >= d.count * 6, abs(median) <= 16 else { return .unclear }
            shift.append(Int16(median))
        }
        return shift.contains(where: { abs($0) >= 2 }) ? .shift(shift + [0]) : .none
    }

    /// Adds `bias` to every pixel (saturating), keeping the image's format and colour space.
    static func apply(_ bias: [Int16], to image: CGImage) -> CGImage? {
        guard let format = vImage_CGImageFormat(cgImage: image) else { return nil }
        guard var buffer = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { buffer.free() }
        let identity: [Int16] = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1]
        var post = bias.map(Int32.init)
        let err = vImageMatrixMultiply_ARGB8888(&buffer, &buffer, identity, 1, nil, &post, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }
        return try? buffer.createCGImage(format: format)
    }

    /// 32x32 thumbnail in the image's own byte layout (no colour conversion).
    static func grid(_ image: CGImage) -> [UInt8]? {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let cs = image.colorSpace,
              let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return px
    }
}

/// Click target for a peeking window: clicking the visible strip brings the real window back.
private final class PeekView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class OverlayManager {
    /// Called with the window id when the user clicks a peeking window.
    var onClick: ((CGWindowID) -> Void)?
    /// Stream live content into peeks instead of showing a still snapshot.
    var live = true
    var liveFPS = 24.0

    private final class Overlay {
        let window: NSPanel
        let imageLayer = CALayer()
        var image: CGImage?
        var mirror: LiveMirror?
        /// Set once live frames arrive; the still snapshot is no longer drawn.
        var isLive = false
        /// The mirror was stopped because nothing changed; the last frame stays up.
        var mirrorIdle = false
        var lastSignature: [UInt8] = []
        var unchangedFrames = 0
        /// Row size the stand-in represents (the window may be taller if the app refused).
        var expectedSize = CGSize.zero
        var fading = false
        /// Snapshot with true on-screen colours, to calibrate the live stream against.
        var reference: CGImage?

        init() {
            window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.level = .normal
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            // Not .transient: that would make it follow you to other Spaces. It belongs to the
            // Space of the strip it stands in for, so switching away and back needs no redraw.
            window.collectionBehavior = [.ignoresCycle, .fullScreenNone]
            let view = PeekView()
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            imageLayer.contentsGravity = .resize
            imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            view.layer?.addSublayer(imageLayer)
            window.contentView = view
        }
    }

    private var overlays: [CGWindowID: Overlay] = [:]
    private var pendingHide: [CGWindowID: DispatchWorkItem] = [:]

    /// Shows `image` as if the window were at `full` (AX coordinates), cut off above `clipTop`.
    /// Also used as a stand-in for a whole window (a slow app's window while scrolling):
    /// then `full` lies below `clipTop` and nothing is cut off.
    func show(_ id: CGWindowID, image: CGImage, full: CGRect, clipTop: CGFloat, trueColor: Bool = false) {
        if let o = overlays[id], o.fading {
            o.fading = false
            o.window.alphaValue = 1
        }
        let top = max(clipTop, full.minY)
        let visibleHeight = full.maxY - top
        guard visibleHeight > 0 else { return hide(id) }
        pendingHide.removeValue(forKey: id)?.cancel()
        let o: Overlay
        if let existing = overlays[id] {
            o = existing
        } else {
            o = Overlay()
            (o.window.contentView as? PeekView)?.onClick = { [weak self] in self?.onClick?(id) }
            overlays[id] = o
        }
        let nsY = Geometry.primaryHeight - full.maxY
        let frame = NSRect(x: full.minX, y: nsY, width: full.width, height: visibleHeight)

        o.expectedSize = full.size
        if trueColor && o.reference == nil { o.reference = image }
        if live && o.mirror == nil && !o.mirrorIdle { startMirror(o, id: id) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !o.isLive && o.image !== image {
            o.image = image
            o.imageLayer.contents = image
        }
        o.imageLayer.contentsScale = o.window.backingScaleFactor
        OverlayManager.layoutImage(o, in: full.size)
        CATransaction.commit()

        // Layer-backed content: no need to force a synchronous redraw every frame.
        o.window.setFrame(frame, display: false)
        if !o.window.isVisible { o.window.orderFrontRegardless() }
    }

    /// Streams the window into the overlay. After ~2 s of identical frames (nothing
    /// playing) the stream stops and the last frame stays, so the screen-recording
    /// indicator goes away; `wake` restarts it on the next swipe.
    private func startMirror(_ o: Overlay, id: CGWindowID) {
        let mirror = LiveMirror(id: id, fps: liveFPS)
        let idleLimit = Int(liveFPS * 2)
        mirror.setReference(o.reference)
        mirror.onFrame = { [weak o] image, signature in
            guard let o, o.window.isVisible else { return }
            if signature == o.lastSignature {
                o.unchangedFrames += 1
                if o.unchangedFrames >= idleLimit {
                    Log.debug("live mirror \(id) idle, stopping")
                    o.mirror?.stop()
                    o.mirror = nil
                    o.mirrorIdle = true
                }
                return
            }
            o.lastSignature = signature
            o.unchangedFrames = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            o.imageLayer.contents = image
            o.image = image
            OverlayManager.layoutImage(o, in: o.expectedSize)
            CATransaction.commit()
            o.isLive = true
        }
        o.mirror = mirror
        mirror.start()
    }

    /// Places the window image so its top edge sits on the row's top edge, at the image's own
    /// aspect ratio. A window the app keeps taller than its row (minimum size) then just
    /// runs past the row's bottom, exactly like the real window would, instead of being squashed.
    /// AppKit views are bottom-up and clip: only the part inside the overlay shows.
    private static func layoutImage(_ o: Overlay, in row: CGSize) {
        guard let image = o.image, image.width > 0 else { return }
        let height = (row.width * CGFloat(image.height) / CGFloat(image.width)).rounded()
        o.imageLayer.frame = CGRect(x: 0, y: row.height - height, width: row.width, height: height)
    }

    /// Stops every live stream but keeps the stand-ins (with their last frame) in place, e.g.
    /// when switching Spaces. The next layout of a visible strip starts its streams again.
    func pauseMirrors() {
        for o in overlays.values {
            o.mirror?.stop()
            o.mirror = nil
                o.mirrorIdle = false
            o.unchangedFrames = 0
        }
    }

    /// Restart idle live mirrors (the user is interacting again).
    func wake() {
        for (id, o) in overlays where o.mirrorIdle && o.window.isVisible {
            o.mirrorIdle = false
            o.unchangedFrames = 0
                if live { startMirror(o, id: id) }
        }
    }

    /// The real window is coming back at `frame`: keep the stand-in on top of it, unclipped,
    /// for a moment so there is no blank frame while the window server catches up.
    func handoff(_ id: CGWindowID, to frame: CGRect, delay: TimeInterval = 0.12) {
        guard let o = overlays[id], o.window.isVisible else { return }
        o.expectedSize = frame.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        OverlayManager.layoutImage(o, in: frame.size)
        CATransaction.commit()
        o.window.setFrame(NSRect(x: frame.minX, y: Geometry.primaryHeight - frame.maxY,
                                 width: frame.width, height: frame.height), display: true)
        guard pendingHide[id] == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.fadeOut(id) }
        pendingHide[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Hands over to the real window with a short cross-fade: macOS tints window
    /// backgrounds with the wallpaper colour, which a capture can't fully reproduce, so a
    /// hard cut would show a small colour jump.
    func fadeOut(_ id: CGWindowID, duration: TimeInterval = 0.18) {
        pendingHide.removeValue(forKey: id)?.cancel()
        guard let o = overlays[id], o.window.isVisible else { return }
        stopLive(o)
        o.fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            o.window.animator().alphaValue = 0
        }, completionHandler: {
            guard o.fading else { return }  // shown again meanwhile
            o.fading = false
            o.window.orderOut(nil)
            o.window.alphaValue = 1
        })
    }

    /// Image currently shown for this window (latest live frame or the snapshot).
    func currentImage(_ id: CGWindowID) -> CGImage? { overlays[id]?.image }

    func hide(_ id: CGWindowID) {
        pendingHide.removeValue(forKey: id)?.cancel()
        guard let o = overlays[id] else { return }
        o.fading = false
        o.window.alphaValue = 1
        stopLive(o)
        o.window.orderOut(nil)
    }

    private func stopLive(_ o: Overlay) {
        o.mirror?.stop()
        o.mirror = nil
        o.reference = nil
        o.isLive = false
        o.mirrorIdle = false
        o.unchangedFrames = 0
        o.lastSignature = []
        o.image = nil
    }

    func isShowing(_ id: CGWindowID) -> Bool {
        overlays[id]?.window.isVisible ?? false
    }

    func remove(_ id: CGWindowID) {
        guard let o = overlays.removeValue(forKey: id) else { return }
        stopLive(o)
        o.window.orderOut(nil)
    }

    func hideAll() {
        overlays.keys.forEach(hide)
    }
}
