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
    /// One pixel per point instead of the Retina backing (a quarter of the pixels).
    private static let nominalResolution: UInt32 = 1 << 9

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

    /// The window at `scale` of its own resolution (1: every pixel it has, lossless; the
    /// `captureScale` setting), and the size in points it shows. `expected`: the size the
    /// window should have, to tell its backing scale when screens differ. ~16 ms at full
    /// resolution; call it off the main thread.
    static func image(_ id: CGWindowID, scale: CGFloat, expected: CGSize = .zero) -> (image: CGImage, points: CGSize)? {
        let s = min(max(scale, 0.1), 1)
        let backing = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        // When one pixel per point is enough, the window server captures that small itself
        // (a quarter of the work on Retina); otherwise at full resolution, scaled down after.
        let nominal = backing * s <= 1.001
        var wid = id
        let options = ignoreClipShape | fullWindow | (nominal ? nominalResolution : 0)
        guard let raw = (CGSHWCaptureWindowList(connection, &wid, 1, options) as? [CGImage])?.first else { return nil }
        let points = nominal ? CGSize(width: raw.width, height: raw.height) : pointSize(of: raw, near: expected)
        let factor = nominal ? backing * s : s
        return (factor >= 0.999 ? raw : downscaled(raw, by: factor) ?? raw, points)
    }

    /// The window size (points) a full-resolution capture shows: its pixels over the backing
    /// scale, which is the screens' common one, or else the whole number closest to pixels /
    /// expected points.
    static func pointSize(of image: CGImage, near expected: CGSize) -> CGSize {
        let scales = Set(NSScreen.screens.map(\.backingScaleFactor))
        var scale = scales.count == 1 ? scales.first! : 0
        if scale == 0 {
            scale = expected.width > 0 ? max(1, (CGFloat(image.width) / expected.width).rounded()) : 2
        }
        return CGSize(width: (CGFloat(image.width) / scale).rounded(), height: (CGFloat(image.height) / scale).rounded())
    }

    /// `image` at `factor` of its size, in the capture's own pixel format (the live colour
    /// correction works on that).
    private static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let h = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let cs = image.colorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
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
    /// Capture resolution (the `captureScale` setting). Snapshots already taken keep theirs.
    var scale: CGFloat = 1

    /// Main thread: a requested snapshot is ready.
    var onReady: ((CGWindowID) -> Void)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func requestPermissionOnce() {
        guard !requestedPermission, !SnapshotCache.hasPermission else { return }
        requestedPermission = true
        CGRequestScreenCaptureAccess()
    }

    /// Latest snapshot, but only if it shows the window at this size. A window taller than
    /// asked (its app has a minimum height) still matches: the extra height is cropped.
    func image(_ id: CGWindowID, size: CGSize) -> CGImage? {
        guard let e = entries[id], abs(e.size.width - size.width) <= 3,
              e.size.height >= size.height - 3 else { return nil }
        return e.image
    }

    /// Latest snapshot whatever size it was taken at.
    func latestImage(_ id: CGWindowID) -> CGImage? { entries[id]?.image }

    /// The latest snapshot has the window's true on-screen colours.
    func isOnScreenCapture(_ id: CGWindowID) -> Bool { entries[id]?.onScreen ?? false }

    func age(_ id: CGWindowID) -> CFTimeInterval {
        entries[id].map { CACurrentMediaTime() - $0.time } ?? .infinity
    }

    func isCapturing(_ id: CGWindowID) -> Bool { inFlight.contains(id) }

    func remove(_ id: CGWindowID) {
        entries.removeValue(forKey: id)
        failedAt.removeValue(forKey: id)
    }

    /// Forgets capture failures older than a minute (the window may be capturable again).
    func forgetOldFailures() {
        let now = CACurrentMediaTime()
        for (id, t) in failedAt where now - t > 60 { failedAt.removeValue(forKey: id) }
    }

    func clear() { entries.removeAll() }

    /// Captures the window now (in the background, ~20 ms) at the given point size.
    func capture(_ id: CGWindowID, size: CGSize, onScreen: Bool) {
        guard SnapshotCache.hasPermission, !inFlight.contains(id),
              CACurrentMediaTime() - (failedAt[id] ?? 0) > 1 else { return }
        inFlight.insert(id)
        let scale = self.scale
        queue.async { [weak self] in
            var shot = WindowCapture.image(id, scale: scale, expected: size)
            if let s = shot, SnapshotCache.isBlank(s.image) { shot = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight.remove(id)
                guard let (image, actual) = shot else {
                    // Don't retry every frame (each attempt lights the recording indicator).
                    self.failedAt[id] = CACurrentMediaTime()
                    Log.debug("snapshot \(id) unusable")
                    return
                }
                // Filed under the size the window really had, not the one asked for: an app slow
                // to take a new size (or refusing it) was captured at its old one, and that
                // picture, fitted to the new frame, came out shrunk with gaps around it.
                if abs(actual.width - size.width) > 4 || abs(actual.height - size.height) > 4 {
                    Log.debug("snapshot \(id) is \(Int(actual.width))x\(Int(actual.height)), not \(Int(size.width))x\(Int(size.height))")
                }
                self.entries[id] = Entry(image: image, size: actual, time: CACurrentMediaTime(), onScreen: onScreen)
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
    /// Main thread: (frame, tiny signature for change detection). The frame is nil when the
    /// window hasn't changed since the last one (nothing to correct or draw).
    var onFrame: ((CGImage?, [UInt8]) -> Void)?
    private let fps: Double
    private let scale: CGFloat
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var reference: [UInt8]?
    private var bias: [Int16]?
    /// Frames since the colour shift was last measured, and whether a clear reading exists.
    private var sinceMeasure = 0
    private var measured = false
    /// Signature of the last captured frame as captured (before any colour correction).
    private var lastRaw: [UInt8] = []

    /// True-colour snapshot of the window: every frame's colours are measured against it
    /// and corrected (see ColorShift) before delivery.
    func setReference(_ image: CGImage?) {
        let grid = image.flatMap(ColorShift.grid)
        lock.lock(); reference = grid; lock.unlock()
    }
    private static let queue = DispatchQueue(label: "oz.mirror", qos: .userInteractive)

    init(id: CGWindowID, fps: Double, scale: CGFloat) {
        self.id = id
        self.fps = min(max(fps, 1), 60)
        self.scale = scale
    }

    func start() {
        let id = self.id, scale = self.scale
        let t = DispatchSource.makeTimerSource(queue: LiveMirror.queue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(4))
        // Frames never pile up: the handler runs serially and skips ticks while busy.
        let measureEvery = Int(fps * 2)
        t.setEventHandler { [weak self] in
            guard var image = WindowCapture.image(id, scale: scale)?.image else { return }
            // Unchanged since the last frame (most of the time, for anything but video): skip
            // the colour work and the redraw, just report it so an idle stream can stop.
            let raw = SnapshotCache.signature(image)
            if let self, raw == self.lastRaw {
                DispatchQueue.main.async { self.onFrame?(nil, raw) }
                return
            }
            self?.lastRaw = raw
            if let self {
                self.lock.lock(); let ref = self.reference; self.lock.unlock()
                // Measured until there is a clear reading (the window parks a moment after
                // streaming starts, and only a parked window loses its tint), then every 2 s
                // rather than every frame. Unclear readings (the content itself changed a
                // lot) keep the previous correction. With wallpaper tinting off (Oz turns
                // it off) there is usually no shift, and nothing is corrected at all.
                self.sinceMeasure += 1
                if let ref, !self.measured || self.sinceMeasure >= measureEvery, let grid = ColorShift.grid(image) {
                    self.sinceMeasure = 0
                    switch ColorShift.measure(reference: ref, frame: grid) {
                    case .shift(let s): self.bias = s; self.measured = true
                    case .none: self.bias = nil; self.measured = true
                    case .unclear: break
                    }
                }
                if let b = self.bias, let corrected = ColorShift.apply(b, to: image) { image = corrected }
            }
            let frame = image
            DispatchQueue.main.async { self?.onFrame?(frame, raw) }
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
    /// One table lookup per byte, in the frame's own byte order: the matrix multiply used
    /// before went through 16-bit planar copies and (un)premultiplying, several times the work.
    static func apply(_ bias: [Int16], to image: CGImage) -> CGImage? {
        guard bias.count == 4, image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              let format = vImage_CGImageFormat(cgImage: image),
              var buffer = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { buffer.free() }
        let tables = bias.map { b in (0..<256).map { Pixel_8(clamping: $0 + Int(b)) } }
        let err = vImageTableLookUp_ARGB8888(&buffer, &buffer, tables[0], tables[1], tables[2], tables[3],
                                             vImage_Flags(kvImageNoFlags))
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
/// A click, not a press: acting on mouse down started scrolling while the button was still
/// held, and a press that turns into a drag isn't a click.
private final class PeekView: NSView {
    var onClick: (() -> Void)?
    private var downAt: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downAt = NSEvent.mouseLocation }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard let d = downAt else { return }
        let p = NSEvent.mouseLocation
        if hypot(p.x - d.x, p.y - d.y) <= 4 { onClick?() }
    }
}

final class OverlayManager {
    /// Called with the window id when the user clicks a peeking window.
    var onClick: ((CGWindowID) -> Void)?
    /// Stream live content into peeks instead of showing a still snapshot.
    var live = true
    var liveFPS = 24.0
    /// Resolution of live frames (the `captureScale` setting).
    var captureScale: CGFloat = 1

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
        /// How much of the window is cut off at the bottom (scroll area above the screen bottom).
        var bottomCut: CGFloat = 0
        /// Drawn and clickable. A hidden overlay stays ordered in, transparent and click-through:
        /// taking a window off screen (`orderOut`) and back is a window-server round trip that
        /// stalled the main thread for up to half a second, many times per swipe.
        var shown = false
        /// The window it was last ordered just below (a window being dragged), if any.
        var orderedBelow: CGWindowID?
        var fading = false
        /// The content changed since the window shadow was last worked out.
        var shadowStale = true
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

    /// Shows `image` as if the window were at `full` (AX coordinates), cut off above `clipTop`
    /// and below `clipBottom`. Also used as a stand-in for a whole window (a slow app's window
    /// while scrolling): then `full` lies between the two and nothing is cut off.
    /// `stream`: keep it live (if live peeks are on); stand-ins during a scroll don't.
    /// `shadow`: drawn with a window shadow like the real one.
    /// `below`: a window being dragged, which must stay on top of the stand-ins.
    func show(_ id: CGWindowID, image: CGImage, full: CGRect, clipTop: CGFloat,
              clipBottom: CGFloat = .greatestFiniteMagnitude, trueColor: Bool = false,
              stream: Bool = true, shadow: Bool = false, below: CGWindowID? = nil) {
        if let o = overlays[id], o.fading {
            // Shown again while fading out: replace the running fade, or it would carry on to
            // zero and leave the stand-in invisible over a parked window (the window "vanished").
            o.fading = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                o.window.animator().alphaValue = 1
            }
            o.window.alphaValue = 1
        }
        let top = max(clipTop, full.minY)
        let bottom = min(clipBottom, full.maxY)
        let visibleHeight = bottom - top
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
        let nsY = Geometry.primaryHeight - bottom
        let frame = NSRect(x: full.minX, y: nsY, width: full.width, height: visibleHeight)

        o.expectedSize = full.size
        o.bottomCut = full.maxY - bottom
        if trueColor && o.reference == nil { o.reference = image }
        if live && stream && o.mirror == nil && !o.mirrorIdle { startMirror(o, id: id) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !o.isLive && o.image !== image {
            o.image = image
            o.imageLayer.contents = image
            o.shadowStale = true
        }
        o.imageLayer.contentsScale = o.window.backingScaleFactor
        OverlayManager.layoutImage(o, in: full.size)
        CATransaction.commit()

        // Layer-backed content: no need to force a synchronous redraw every frame.
        let resized = o.window.frame.size != frame.size
        o.window.setFrame(frame, display: false)
        if o.window.hasShadow != shadow {
            o.window.hasShadow = shadow
            o.shadowStale = true
        }
        // The window server works the shadow out from the content once and keeps it: worked
        // out while the stand-in was still empty, or before it changed shape, it would stay
        // missing or wrong. A move alone keeps it.
        if shadow && (resized || o.shadowStale) {
            o.shadowStale = false
            o.window.invalidateShadow()
        }
        if !o.shown {
            o.shown = true
            o.window.alphaValue = 1
            o.window.ignoresMouseEvents = false
            // Over the windows that came forward while it was hidden, but under a dragged one.
            if let below {
                o.window.order(.below, relativeTo: Int(below))
            } else {
                o.window.orderFrontRegardless()
            }
            o.orderedBelow = below
        } else if let below, o.orderedBelow != below {
            // Already showing when a drag started: tuck it under the dragged window once.
            o.window.order(.below, relativeTo: Int(below))
            o.orderedBelow = below
        }
    }

    /// Streams the window into the overlay. After ~2 s of identical frames (nothing
    /// playing) the stream stops and the last frame stays, so the screen-recording
    /// indicator goes away; `wake` restarts it on the next swipe.
    private func startMirror(_ o: Overlay, id: CGWindowID) {
        let mirror = LiveMirror(id: id, fps: liveFPS, scale: captureScale)
        let idleLimit = Int(liveFPS * 2)
        mirror.setReference(o.reference)
        mirror.onFrame = { [weak o] image, signature in
            guard let o, o.shown else { return }
            guard let image, signature != o.lastSignature else {
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

    /// Fills the window's frame with the picture, top-left aligned, cropping what sticks out:
    /// a picture of the right size fits exactly; one taken at another size (a stale stand-in,
    /// a window taller than asked) is cropped rather than shrunk, so there are never gaps
    /// around it or tiny text.
    private static func layoutImage(_ o: Overlay, in row: CGSize) {
        guard let image = o.image, image.width > 0, image.height > 0 else { return }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(row.width / iw, row.height / ih)
        let w = (iw * scale).rounded(), h = (ih * scale).rounded()
        o.imageLayer.frame = CGRect(x: 0, y: row.height - h - o.bottomCut, width: w, height: h)
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

    /// Turns live peeks on or off for the overlays already showing too. Off: each keeps the
    /// picture it has and nothing is captured any more (no recording indicator).
    func setLive(_ on: Bool) {
        live = on
        if on {
            for (id, o) in overlays where o.shown && o.mirror == nil {
                o.mirrorIdle = false
                o.unchangedFrames = 0
                startMirror(o, id: id)
            }
        } else {
            pauseMirrors()
        }
    }

    /// Restart idle live mirrors (the user is interacting again).
    func wake() {
        for (id, o) in overlays where o.mirrorIdle && o.shown {
            o.mirrorIdle = false
            o.unchangedFrames = 0
                if live { startMirror(o, id: id) }
        }
    }

    /// The real window is coming back at `frame`: keep the stand-in on top of it, unclipped,
    /// for a moment so there is no blank frame while the window server catches up.
    func handoff(_ id: CGWindowID, to frame: CGRect, delay: TimeInterval = 0.12) {
        guard let o = overlays[id], o.shown else { return }
        o.expectedSize = frame.size
        o.bottomCut = 0
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
        guard let o = overlays[id], o.shown else { return }
        stopLive(o)
        o.fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            o.window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard o.fading else { return }  // shown again meanwhile
            o.fading = false
            o.shown = false
            o.window.ignoresMouseEvents = true
            self?.release(o)
        })
    }

    /// Image currently shown for this window (latest live frame or the snapshot).
    func currentImage(_ id: CGWindowID) -> CGImage? { overlays[id]?.image }

    func hide(_ id: CGWindowID) {
        pendingHide.removeValue(forKey: id)?.cancel()
        guard let o = overlays[id], o.shown || o.fading else { return }
        o.fading = false
        o.shown = false
        stopLive(o)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            o.window.animator().alphaValue = 0
        }
        o.window.alphaValue = 0
        o.window.ignoresMouseEvents = true
        release(o)
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

    /// A hidden overlay stays ordered in (see `Overlay.shown`) but holds nothing: no picture,
    /// and a 1x1 window, so its backing store shrinks to nothing too.
    private func release(_ o: Overlay) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        o.imageLayer.contents = nil
        CATransaction.commit()
        o.window.setFrame(NSRect(x: o.window.frame.minX, y: o.window.frame.minY, width: 1, height: 1), display: false)
    }

    func isShowing(_ id: CGWindowID) -> Bool {
        overlays[id]?.shown ?? false
    }

    func remove(_ id: CGWindowID) {
        guard let o = overlays.removeValue(forKey: id) else { return }
        stopLive(o)
        o.window.orderOut(nil)
    }

    /// Hides every overlay and really takes them off screen: before Mission Control (it would
    /// show the transparent ones) and on quit.
    func hideAll() {
        for (id, o) in overlays {
            hide(id)
            o.window.orderOut(nil)
        }
    }
}
