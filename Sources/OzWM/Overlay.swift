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
    /// With the window's shadow around it, as the window server draws it (found by trying).
    private static let withShadowOption: UInt32 = 1 << 0

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
    /// resolution; call it off the main thread. `withShadow`: also the window's real shadow,
    /// as a picture of the window with its shadow around it and where the window sits in it.
    static func image(_ id: CGWindowID, scale: CGFloat, expected: CGSize = .zero,
                      withShadow: Bool = false) -> (image: CGImage, points: CGSize, shadow: WindowShadow?)? {
        let s = min(max(scale, 0.1), 1)
        let backing = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        // When one pixel per point is enough, the window server captures that small itself
        // (a quarter of the work on Retina); otherwise at full resolution, scaled down after.
        let nominal = backing * s <= 1.001
        var wid = id
        let options = ignoreClipShape | fullWindow | (nominal ? nominalResolution : 0) | (withShadow ? withShadowOption : 0)
        guard var raw = (CGSHWCaptureWindowList(connection, &wid, 1, options) as? [CGImage])?.first else { return nil }
        var shadow: WindowShadow?
        if withShadow {
            // The window alone is cut out of it (no copy), so everything else sees the usual picture.
            guard let r = windowRect(in: raw), let window = raw.cropping(to: r) else { return nil }
            let ppp = nominal ? 1 : CGFloat(window.width) / pointSize(of: window, near: expected).width
            let insets = NSEdgeInsets(top: r.minY / ppp, left: r.minX / ppp,
                                      bottom: (CGFloat(raw.height) - r.maxY) / ppp, right: (CGFloat(raw.width) - r.maxX) / ppp)
            if insets.left > 2, insets.left < 80, abs(insets.left - insets.right) < 3, insets.top >= 0, insets.top < 80,
               insets.bottom > 2, insets.bottom < 100 {
                shadow = WindowShadow(image: raw, insets: insets)
            }
            raw = window
        }
        let points = nominal ? CGSize(width: raw.width, height: raw.height) : pointSize(of: raw, near: expected)
        let factor = nominal ? backing * s : s
        return (factor >= 0.999 ? raw : downscaled(raw, by: factor) ?? raw, points, shadow)
    }

    /// Where the window lies in a capture with its shadow (pixels, top-left origin): the
    /// shadow is at most about 40% opaque, the window's edge (outside its rounded corners)
    /// fully, so scanning the middle row and column from outside in finds it. 95%: the
    /// anti-aliased pixel just outside the edge (~85%) isn't the window's.
    private static func windowRect(in image: CGImage) -> CGRect? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              image.bitsPerPixel == 32 else { return nil }
        let info = image.bitmapInfo, alphaInfo = image.alphaInfo
        let little = info.contains(.byteOrder32Little)
        let first = alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst
        let alphaIndex = little ? (first ? 3 : 0) : (first ? 0 : 3)
        let w = image.width, h = image.height, row = image.bytesPerRow
        func opaque(_ x: Int, _ y: Int) -> Bool { bytes[y * row + x * 4 + alphaIndex] >= 242 }
        let my = h / 2, mx = w / 2
        guard let left = (0..<w).first(where: { opaque($0, my) }),
              let right = (0..<w).reversed().first(where: { opaque($0, my) }),
              let top = (0..<h).first(where: { opaque(mx, $0) }),
              let bottom = (0..<h).reversed().first(where: { opaque(mx, $0) }),
              right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
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

/// A window's real shadow: a capture of the window with its shadow, and how far the shadow
/// reaches past each of the window's edges (points).
struct WindowShadow {
    let image: CGImage
    let insets: NSEdgeInsets
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
        let shadow: WindowShadow?
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

