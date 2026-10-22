import Cocoa

/// Demo mode: stand-in app windows to show Oz off with, themed on L. Frank Baum's
/// "The Wonderful Wizard of Oz" (1900). Each is a real window of a little app of its own
/// (`OzWM demo`, so Oz tiles it like any other) whose content is a scene drawn for the
/// window's size, again whenever it changes.
enum Demo {
    /// To the demo app: `open:<n>` opens a window with theme n, `quit` closes them all.
    static let notification = Notification.Name("dev.oz.wm.demo")

    enum Theme: Int, CaseIterable {
        case kansas, yellowBrickRoad, emeraldCity, poppyField, munchkinCountry, tinWoodman, witchCastle, glinda

        var title: String {
            switch self {
            case .kansas: return "Kansas"
            case .yellowBrickRoad: return "The Yellow Brick Road"
            case .emeraldCity: return "The Emerald City"
            case .poppyField: return "The Poppy Field"
            case .munchkinCountry: return "The Country of the Munchkins"
            case .tinWoodman: return "The Tin Woodman"
            case .witchCastle: return "The Wicked Witch of the West"
            case .glinda: return "Glinda the Good"
            }
        }

        var subtitle: String {
            switch self {
            case .kansas: return "Dorothy and Toto, on the great gray prairie"
            case .yellowBrickRoad: return "Follow it to the Emerald City"
            case .emeraldCity: return "Everything is green behind the spectacles"
            case .poppyField: return "Do not fall asleep among the flowers"
            case .munchkinCountry: return "Where everything is blue"
            case .tinWoodman: return "He would like a heart"
            case .witchCastle: return "The Winkie Country, in the west"
            case .glinda: return "The Good Witch of the South"
            }
        }
    }

    // MARK: The demo app (`OzWM demo [theme]`)

    /// Runs the demo app: one window now, more on request, gone with the last one.
    static func runApp(firstTheme: Int) -> Never {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        controller.open(Theme(rawValue: firstTheme % Theme.allCases.count) ?? .kansas)
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { n in
            guard let message = n.object as? String else { return }
            if message == "quit" {
                NSApp.terminate(nil)
            } else if message.hasPrefix("open:"), let i = Int(message.dropFirst(5)) {
                controller.open(Theme(rawValue: i % Theme.allCases.count) ?? .kansas)
            }
        }
        app.run()
        exit(0)
    }

    private final class AppController: NSObject, NSApplicationDelegate {
        private var windows: [NSWindow] = []

        func open(_ theme: Theme) {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = theme.title
            w.isReleasedWhenClosed = false
            w.contentView = SceneView(theme: theme)
            w.center()
            windows.append(w)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }

    // MARK: Oz's side

    /// Opens demo windows from Oz: starts the demo app with the first, asks it for more.
    final class Launcher {
        private var process: Process?
        private var next = 0

        func openWindow() {
            let theme = next
            next += 1
            if let p = process, p.isRunning {
                DistributedNotificationCenter.default().postNotificationName(
                    Demo.notification, object: "open:\(theme)", userInfo: nil, deliverImmediately: true)
                return
            }
            guard let exe = Bundle.main.executablePath else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["demo", String(theme)]
            do {
                try p.run()
                process = p
                Log.info("demo app started")
            } catch {
                Log.info("demo app failed to start: \(error)")
            }
        }

        /// Closes every demo window (the demo app quits), also one an earlier Oz started.
        func closeAll() {
            DistributedNotificationCenter.default().postNotificationName(
                Demo.notification, object: "quit", userInfo: nil, deliverImmediately: true)
            process = nil
        }
    }
}

// MARK: Scenes

/// A theme's scene, drawn to fill the view at whatever size it has.
private final class SceneView: NSView {
    let theme: Demo.Theme

