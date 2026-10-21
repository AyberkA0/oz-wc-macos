import Cocoa

/// Full-screen editor for a desktop's scroll area, in the style of the macOS screen
/// recording picker (⌘⇧5): the windows are hidden behind the wallpaper, everything outside
/// the area is dimmed, and the hatched area is dragged by its edges/corners or moved whole.
final class ScrollAreaEditor: NSObject {
    /// Result as fractions of the screen's visible frame (x, y from the top-left, width,
    /// height); nil means the whole screen. Not called when cancelled.
    private let onDone: (CGRect?) -> Void
    private let window: EditorWindow
    private var finished = false
    /// Called once the editor is gone, saved or not.
    var onClose: (() -> Void)?
    /// Esc / Return as global hotkeys: macOS may not let Oz take keyboard focus (it refuses
    /// activation that doesn't follow a click, e.g. when opened by a shortcut).
    private var releaseKeys: [() -> Void] = []

    init(screen: NSScreen, fraction: CGRect?, onDone: @escaping (CGRect?) -> Void) {
        self.onDone = onDone
        window = EditorWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init()
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        window.becomesKeyOnlyIfNeeded = false
        window.setFrame(screen.frame, display: false)

        let view = EditorView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
        view.selection = fraction.map(view.rect(fromFraction:)) ?? view.usable
        view.onSave = { [weak self] in self?.finish(save: true) }
        view.onCancel = { [weak self] in self?.finish(save: false) }
        window.contentView = view
    }

    func show() {
        // A non-activating panel takes the keyboard without activating Oz: macOS refuses
        // activation that doesn't follow a click (opened by a shortcut), which left the
        // editor deaf to Esc / Return.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        let keys: [(String, Bool)] = [("escape", false), ("return", true)]
        releaseKeys = keys.compactMap { combo, save in
            HotkeyCenter.shared.registerTemporary(combo) { [weak self] in self?.finish(save: save) }
        }


    }

    private func finish(save: Bool) {
        guard !finished, let view = window.contentView as? EditorView else { return }
        finished = true
        releaseKeys.forEach { $0() }
        releaseKeys = []
        let result = view.fraction()
        window.orderOut(nil)
        if save { onDone(result) }
        onClose?()
    }
}

private final class EditorWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class EditorView: NSView {
    var selection = NSRect.zero { didSet { updateLayers(); window?.invalidateCursorRects(for: self) } }
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The part of the screen windows may use (below the menu bar, beside the Dock), view coordinates.
    let usable: NSRect
    private let minSize = NSSize(width: 240, height: 160)
    private let handle: CGFloat = 10

    // Drawn by Core Animation: redrawing a full Retina screen on the CPU took most of a
    // second per frame, far too slow to follow a drag.
    private let canvas = NSView()
    private let wallpaperLayer = CALayer()
    private let hatchLayer = CALayer()
    private let hatchMask = CAShapeLayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let badge = NSView()
    private let sizeLabel = NSTextField(labelWithString: "")

    /// What a drag changes: edges to move (resize), all four (move), or a new rectangle.
    private struct Drag {
        var left = false, right = false, bottom = false, top = false
        var start = NSPoint.zero
        var original = NSRect.zero
        var drawing = false
    }
    private var drag: Drag?