    /// The window's real shadow from its latest snapshot, if that has the same size.
    func shadow(_ id: CGWindowID, size: CGSize) -> WindowShadow? {
        guard let e = entries[id], abs(e.size.width - size.width) <= 3, abs(e.size.height - size.height) <= 3 else { return nil }
        return e.shadow
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
            var shot = WindowCapture.image(id, scale: scale, expected: size, withShadow: true)
            if let s = shot, SnapshotCache.isBlank(s.image) { shot = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight.remove(id)
                guard let (image, actual, shadow) = shot else {
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
                self.entries[id] = Entry(image: image, size: actual, shadow: shadow, time: CACurrentMediaTime(), onScreen: onScreen)
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
/// A stand-in's window: always exactly where it is put. AppKit otherwise pushes a window
/// that reaches into the menu bar down below it, and a stand-in with room for its shadow
/// above does: the picture jumped ~30 pt down, then slid back as it faded (a flicker).
private final class StandInPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

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
        /// Where the whole window lies in the overlay window (its own coordinates, y up): the
        /// part outside the overlay's bounds is cut off, the margin around it holds the shadow.
        var contentFrame = CGRect.zero
        /// The window's real shadow while moving (see `show`): its capture with the shadow,
        /// laid under the picture.
        let shadowLayer = CALayer()
        /// Stand-in for it until a capture with the shadow exists: a wide soft shadow and a
        /// thin one along the edge, as close to the system's as measured.
        let keyShadow = CALayer()
        let edgeShadow = CALayer()
        /// The shadow it draws while moving, if any, and where (AX coordinates) the window is.
        var ownShadow: ShadowKind?
        var fullRect = CGRect.zero
        /// The real window is on screen right under it: then its own shadow shows, and ours
        /// stays off, or the two would add up (a darker flash). Followed every frame from the
        /// window server (`syncShadows`), not guessed from when we asked the app to move it.
        var realCovers = false
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
            window = StandInPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
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
            shadowLayer.contentsGravity = .resize
            shadowLayer.isHidden = true
            shadowLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            view.layer?.addSublayer(shadowLayer)
            for (layer, opacity, radius, offset) in [(keyShadow, Float(0.45), CGFloat(11), CGFloat(-7.5)),
                                                     (edgeShadow, Float(0.35), CGFloat(0.75), CGFloat(0))] {
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = opacity
                layer.shadowRadius = radius
                layer.shadowOffset = CGSize(width: 0, height: offset)
                layer.isHidden = true
                layer.actions = ["bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull(), "hidden": NSNull()]
                view.layer?.addSublayer(layer)
            }
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
    /// `shadow`: drawn with a window shadow like the real one. `clickable`: a peek at rest,
    /// drawn without a margin so it doesn't take clicks meant for the windows around it.
    /// Otherwise (anything moving) the shadow is drawn in a margin around
    /// the picture, so it moves with it in the same frame and never has to be worked out
    /// again (the system's shadow is, on every size change, a frame or more late: flicker):
    /// `windowShadow`, the window's own as captured, so it is the very same as the real
    /// window's on either side of the switch.
    /// `below`: a window being dragged, which must stay on top of the stand-ins.
    func show(_ id: CGWindowID, image: CGImage, full: CGRect, clipTop: CGFloat,
              clipBottom: CGFloat = .greatestFiniteMagnitude, trueColor: Bool = false,
              stream: Bool = true, shadow: Bool = false, clickable: Bool = true, windowShadow: WindowShadow? = nil,
              below: CGWindowID? = nil) {
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
        o.expectedSize = full.size
        if !o.shown { o.realCovers = OverlayManager.realWindowsCovering([id: full])[id] ?? false }
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
        let ownShadow = shadow && !clickable
        let resized = place(o, full: full, top: top, bottom: bottom, clipTop: clipTop, clipBottom: clipBottom,
                            shadow: ownShadow ? (windowShadow.map { .captured($0) } ?? .drawn) : nil)
        CATransaction.commit()

        // At rest the system draws the shadow: its size doesn't change there, so it is
        // worked out once (again when the picture or size changes: worked out while the
        // stand-in was still empty, it would stay missing).
        let systemShadow = shadow && clickable
        if o.window.hasShadow != systemShadow {
            o.window.hasShadow = systemShadow
            o.shadowStale = true
        }
        if systemShadow && (resized || o.shadowStale) {
            o.shadowStale = false
            o.window.invalidateShadow()
        }
        if !o.shown {
            o.shown = true
            o.window.alphaValue = 1
            // Always takes clicks while shown: a stand-in still up when the motion is over is
            // the window as far as the user can tell (click-through, clicks hit the desktop).
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
            OverlayManager.layoutImage(o)
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
    private static func layoutImage(_ o: Overlay) {
        guard let image = o.image, image.width > 0, image.height > 0 else { return }
        let row = o.contentFrame
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(row.width / iw, row.height / ih)
        let w = (iw * scale).rounded(), h = (ih * scale).rounded()
        o.imageLayer.frame = CGRect(x: row.minX, y: row.maxY - h, width: w, height: h)
    }

    /// How far the system's shadow reaches past a window's edges (measured), for the drawn one.
    private static let drawnShadowInsets = NSEdgeInsets(top: 16, left: 23, bottom: 31, right: 23)
    /// Corner radius of macOS windows (measured), for the shape of the drawn shadow.
    private static let cornerRadius: CGFloat = 18

    fileprivate enum ShadowKind {
        case captured(WindowShadow)
        case drawn
    }

    /// Puts the overlay window over the visible part (`top`...`bottom`) of a window at `full`
    /// (AX coordinates), with room around it for `shadow` on the sides that aren't cut off,
    /// within the clip; lays the picture and shadow out inside. In a Core Animation
    /// transaction. True if the overlay window changed size.
    @discardableResult
    private func place(_ o: Overlay, full: CGRect, top: CGFloat, bottom: CGFloat,
                       clipTop: CGFloat = -.greatestFiniteMagnitude, clipBottom: CGFloat = .greatestFiniteMagnitude,
                       shadow: ShadowKind?) -> Bool {
        let m: NSEdgeInsets
        switch shadow {
        case .captured(let s): m = s.insets
        case .drawn: m = Self.drawnShadowInsets
        case nil: m = NSEdgeInsetsZero
        }
        let winTop = top > full.minY + 0.5 ? top : max(full.minY - m.top, clipTop)
        let winBottom = bottom < full.maxY - 0.5 ? bottom : min(full.maxY + m.bottom, clipBottom)
        let frame = NSRect(x: full.minX - m.left, y: Geometry.primaryHeight - winBottom,
                           width: full.width + m.left + m.right, height: winBottom - winTop)
        let content = CGRect(x: m.left, y: winBottom - full.maxY, width: full.width, height: full.height)
        if case .captured(let s) = shadow {
            if (o.shadowLayer.contents as AnyObject?) !== s.image { o.shadowLayer.contents = s.image }
            o.shadowLayer.frame = CGRect(x: 0, y: content.minY - m.bottom, width: frame.width,
                                         height: full.height + m.top + m.bottom)
        }
        if case .drawn = shadow, content.size != o.contentFrame.size {
            let path = CGPath(roundedRect: CGRect(origin: .zero, size: content.size),
                              cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
            o.keyShadow.shadowPath = path
            o.edgeShadow.shadowPath = path
        }
        o.ownShadow = shadow
        o.fullRect = full
        Self.showShadow(o)
        o.contentFrame = content
        o.keyShadow.frame = content
        o.edgeShadow.frame = content
        OverlayManager.layoutImage(o)
        // Layer-backed content: no need to force a synchronous redraw every frame.
        let resized = o.window.frame.size != frame.size
        o.window.setFrame(frame, display: false)
        return resized
    }

    /// Our shadow layers on or off: the kind asked for, unless the real window is right under.
    private static func showShadow(_ o: Overlay) {
        var captured = false, drawn = false
        if !o.realCovers {
            switch o.ownShadow {
            case .captured: captured = true
            case .drawn: drawn = true
            case nil: break
            }
        }
        o.shadowLayer.isHidden = !captured
        o.keyShadow.isHidden = !drawn
        o.edgeShadow.isHidden = !drawn
    }

    /// Whether each real window is on screen covering most of the given frame (AX coordinates),
    /// as the window server has it now. One query for all of them.
    private static func realWindowsCovering(_ frames: [CGWindowID: CGRect]) -> [CGWindowID: Bool] {
        guard !frames.isEmpty else { return [:] }
        let ids = Array(frames.keys)
        let values = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: ids.count)
        defer { values.deallocate() }
        for (i, id) in ids.enumerated() { values[i] = UnsafeRawPointer(bitPattern: UInt(id)) }
        guard let array = CFArrayCreate(nil, values, ids.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [:] }
        var out: [CGWindowID: Bool] = [:]
        for info in list {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, let full = frames[id],
                  let b = info[kCGWindowBounds as String] else { continue }
            var r = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &r)
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let overlap = r.intersection(full)
            out[id] = onScreen && !overlap.isNull && overlap.width * overlap.height >= full.width * full.height * 0.5
        }
        return out
    }

    /// Each frame something moves (and while handing over): our shadows follow whether the
    /// real windows are under their stand-ins right now.
    func syncShadows() {
        var frames: [CGWindowID: CGRect] = [:]
        for (id, o) in overlays where o.shown && o.ownShadow != nil { frames[id] = o.fullRect }
        let covering = Self.realWindowsCovering(frames)
        var changed: [Overlay] = []
        for (id, covers) in covering {
            guard let o = overlays[id], o.realCovers != covers else { continue }
            o.realCovers = covers
            changed.append(o)
        }
        guard !changed.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changed.forEach(Self.showShadow)
        CATransaction.commit()
    }

    /// Keeps `syncShadows` going after the motion stopped (the display link pauses then),
    /// until every handover is through.
    private var handoffTimer: Timer?
    private func followHandoffs() {
        guard handoffTimer == nil else { return }
        handoffTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.syncShadows()
            if self.pendingHide.isEmpty && !self.overlays.values.contains(where: { $0.fading }) {
                t.invalidate()
                self.handoffTimer = nil
            }
        }
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Our shadow stays until the real window is really back underneath with its own
        // (`syncShadows` sees it), not one frame less (no shadow) or more (two).
        place(o, full: frame, top: frame.minY, bottom: frame.maxY, shadow: o.ownShadow)
        CATransaction.commit()
        o.window.display()
        followHandoffs()
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