    init(theme: Demo.Theme) {
        self.theme = theme
        super.init(frame: .zero)
        // Redrawn at the new size during a resize, not stretched.
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        guard r.width > 1, r.height > 1 else { return }
        switch theme {
        case .kansas: kansas(r)
        case .yellowBrickRoad: road(r)
        case .emeraldCity: emeraldCity(r)
        case .poppyField: poppies(r)
        case .munchkinCountry: munchkins(r)
        case .tinWoodman: tinWoodman(r)
        case .witchCastle: castle(r)
        case .glinda: glinda(r)
        }
        caption(r)
    }

    // Helpers. Coordinates are fractions of the view (0,0 bottom left).

    private func p(_ r: NSRect, _ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
    }

    private func rect(_ r: NSRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: r.minX + x * r.width, y: r.minY + y * r.height, width: w * r.width, height: h * r.height)
    }

    private func sky(_ r: NSRect, _ top: NSColor, _ bottom: NSColor) {
        NSGradient(starting: bottom, ending: top)?.draw(in: r, angle: 90)
    }

    private func fill(_ color: NSColor, _ path: NSBezierPath) {
        color.setFill()
        path.fill()
    }

    private func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// The same "random" scatter every time for a theme (positions in 0...1).
    private func scatter(_ count: Int, seed: UInt64) -> [(CGFloat, CGFloat, CGFloat)] {
        var s = seed
        func next() -> CGFloat {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((s >> 33) & 0xFFFF) / 65535
        }
        return (0..<count).map { _ in (next(), next(), next()) }
    }

    /// A hill along the bottom: a wide ellipse rising to `height`.
    private func hill(_ r: NSRect, center: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
        fill(color, NSBezierPath(ovalIn: rect(r, center - width / 2, -height, width, height * 2)))
    }