    init(frame: NSRect, screen: NSScreen) {
        let vf = screen.visibleFrame
        usable = NSRect(x: vf.minX - screen.frame.minX, y: vf.minY - screen.frame.minY, width: vf.width, height: vf.height)
        super.init(frame: frame)
        setupLayers(scale: screen.backingScaleFactor)
        addControls()
        loadImages(screen: screen)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Fractions of the usable area (y from the top, like AX coordinates)

    func rect(fromFraction f: CGRect) -> NSRect {
        let w = f.width * usable.width, h = f.height * usable.height
        return NSRect(x: usable.minX + f.minX * usable.width, y: usable.maxY - f.minY * usable.height - h,
                      width: w, height: h).integral
    }

    /// nil when the selection covers (nearly) the whole usable area.
    func fraction() -> CGRect? {
        let s = selection.intersection(usable)
        if abs(s.minX - usable.minX) < 4 && abs(s.maxX - usable.maxX) < 4
            && abs(s.minY - usable.minY) < 4 && abs(s.maxY - usable.maxY) < 4 { return nil }
        return CGRect(x: (s.minX - usable.minX) / usable.width, y: (usable.maxY - s.maxY) / usable.height,
                      width: s.width / usable.width, height: s.height / usable.height)
    }

    // MARK: Drawing

    private func setupLayers(scale: CGFloat) {
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        canvas.layer = root
        canvas.wantsLayer = true
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)

        wallpaperLayer.contentsGravity = .resizeAspectFill
        hatchLayer.mask = hatchMask
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.6).cgColor
        dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [6, 4]
        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor.black.withAlphaComponent(0.4).cgColor
        for l in [wallpaperLayer, hatchLayer, dimLayer, borderLayer, handleLayer] {
            l.frame = bounds
            l.contentsScale = scale
            l.actions = ["path": NSNull(), "contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            root.addSublayer(l)
        }
        hatchMask.frame = bounds

        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 7
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        sizeLabel.textColor = .white
        badge.addSubview(sizeLabel)
        addSubview(badge)
    }

