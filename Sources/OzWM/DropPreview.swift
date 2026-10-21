import Cocoa

/// While a window is dragged, shows where it will land when let go: a pane of Liquid Glass
/// (frosted glass before macOS 26) over the slot it will take, just below the dragged window.
final class DropPreview {
    private let window: NSPanel
    /// Shown frame, AX coordinates.
    private var shown: CGRect?
    private var below: CGWindowID?

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone, .transient]
        window.alphaValue = 0

        let radius: CGFloat = 16
        let content: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            glass.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.12)
            content = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 1
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            content = blur
        }
        window.contentView = content
    }

    /// Shows (or moves) the preview over `frame` (AX coordinates), ordered just below the
    /// window being dragged so that one stays on top.
    func show(_ frame: CGRect, below id: CGWindowID) {
        let ns = NSRect(x: frame.minX, y: Geometry.primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        if shown == nil {
            window.setFrame(ns, display: true)
            window.order(.below, relativeTo: Int(id))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 1
            }
        } else if shown != frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(ns, display: true)
            }
        }
        if below != id {
            window.order(.below, relativeTo: Int(id))
            below = id
        }
        shown = frame
    }

    func hide() {
        guard shown != nil else { return }
        shown = nil
        below = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.shown == nil else { return }  // shown again meanwhile
            self.window.orderOut(nil)
            // A region-sized pane of glass keeps a backing store that size: let it go.
            self.window.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
        })
    }
}

/// Inside the Oz zone the landing place is a split line: between two rows (horizontal) or
/// beside a window in its row (vertical). A glowing accent-coloured bar, above the windows.
final class InsertionLine {
    private let window: NSPanel
    private let bar = CALayer()
    private var shown: CGRect?

    static let thickness: CGFloat = 6

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone, .transient]
        window.alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        bar.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.cornerRadius = InsertionLine.thickness / 2
        bar.shadowColor = NSColor.controlAccentColor.cgColor
        bar.shadowOpacity = 0.9
        bar.shadowRadius = 6
        bar.shadowOffset = .zero
        bar.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        view.layer?.addSublayer(bar)
        window.contentView = view
    }

    /// `frame`: the bar, AX coordinates. The window is a little larger so the glow isn't cut.
    /// Moves and appears at once: a line that slides lags behind the cursor.
    func show(_ frame: CGRect) {
        guard shown != frame else { return }
        let pad: CGFloat = 10
        let ns = NSRect(x: frame.minX - pad, y: Geometry.primaryHeight - frame.maxY - pad,
                        width: frame.width + 2 * pad, height: frame.height + 2 * pad)
        window.setFrame(ns, display: false)
        bar.frame = CGRect(x: pad, y: pad, width: frame.width, height: frame.height)
        if shown == nil {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
        shown = frame
    }

    func hide() {
        guard shown != nil else { return }
        shown = nil
        window.orderOut(nil)
    }
}

/// Where the view is in the strip: a thin rounded bar along the zone's right edge, sized like
/// the visible part of the strip and placed like it. Shown while the strip moves, faded out a
/// moment after it stops (like macOS's overlay scrollers).
final class ScrollIndicator {
    private let window: NSPanel
    private var visible = false
    private var hideWork: DispatchWorkItem?

    static let width: CGFloat = 5

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone, .transient]
        window.alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        // Grey reads on light and dark content alike; the thin light rim separates it from both.
        view.layer?.backgroundColor = NSColor(white: 0.45, alpha: 0.65).cgColor
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        view.layer?.borderWidth = 0.5
        view.layer?.cornerRadius = ScrollIndicator.width / 2
        window.contentView = view
    }

    /// Shows the bar at `frame` (AX coordinates) and fades it out once it hasn't moved for a bit.
    func show(_ frame: CGRect) {
        window.setFrame(NSRect(x: frame.minX, y: Geometry.primaryHeight - frame.maxY, width: frame.width, height: frame.height),
                        display: false)
        if !visible {
            visible = true
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                window.animator().alphaValue = 1
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visible else { return }
            self.window.orderOut(nil)
        })
    }
}