    private func caption(_ r: NSRect) {
        let size = max(14, min(r.width, r.height) * 0.075)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowBlurRadius = size * 0.25
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.06)
        let title = NSAttributedString(string: theme.title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white, .shadow: shadow])
        let sub = NSAttributedString(string: theme.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.42, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.9), .shadow: shadow])
        let margin = size * 0.8
        sub.draw(at: NSPoint(x: r.minX + margin, y: r.minY + margin))
        title.draw(at: NSPoint(x: r.minX + margin, y: r.minY + margin + sub.size().height + size * 0.1))
    }

    // The scenes.

    private func kansas(_ r: NSRect) {
        sky(r, hex(0x8C95A0), hex(0xD9C7A3))
        // The cyclone.
        for i in 0..<14 {
            let t = CGFloat(i) / 13
            let w = 0.05 + 0.22 * t
            fill(hex(0x4A4E55, 0.22 + 0.03 * CGFloat(i)), NSBezierPath(ovalIn: rect(r, 0.24 - w / 2, 0.3 + 0.55 * t, w, 0.07)))
        }
        fill(hex(0xA88B5C), NSBezierPath(rect: rect(r, 0, 0, 1, 0.32)))
        fill(hex(0x8E7349), NSBezierPath(rect: rect(r, 0, 0, 1, 0.12)))
        // The farmhouse.
        fill(hex(0x6B5A44), NSBezierPath(rect: rect(r, 0.6, 0.3, 0.2, 0.17)))
        let roof = NSBezierPath()
        roof.move(to: p(r, 0.58, 0.47)); roof.line(to: p(r, 0.7, 0.6)); roof.line(to: p(r, 0.82, 0.47)); roof.close()
        fill(hex(0x4B3B2B), roof)
        fill(hex(0xE8D9A8), NSBezierPath(rect: rect(r, 0.66, 0.36, 0.035, 0.05)))
        fill(hex(0x3A2E22), NSBezierPath(rect: rect(r, 0.73, 0.3, 0.035, 0.09)))
    }

    private func road(_ r: NSRect) {
        sky(r, hex(0x5BA3E0), hex(0xBFE3F7))
        hill(r, center: 0.15, width: 0.9, height: 0.42, color: hex(0x5FAE4E))
        hill(r, center: 0.85, width: 0.9, height: 0.38, color: hex(0x4E9E43))
        fill(hex(0x6CC05A), NSBezierPath(rect: rect(r, 0, 0, 1, 0.3)))
        // The road narrows to the horizon; rows of bricks get thinner with it.
        let road = NSBezierPath()
        road.move(to: p(r, 0.2, 0)); road.line(to: p(r, 0.8, 0)); road.line(to: p(r, 0.52, 0.42)); road.line(to: p(r, 0.48, 0.42)); road.close()
        fill(hex(0xF2C230), road)
        NSGraphicsContext.saveGraphicsState()
        road.addClip()
        hex(0xC99A1A).setStroke()
        // Rows thin out towards the horizon; they never quite reach it, so stop when too thin.
        var y: CGFloat = 0, step: CGFloat = 0.075, row = 0
        while y < 0.42 && step * r.height > 1.5 {
            let line = NSBezierPath()
            line.move(to: p(r, 0, y)); line.line(to: p(r, 1, y))
            line.lineWidth = max(1, r.height * 0.004)
            line.stroke()
            // Joints between bricks, staggered row by row.
            let half = 0.3 * (1 - y / 0.42) + 0.02
            for k in 0..<8 {
                let x = 0.5 - half + (CGFloat(k) + (row % 2 == 0 ? 0.5 : 0)) * (2 * half / 8)
                let joint = NSBezierPath()
                joint.move(to: p(r, x, y)); joint.line(to: p(r, x, min(y + step, 0.42)))
                joint.lineWidth = max(1, r.height * 0.003)
                joint.stroke()
            }
            y += step
            step *= 0.82
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        // The city, far away.
        fill(hex(0x2E9E6A, 0.85), NSBezierPath(rect: rect(r, 0.47, 0.42, 0.06, 0.05)))
    }

    private func spire(_ r: NSRect, x: CGFloat, width: CGFloat, top: CGFloat, color: NSColor) {
        fill(color, NSBezierPath(rect: rect(r, x, 0.3, width, top - 0.3)))
        let cap = NSBezierPath()
        cap.move(to: p(r, x - width * 0.1, top)); cap.line(to: p(r, x + width / 2, top + width * 1.6)); cap.line(to: p(r, x + width * 1.1, top)); cap.close()
        fill(color.blended(withFraction: 0.25, of: .white) ?? color, cap)
    }

    private func emeraldCity(_ r: NSRect) {
        sky(r, hex(0x0F5C47), hex(0xA7F0C9))
        fill(hex(0xFFFFFF, 0.25), NSBezierPath(ovalIn: rect(r, 0.25, 0.25, 0.5, 0.55)))
        let towers: [(CGFloat, CGFloat, CGFloat, UInt32)] = [
            (0.3, 0.05, 0.55, 0x2BB673), (0.37, 0.06, 0.68, 0x1E9E60), (0.45, 0.1, 0.8, 0x15895A),
            (0.56, 0.06, 0.7, 0x1E9E60), (0.63, 0.05, 0.58, 0x2BB673), (0.22, 0.05, 0.45, 0x3CC783),
            (0.71, 0.05, 0.47, 0x3CC783)]
        for t in towers { spire(r, x: t.0, width: t.1, top: t.2, color: hex(t.3)) }
        fill(hex(0x0D6B45), NSBezierPath(rect: rect(r, 0.18, 0.3, 0.64, 0.06)))
        fill(hex(0x2E8B57), NSBezierPath(rect: rect(r, 0, 0, 1, 0.3)))
        let road = NSBezierPath()
        road.move(to: p(r, 0.42, 0)); road.line(to: p(r, 0.58, 0)); road.line(to: p(r, 0.51, 0.3)); road.line(to: p(r, 0.49, 0.3)); road.close()
        fill(hex(0xF2C230), road)
    }

    private func poppies(_ r: NSRect) {
        sky(r, hex(0x9CCBF0), hex(0xF5E6C8))
        hill(r, center: 0.5, width: 1.6, height: 0.55, color: hex(0x6DAF4A))
        let unit = min(r.width, r.height)
        for (x, y, s) in scatter(160, seed: 7) {
            // Under the hill's curve (an ellipse 1.6 wide, 0.55 high, centred).
            let dx = (x - 0.5) / 0.8
            let yy = y * 0.5 * (1 - dx * dx).squareRoot()
            let size = unit * (0.012 + 0.03 * (1 - yy / 0.5)) * (0.7 + 0.6 * s)
            let c = p(r, x, yy)
            hex(0x3E7A2C).setStroke()
            let stem = NSBezierPath()
            stem.move(to: c); stem.line(to: NSPoint(x: c.x, y: c.y - size * 1.4))
            stem.lineWidth = max(1, size * 0.15)
            stem.stroke()
            fill(hex(s > 0.5 ? 0xD7261E : 0xE8442D), NSBezierPath(ovalIn: NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)))
            fill(hex(0x2A1A12), NSBezierPath(ovalIn: NSRect(x: c.x - size * 0.12, y: c.y - size * 0.12, width: size * 0.24, height: size * 0.24)))
        }
    }

    private func munchkins(_ r: NSRect) {
        sky(r, hex(0x3D7FD6), hex(0xB9DAF7))
        hill(r, center: 0.5, width: 1.8, height: 0.4, color: hex(0x7CC36A))
        // Round blue houses with domed roofs.
        for (i, x) in [0.12, 0.38, 0.64, 0.86].enumerated() {
            let w: CGFloat = 0.14 - CGFloat(i % 2) * 0.03
            fill(hex(0x2E5FB3), NSBezierPath(rect: rect(r, x - w / 2, 0.22, w, 0.14)))
            fill(hex(0x1D3F80), NSBezierPath(ovalIn: rect(r, x - w * 0.6, 0.29, w * 1.2, 0.16)))
            fill(hex(0xF5E7B0), NSBezierPath(ovalIn: rect(r, x - 0.015, 0.22, 0.03, 0.07)))
        }
        let unit = min(r.width, r.height)
        for (x, y, s) in scatter(70, seed: 11) {
            let size = unit * (0.01 + 0.012 * s)
            let c = p(r, x, y * 0.2)
            fill(hex(s > 0.5 ? 0xFFD54A : 0xFFFFFF), NSBezierPath(ovalIn: NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)))
        }
    }

    private func heart(_ r: NSRect, center: NSPoint, size: CGFloat) -> NSBezierPath {
        let h = NSBezierPath()
        h.move(to: NSPoint(x: center.x, y: center.y - size * 0.55))
        h.curve(to: NSPoint(x: center.x - size * 0.5, y: center.y + size * 0.15),
                controlPoint1: NSPoint(x: center.x - size * 0.2, y: center.y - size * 0.3),
                controlPoint2: NSPoint(x: center.x - size * 0.5, y: center.y - size * 0.1))
        h.curve(to: NSPoint(x: center.x, y: center.y + size * 0.3),
                controlPoint1: NSPoint(x: center.x - size * 0.5, y: center.y + size * 0.45),
                controlPoint2: NSPoint(x: center.x - size * 0.1, y: center.y + size * 0.5))
        h.curve(to: NSPoint(x: center.x + size * 0.5, y: center.y + size * 0.15),
                controlPoint1: NSPoint(x: center.x + size * 0.1, y: center.y + size * 0.5),
                controlPoint2: NSPoint(x: center.x + size * 0.5, y: center.y + size * 0.45))
        h.curve(to: NSPoint(x: center.x, y: center.y - size * 0.55),
                controlPoint1: NSPoint(x: center.x + size * 0.5, y: center.y - size * 0.1),
                controlPoint2: NSPoint(x: center.x + size * 0.2, y: center.y - size * 0.3))
        h.close()
        return h
    }

    private func tinWoodman(_ r: NSRect) {
        NSGradient(colors: [hex(0x5E6670), hex(0xC9D0D8), hex(0x7C858F), hex(0xB4BCC6)])?.draw(in: r, angle: 35)
        // Rivets along the edges of a plate.
        let plate = rect(r, 0.08, 0.12, 0.84, 0.76)
        hex(0x4A5059, 0.6).setStroke()
        let border = NSBezierPath(roundedRect: plate, xRadius: min(r.width, r.height) * 0.03, yRadius: min(r.width, r.height) * 0.03)
        border.lineWidth = max(2, min(r.width, r.height) * 0.008)
        border.stroke()
        let unit = min(r.width, r.height)
        for i in 0..<12 {
            for (x, y) in [(CGFloat(i) / 11, CGFloat(0)), (CGFloat(i) / 11, CGFloat(1))] {
                let c = NSPoint(x: plate.minX + x * plate.width, y: plate.minY + y * plate.height)
                let d = unit * 0.018
                fill(hex(0x8E969F), NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)))
            }
        }
        let center = p(r, 0.62, 0.55)
        let size = unit * 0.42
        fill(hex(0x000000, 0.18), heart(r, center: NSPoint(x: center.x + size * 0.03, y: center.y - size * 0.04), size: size))
        fill(hex(0xC8102E), heart(r, center: center, size: size))
        fill(hex(0xFFFFFF, 0.25), NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.32, y: center.y + size * 0.05, width: size * 0.18, height: size * 0.12)))
    }

    private func castle(_ r: NSRect) {
        sky(r, hex(0x1B1030), hex(0x5B3A7A))
        let unit = min(r.width, r.height)
        for (x, y, s) in scatter(60, seed: 3) {
            let d = unit * 0.004 * (1 + s)
            fill(hex(0xFFFFFF, 0.7), NSBezierPath(ovalIn: NSRect(x: r.minX + x * r.width, y: r.minY + (0.55 + y * 0.45) * r.height, width: d, height: d)))
        }
        let moon = unit * 0.2
        fill(hex(0xF4EFC8), NSBezierPath(ovalIn: NSRect(x: p(r, 0.78, 0.7).x - moon / 2, y: p(r, 0.78, 0.7).y - moon / 2, width: moon, height: moon)))
        hill(r, center: 0.35, width: 1.1, height: 0.38, color: hex(0x120A1F))
        let keep = NSBezierPath(rect: rect(r, 0.26, 0.3, 0.18, 0.3))
        keep.append(NSBezierPath(rect: rect(r, 0.2, 0.3, 0.05, 0.4)))
        keep.append(NSBezierPath(rect: rect(r, 0.45, 0.3, 0.05, 0.36)))
        for i in 0..<5 { keep.append(NSBezierPath(rect: rect(r, 0.26 + CGFloat(i) * 0.04, 0.6, 0.022, 0.03))) }
        for (x, top) in [(0.2, 0.7), (0.45, 0.66)] as [(CGFloat, CGFloat)] {
            let cap = NSBezierPath()
            cap.move(to: p(r, x - 0.01, top)); cap.line(to: p(r, x + 0.025, top + 0.1)); cap.line(to: p(r, x + 0.06, top)); cap.close()
            keep.append(cap)
        }
        fill(hex(0x08040F), keep)
        fill(hex(0xF2C230, 0.9), NSBezierPath(rect: rect(r, 0.33, 0.45, 0.02, 0.04)))
    }

    private func glinda(_ r: NSRect) {
        sky(r, hex(0xF7B5D6), hex(0xE9E1FF))
        hill(r, center: 0.5, width: 1.7, height: 0.3, color: hex(0xC9E8B9))
        let unit = min(r.width, r.height)
        for (x, y, s) in scatter(26, seed: 5) {
            let d = unit * (0.05 + 0.16 * s)
            let b = NSRect(x: r.minX + x * r.width - d / 2, y: r.minY + (0.25 + y * 0.7) * r.height - d / 2, width: d, height: d)
            fill(hex(0xFFFFFF, 0.18), NSBezierPath(ovalIn: b))
            hex(0xFFFFFF, 0.75).setStroke()
            let ring = NSBezierPath(ovalIn: b)
            ring.lineWidth = max(1, d * 0.025)
            ring.stroke()
            fill(hex(0xFFFFFF, 0.8), NSBezierPath(ovalIn: NSRect(x: b.minX + d * 0.2, y: b.maxY - d * 0.35, width: d * 0.16, height: d * 0.1)))
        }
    }
}
