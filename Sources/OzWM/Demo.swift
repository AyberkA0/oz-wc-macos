import Cocoa

/// Demo mode: stand-in app windows to show Oz off with, themed on L. Frank Baum's
/// "The Wonderful Wizard of Oz" (1900). Each is a real window of a little app of its own
/// (`OzWM demo`, so Oz tiles it like any other): a plain background with the theme's name,
/// laid out for the window's size, again whenever it changes.
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

// MARK: The window's content

/// A theme's window: a plain background in GitHub's colours (light or dark, as the system
/// is) with the theme's title and subtitle, laid out for the window's size.
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        guard r.width > 1, r.height > 1 else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // GitHub's canvas and text colours.
        hex(dark ? 0x0D1117 : 0xFFFFFF).setFill()
        r.fill()
        let size = max(14, min(r.width, r.height) * 0.075)
        let title = NSAttributedString(string: theme.title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: hex(dark ? 0xF0F6FC : 0x1F2328)])
        let sub = NSAttributedString(string: theme.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.42, weight: .medium),
            .foregroundColor: hex(dark ? 0x9198A1 : 0x59636E)])
        let margin = size * 0.8
        sub.draw(at: NSPoint(x: r.minX + margin, y: r.minY + margin))
        title.draw(at: NSPoint(x: r.minX + margin, y: r.minY + margin + sub.size().height + size * 0.1))
    }
}