    /// The wallpaper (aspect-filled, like the desktop) and the hatch pattern, both rendered
    /// once off the main thread; the editor shows over black until they're ready.
    private func loadImages(screen: NSScreen) {
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let size = bounds.size, scale = screen.backingScaleFactor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let w = Int(size.width * scale), h = Int(size.height * scale)
            func context() -> CGContext? {
                CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            }
            if let ctx = context() {
                // Diagonal lines over a faint fill.
                ctx.scaleBy(x: scale, y: scale)
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
                ctx.setLineWidth(1)
                var x = -size.height
                while x < size.width {
                    ctx.move(to: CGPoint(x: x, y: 0))
                    ctx.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    x += 14
                }
                ctx.strokePath()
                let hatch = ctx.makeImage()
                DispatchQueue.main.async { self?.hatchLayer.contents = hatch }
            }
            if let url, let image = NSImage(contentsOf: url) {
                var rect = NSRect(origin: .zero, size: image.size)
                guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), let ctx = context() else { return }
                let s = max(CGFloat(w) / CGFloat(cg.width), CGFloat(h) / CGFloat(cg.height))
                let dw = CGFloat(cg.width) * s, dh = CGFloat(cg.height) * s
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
                let filled = ctx.makeImage()
                DispatchQueue.main.async { self?.wallpaperLayer.contents = filled }
            }
        }
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addRect(selection)
        dimLayer.path = dim
        hatchMask.path = CGPath(rect: selection, transform: nil)
        borderLayer.path = CGPath(rect: selection.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        let handles = CGMutablePath()
        for p in handlePoints() { handles.addEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)) }
        handleLayer.path = handles
        CATransaction.commit()

        sizeLabel.stringValue = "\(Int(selection.width)) × \(Int(selection.height))"
        sizeLabel.sizeToFit()
        let ls = sizeLabel.frame.size
        badge.frame = NSRect(x: (selection.midX - ls.width / 2 - 10).rounded(), y: (selection.midY - ls.height / 2 - 5).rounded(),
                             width: ls.width + 20, height: ls.height + 10)
        sizeLabel.setFrameOrigin(NSPoint(x: 10, y: 5))
    }

    private func handlePoints() -> [NSPoint] {
        let s = selection
        return [NSPoint(x: s.minX, y: s.minY), NSPoint(x: s.midX, y: s.minY), NSPoint(x: s.maxX, y: s.minY),
                NSPoint(x: s.minX, y: s.midY), NSPoint(x: s.maxX, y: s.midY),
                NSPoint(x: s.minX, y: s.maxY), NSPoint(x: s.midX, y: s.maxY), NSPoint(x: s.maxX, y: s.maxY)]
    }

    // MARK: Controls (a pill at the bottom, like ⌘⇧5)

    private func addControls() {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .behindWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12

        func button(_ title: String, _ action: Selector, key: String = "") -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.keyEquivalent = key
            return b
        }
        let presets = NSSegmentedControl(labels: ["Left ½", "Right ½", "Left ⅔", "Right ⅔", "Full"],
                                         trackingMode: .momentary, target: self, action: #selector(preset(_:)))
        let stack = NSStackView(views: [
            presets,
            button("Cancel", #selector(cancel), key: "\u{1b}"),
            button("Set Scroll Area", #selector(save), key: "\r"),
        ])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        let hint = NSTextField(labelWithString: "Drag the edges to resize, drag inside to move, or draw a new area. Return saves, Esc cancels.")
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 12)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(usable.minY + 40)),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
        ])
    }

    @objc private func save() { onSave?() }
    @objc private func cancel() { onCancel?() }

    @objc private func preset(_ sender: NSSegmentedControl) {
        let u = usable
        switch sender.selectedSegment {
        case 0: selection = NSRect(x: u.minX, y: u.minY, width: (u.width / 2).rounded(), height: u.height)
        case 1: selection = NSRect(x: u.minX + (u.width / 2).rounded(), y: u.minY, width: u.width - (u.width / 2).rounded(), height: u.height)
        case 2: selection = NSRect(x: u.minX, y: u.minY, width: (u.width * 2 / 3).rounded(), height: u.height)
        case 3: selection = NSRect(x: u.maxX - (u.width * 2 / 3).rounded(), y: u.minY, width: (u.width * 2 / 3).rounded(), height: u.height)
        default: selection = u
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()          // esc
        case 36, 76: onSave?()        // return, enter
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        let s = selection, h = handle
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(s.insetBy(dx: h, dy: h), cursor: .openHand)
        addCursorRect(NSRect(x: s.minX - h, y: s.minY + h, width: 2 * h, height: s.height - 2 * h), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: s.maxX - h, y: s.minY + h, width: 2 * h, height: s.height - 2 * h), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: s.minX + h, y: s.minY - h, width: s.width - 2 * h, height: 2 * h), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: s.minX + h, y: s.maxY - h, width: s.width - 2 * h, height: 2 * h), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = selection, h = handle
        var d = Drag(start: p, original: s)
        let nearX = p.y > s.minY - h && p.y < s.maxY + h
        let nearY = p.x > s.minX - h && p.x < s.maxX + h
        d.left = nearX && abs(p.x - s.minX) <= h
        d.right = nearX && abs(p.x - s.maxX) <= h
        d.bottom = nearY && abs(p.y - s.minY) <= h
        d.top = nearY && abs(p.y - s.maxY) <= h
        if !(d.left || d.right || d.bottom || d.top) {
            if s.contains(p) {
                d.left = true; d.right = true; d.bottom = true; d.top = true   // move
                NSCursor.closedHand.set()
            } else {
                d.drawing = true
            }
        }
        drag = d
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let u = usable
        if d.drawing {
            let a = clamp(d.start, to: u), b = clamp(p, to: u)
            selection = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            return
        }
        let dx = p.x - d.start.x, dy = p.y - d.start.y
        var r = d.original
        if d.left && d.right && d.top && d.bottom {
            r.origin.x = min(max(r.minX + dx, u.minX), u.maxX - r.width)
            r.origin.y = min(max(r.minY + dy, u.minY), u.maxY - r.height)
        } else {
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            if d.left { minX = min(max(r.minX + dx, u.minX), maxX - minSize.width) }
            if d.right { maxX = max(min(r.maxX + dx, u.maxX), minX + minSize.width) }
            if d.bottom { minY = min(max(r.minY + dy, u.minY), maxY - minSize.height) }
            if d.top { maxY = max(min(r.maxY + dy, u.maxY), minY + minSize.height) }
            r = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        selection = r.integral
    }

    override func mouseUp(with event: NSEvent) {
        if let d = drag, d.drawing, selection.width < minSize.width || selection.height < minSize.height {
            // A click or a tiny drag: keep the previous area.
            selection = d.original
        }
        drag = nil
        window?.invalidateCursorRects(for: self)
    }

    private func clamp(_ p: NSPoint, to r: NSRect) -> NSPoint {
        NSPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }
}
