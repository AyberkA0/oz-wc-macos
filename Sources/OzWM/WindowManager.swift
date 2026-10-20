import Cocoa
import OzCore
import QuartzCore

struct StripKey: Hashable {
    let space: SpaceID
    let display: CGDirectDisplayID
}

final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String?
    /// Last frame we applied (AX coordinates).
    var lastFrame: CGRect?
    var parked = false
    var shrunk = false
    /// Its size was changed since the last settle (the app may have refused it).
    var needsSizeCheck = false
    var savedHeight: CGFloat?
    var frameCheck: DispatchWorkItem?

    /// Title as of when the window was found (read off the main thread; used for rules/events).
    var title: String

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, appName: String, bundleID: String?, title: String = "") {
        self.title = title
        self.id = id
        self.element = element
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
    }

}

/// What Oz needs to know about a window, gathered from its app in one go so it can be
/// done off the main thread (each AX read is a round trip to the app, which may be busy).
struct WindowProbe {
    let element: AXUIElement
    let pid: pid_t
    let id: CGWindowID
    let frame: CGRect?
    /// A standard, visible (not minimized / not fullscreen) window.
    let manageable: Bool
    let resizable: Bool
    let title: String

    static func read(_ el: AXUIElement, pid: pid_t) -> WindowProbe? {
        guard let wid = AX.windowID(el) else { return nil }
        let manageable = AX.string(el, kAXRoleAttribute) == kAXWindowRole
            && AX.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole
            && AX.bool(el, kAXMinimizedAttribute) != true
            && AX.bool(el, "AXFullScreen") != true
        let resizable = manageable && AX.isSettable(el, kAXSizeAttribute) && AX.isSettable(el, kAXPositionAttribute)
        return WindowProbe(element: el, pid: pid, id: wid, frame: AX.frame(el), manageable: manageable,
                           resizable: resizable, title: manageable ? AX.string(el, kAXTitleAttribute) ?? "" : "")
    }

    static func readApp(_ pid: pid_t) -> [WindowProbe] {
        AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute).compactMap { read($0, pid: pid) }
    }

    /// All apps, in parallel.
    static func readApps(_ pids: [pid_t]) -> [WindowProbe] {
        let lock = NSLock()
        var out: [WindowProbe] = []
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let probes = readApp(pids[i])
            lock.lock()
            out += probes
            lock.unlock()
        }
        return out
    }
}

struct RuleResult {
    var float = false
    var ignore = false
    var height: CGFloat?
}

enum Command: String, CaseIterable {
    case focusUp, focusDown, focusLeft, focusRight, focusFirst, focusLast, focusRow
    case moveUp, moveDown, moveLeft, moveRight, moveFirst, moveLast
    case slurpIn, barfOut, joinUp, joinDown
    case cycleHeight, cycleHeightBack, setHeight, toggleFullHeight, resizeHeight
    case cycleWidth, cycleWidthBack, setWidth, resizeWidth, equalizeRow
    case center, alignTop, scrollUp, scrollDown, scrollBy, scrollToTop, scrollToBottom
    case toggleFloat, closeWindow, moveToNextScreen
    case retile, toggleTiling, reloadConfig
    case missionControl, appExpose, showDesktop, launchpad
}

final class WindowManager {
    var settings = Settings()
    private(set) var enabled = true

    /// Hooks wired up by the app delegate / config engine.
    var rulesProvider: ((ManagedWindow) -> RuleResult)?
    var emit: ((String, [String: Any]) -> Void)?
    var reloadConfig: (() -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?

    private var strips: [StripKey: Strip] = [:]
    private var windows: [CGWindowID: ManagedWindow] = [:]
    private var floating: [CGWindowID: ManagedWindow] = [:]
    private var observers: [pid_t: AppObserver] = [:]
    private var minHeights: [CGWindowID: CGFloat] = [:]
    let snapshots = SnapshotCache()
    private let overlays = OverlayManager()
    /// Windows waiting for their stand-in to reach the screen before being moved away.
    private var pendingParks: [CGWindowID: DispatchWorkItem] = [:]

    private struct GestureState { let key: StripKey; let strip: Strip; let screen: NSScreen }
    private var gesture: GestureState?

    /// The window the user is resizing with the mouse right now; its neighbours reflow live.
    private var liveResize: (id: CGWindowID, key: StripKey)?
    private var liveReadInFlight = false
    /// New windows sent straight to their final frame; the layout leaves them alone while
    /// the rest of the strip animates around them.
    private var pinned = Set<CGWindowID>()
    /// Window to focus once its strip's scroll animation ends. Activating makes the app
    /// redraw in its focused look, and while it does it answers moves 50-70 ms late
    /// (measured), so focusing mid-glide made that window trail behind and then jump.
    private var pendingActivation: [StripKey: CGWindowID] = [:]
    /// Windows of slow apps drawn by a stand-in while the strip moves (real one parked).
    private var proxied = Set<CGWindowID>()
    /// Last focused window as reported by AX notifications (avoids asking the app).
    private var trackedFocus: CGWindowID?
    private var liveReadAgain = false

    private struct Animation {
        let strip: Strip
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: Double
    }
    private var animations: [StripKey: Animation] = [:]
    /// Strips whose layout must be re-applied on the next display frame.
    private var dirty = Set<StripKey>()
    private let driver = FrameDriver()
    let writer = AXWriter()

    private enum AddMode { case scan, created }

    // MARK: Lifecycle

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appLaunched(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appTerminated(app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the window server a moment to settle the new Space.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.spaceChanged()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.screensChanged() }
        }
        driver.onFrame = { [weak self] in self?.frame() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async { self?.endLiveResize() }
        }
        writer.onMinHeight = { [weak self] id, h in
            // The app refused to get that small at the top edge: remember it, re-evaluate.
            guard let self else { return }
            self.minHeights[id] = h
            if let (key, _) = self.locate(id) { self.markDirty(key) }
        }
        if settings.topOverflow == .slide { snapshots.requestPermissionOnce() }
        overlays.live = settings.livePeek
        overlays.liveFPS = settings.livePeekFPS
        setupSnapshots()
        scanAll(initial: true)
    }

    /// Put every hidden/shrunk window back on screen (on quit or when tiling is turned off).
    func restoreAll() {
        overlays.hideAll()
        animations.removeAll()
        dirty.removeAll()
        driver.pause()
        // Let queued moves land first, or they would undo the restore.
        writer.waitUntilIdle()
        var offset: CGFloat = 0
        for (key, strip) in strips {
            guard let screen = Geometry.screen(displayID: key.display) ?? NSScreen.main else { continue }
            let vp = viewport(screen)
            for row in strip.rows {
                for id in row.windows {
                    guard let w = windows[id], w.parked || w.shrunk else { continue }
                    let h = min(row.height, vp.height - offset)
                    let r = CGRect(x: vp.minX + offset, y: vp.minY + offset, width: vp.width - offset, height: max(h, 200))
                    AX.setPosition(w.element, r.origin)
                    AX.setSize(w.element, r.size)
                    offset = (offset + 28).truncatingRemainder(dividingBy: 280)
                }
            }
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        if on {
            enabled = true
            scanAll(initial: true)
        } else {
            restoreAll()
            enabled = false
            strips.removeAll()
            windows.removeAll()
            floating.removeAll()
            minHeights.removeAll()
            gesture = nil
        }
        onEnabledChanged?(enabled)
    }

    func settingsChanged() {
        if settings.topOverflow == .slide { snapshots.requestPermissionOnce() }
        overlays.hideAll()
        overlays.live = settings.livePeek
        overlays.liveFPS = settings.livePeekFPS
        for w in windows.values { w.lastFrame = nil; w.parked = false }
        layoutVisible(animated: false)
    }

    // MARK: Discovery

    private func managedApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
    }

    private func ensureObserver(_ pid: pid_t) {
        guard observers[pid] == nil, let o = AppObserver(pid: pid) else { return }
        // Chromium/Electron animate every AX move while this is on, which makes scrolling sluggish.
        if AX.bool(o.app, "AXEnhancedUserInterface") == true {
            AX.set(o.app, "AXEnhancedUserInterface", kCFBooleanFalse)
        }
        o.handler = { [weak self] name, element, pid in
            self?.handle(notification: name, element: element, pid: pid)
        }
        observers[pid] = o
    }

    /// Finds all windows. At startup this blocks (nothing to keep smooth yet); on later
    /// rescans (Space switches) the reading happens in the background.
    func scanAll(initial: Bool) {
        guard enabled else { return }
        let apps = managedApps()
        apps.forEach { ensureObserver($0.processIdentifier) }
        let pids = apps.filter { !$0.isHidden }.map(\.processIdentifier)
        if initial {
            finishScan(WindowProbe.readApps(pids), initial: true)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let probes = WindowProbe.readApps(pids)
                DispatchQueue.main.async { self?.finishScan(probes, initial: false) }
            }
        }
    }

    private func finishScan(_ probes: [WindowProbe], initial: Bool) {
        guard enabled else { return }
        let found = probes.sorted { a, b in
            let fa = a.frame ?? .zero, fb = b.frame ?? .zero
            return fa.minY != fb.minY ? fa.minY < fb.minY : fa.minX < fb.minX
        }
        let alive = Set(found.map(\.id))
        for id in Array(windows.keys) where !alive.contains(id) && !windowExists(id) {
            unmanage(id, focusNeighbor: false)
        }
        for id in Array(floating.keys) where !alive.contains(id) && !windowExists(id) {
            floating.removeValue(forKey: id)
        }
        for p in found {
            if windows[p.id] != nil {
                if !p.manageable {
                    unmanage(p.id, focusNeighbor: false)
                } else {
                    reassignSpaceIfNeeded(p.id)
                }
            } else if floating[p.id] == nil && (initial || windowExists(p.id)) {
                add(p, mode: .scan)
            }
        }

        if initial, let fid = systemFocusedWindowID(), let (_, strip) = locate(fid) {
            strip.focused = fid
        }
        for (key, strip) in strips where isVisible(key) {
            if let f = strip.focused, let screen = Geometry.screen(displayID: key.display) {
                let vh = viewport(screen).height
                strip.scrollY = strip.clampScroll(strip.scrollToReveal(f, viewportHeight: vh, gap: settings.gap),
                                                  viewportHeight: vh, gap: settings.gap)
            }
        }
        layoutVisible(animated: false)
        Log.info("scan: \(windows.count) tiled, \(floating.count) floating, \(strips.count) strip(s)")
    }

    /// Reads one app's windows on its queue and adds the new ones.
    private func scanApp(_ pid: pid_t, mode: AddMode) {
        guard enabled else { return }
        ensureObserver(pid)
        writer.perform(pid: pid) { [weak self] in
            let probes = WindowProbe.readApp(pid)
            DispatchQueue.main.async {
                guard let self else { return }
                probes.forEach { self.add($0, mode: mode) }
                if mode == .scan { self.layoutVisible(animated: false) }
            }
        }
    }

    /// Adds a window the app just reported (created / deminiaturized).
    private func addWindow(_ el: AXUIElement, pid: pid_t, mode: AddMode) {
        guard enabled else { return }
        writer.perform(pid: pid) { [weak self] in
            guard let probe = WindowProbe.read(el, pid: pid) else { return }
            DispatchQueue.main.async { self?.add(probe, mode: mode) }
        }
    }

    private func windowExists(_ id: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return !info.isEmpty
    }

    private func add(_ probe: WindowProbe, mode: AddMode) {
        let wid = probe.id, pid = probe.pid, el = probe.element
        guard enabled, pid != getpid(), windows[wid] == nil, floating[wid] == nil, probe.manageable else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.isHidden == true { return }
        let w = ManagedWindow(id: wid, element: el, pid: pid, appName: app?.localizedName ?? "?",
                              bundleID: app?.bundleIdentifier, title: probe.title)
        let rule = rulesProvider?(w) ?? RuleResult()
        if rule.ignore { return }
        ensureObserver(pid)
        observers[pid]?.watch(window: el)

        if rule.float || !probe.resizable {
            floating[wid] = w
            emit?("windowCreated", info(w))
            return
        }

        let frame = probe.frame
        let screen = frame.map { Geometry.screen(containingAX: CGPoint(x: $0.midX, y: $0.midY)) }
            ?? Geometry.screenUnderMouse()
        guard let screen else { return }
        let space = Spaces.space(of: wid) ?? Spaces.current(on: screen)
        if Spaces.isFullscreen(space) { return }
        let key = StripKey(space: space, display: Geometry.displayID(screen))
        let strip = self.strip(key)
        let vh = viewport(screen).height

        let height: CGFloat
        if let r = rule.height {
            height = Strip.height(forRatio: r, viewportHeight: vh, gap: settings.gap)
        } else if mode == .scan && settings.keepInitialHeights, let f = frame {
            height = min(max(f.height, 120), vh).rounded()
        } else {
            height = Strip.height(forRatio: settings.defaultHeight, viewportHeight: vh, gap: settings.gap)
        }

        windows[wid] = w
        let position: InsertPosition = mode == .scan ? .end : settings.newWindowPosition
        strip.insert(wid, height: height, anchor: strip.focused, position: position)
        Log.debug("add \(wid) \(w.appName) '\(w.title)' -> space \(space) rows=\(strip.rows.count)")

        if mode == .created || strip.focused == nil {
            strip.focused = wid
        }
        if mode == .created {
            strip.scrollY = strip.scrollToReveal(wid, viewportHeight: vh, gap: settings.gap)
            // Move the new window once, straight to where it will end up, instead of letting it
            // ride the scroll animation (it would first be parked off screen, then slide in).
            if visibleScreen(key) != nil, abs(strip.renderScrollY - strip.scrollY) > 1,
               let item = strip.layout(params(screen), scroll: strip.scrollY, minHeights: minHeights)
                .first(where: { $0.id == wid }), case .frame(let r) = item.placement {
                writer.move(wid, pid: pid, element: el, to: r, setSize: true)
                w.lastFrame = r
                w.needsSizeCheck = true
                pinned.insert(wid)
                // Start moving the neighbours only once the app has actually moved the new
                // window (Finder takes ~60 ms); otherwise they clear the space first and the
                // desktop shows through for a frame or two.
                writer.perform(pid: pid) { [weak self] in
                    DispatchQueue.main.async { self?.relayout(key, animated: true) }
                }
            } else {
                relayout(key, animated: true)
            }
            emit?("windowCreated", info(w))
        }
    }

    private func unmanage(_ id: CGWindowID, focusNeighbor: Bool) {
        pinned.remove(id)
        proxied.remove(id)
        pendingParks.removeValue(forKey: id)?.cancel()
        overlays.remove(id)
        snapshots.remove(id)
        floating.removeValue(forKey: id)
        minHeights.removeValue(forKey: id)
        guard let w = windows.removeValue(forKey: id) else { return }
        w.frameCheck?.cancel()
        guard let (key, strip) = locate(id) else { return }
        let wasFocused = strip.focused == id
        let neighbor = strip.remove(id)
        if let screen = visibleScreen(key) {
            let vh = viewport(screen).height
            strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: vh, gap: settings.gap)
            if let n = strip.focused {
                strip.scrollY = strip.scrollToReveal(n, viewportHeight: vh, gap: settings.gap)
            }
            relayout(key, animated: true)
            if focusNeighbor && wasFocused, let n = neighbor {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.focus(n)
                }
            }
        }
        if strip.isEmpty { strips.removeValue(forKey: key) }
    }

    private func reassignSpaceIfNeeded(_ id: CGWindowID) {
        guard let (key, strip) = locate(id), let space = Spaces.space(of: id), space != key.space else { return }
        strip.remove(id)
        if strip.isEmpty { strips.removeValue(forKey: key) }
        let target = self.strip(StripKey(space: space, display: key.display))
        let h = Strip.height(forRatio: settings.defaultHeight,
                             viewportHeight: viewport(Geometry.screen(displayID: key.display) ?? NSScreen.main!).height,
                             gap: settings.gap)
        target.insert(id, height: h, anchor: target.focused, position: .end)
        windows[id]?.lastFrame = nil
    }

    // MARK: Events

    private func handle(notification: String, element: AXUIElement, pid: pid_t) {
        guard enabled else { return }
        switch notification {
        case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification:
            // Probed on the app's queue, so it already waits for the app to answer.
            addWindow(element, pid: pid, mode: .created)
        case kAXFocusedWindowChangedNotification:
            focusChanged(element)
        case kAXUIElementDestroyedNotification:
            if let w = find(element, pid: pid) { unmanage(w.id, focusNeighbor: true) }
        case kAXWindowMiniaturizedNotification:
            if let w = find(element, pid: pid) { unmanage(w.id, focusNeighbor: true) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // While scrolling these are our own moves, dozens per second: skip the lookup.
            guard !isMoving, let w = find(element, pid: pid), windows[w.id] != nil else { return }
            if notification == kAXWindowResizedNotification && NSEvent.pressedMouseButtons & 1 != 0 {
                trackLiveResize(w)
            }
            scheduleFrameCheck(w)
        case kAXApplicationHiddenNotification:
            for w in windows.values where w.pid == pid { unmanage(w.id, focusNeighbor: false) }
        case kAXApplicationShownNotification:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.scanApp(pid, mode: .scan)
            }
        default:
            break
        }
    }

    private func find(_ el: AXUIElement, pid: pid_t, askApp: Bool = true) -> ManagedWindow? {
        // CFEqual is a local comparison; asking the app for the window id is a round trip.
        if let w = windows.values.first(where: { $0.pid == pid && CFEqual($0.element, el) })
            ?? floating.values.first(where: { $0.pid == pid && CFEqual($0.element, el) }) {
            return w
        }
        if askApp, let wid = AX.windowID(el) { return windows[wid] ?? floating[wid] }
        return nil
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard enabled, app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        ensureObserver(pid)
        // The first window often exists before our observer is registered.
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scanApp(pid, mode: .created)
            }
        }
    }

    private func appTerminated(_ pid: pid_t) {
        observers.removeValue(forKey: pid)
        writer.forget(pid: pid)
        for w in windows.values where w.pid == pid { unmanage(w.id, focusNeighbor: false) }
        for w in floating.values where w.pid == pid { floating.removeValue(forKey: w.id) }
    }

    private func appActivated(_ pid: pid_t) {
        guard enabled else { return }
        writer.perform(pid: pid) { [weak self] in
            guard let el = AX.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return }
            DispatchQueue.main.async { self?.focusChanged(el) }
        }
    }

    private func focusChanged(_ el: AXUIElement) {
        // No round trip to the app here (a busy app stalled this for 200 ms): a window we
        // don't recognise by element is one we don't manage yet anyway.
        guard enabled, let pid = AX.pid(el), let w = find(el, pid: pid, askApp: false) else { return }
        trackedFocus = w.id
        guard gesture == nil, windows[w.id] != nil, let (key, strip) = locate(w.id) else { return }
        let wid = w.id
        strip.focused = wid
        if let screen = visibleScreen(key) {
            let vh = viewport(screen).height
            let target = strip.scrollToReveal(wid, viewportHeight: vh, gap: settings.gap)
            if abs(target - strip.scrollY) > 0.5 {
                strip.scrollY = target
                relayout(key, animated: true)
            }
        }
        emit?("windowFocused", info(w))
    }

    private func spaceChanged() {
        guard enabled else { return }
        // Animations target the old Space's windows; finish them instantly.
        for (_, a) in animations { a.strip.renderScrollY = a.to }
        animations.removeAll()
        dirty.removeAll()
        // Keep the peeks on screen (they live on their own Space); just stop streaming.
        overlays.pauseMirrors()
        gesture = nil
        scanAll(initial: false)
        emit?("spaceChanged", [:])
    }

    private func screensChanged() {
        guard enabled else { return }
        let live = Set(NSScreen.screens.map(Geometry.displayID))
        for (key, strip) in strips where !live.contains(key.display) {
            guard let main = NSScreen.main ?? NSScreen.screens.first else { break }
            let target = self.strip(StripKey(space: Spaces.current(on: main), display: Geometry.displayID(main)))
            for row in strip.rows { target.rows.append(row) }
            strips.removeValue(forKey: key)
        }
        for w in windows.values { w.lastFrame = nil; w.parked = false }
        layoutVisible(animated: false)
    }

    private func scheduleFrameCheck(_ w: ManagedWindow) {
        w.frameCheck?.cancel()
        let item = DispatchWorkItem { [weak self, weak w] in
            guard let self, let w else { return }
            self.checkFrame(w)
        }
        w.frameCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Reacts to the user resizing or dragging a tiled window.
    private func checkFrame(_ w: ManagedWindow) {
        guard enabled, windows[w.id] === w, !w.parked else { return }
        if isMoving || liveResize != nil || NSEvent.pressedMouseButtons != 0 || writer.hasPending(pid: w.pid) {
            scheduleFrameCheck(w)
            return
        }
        let element = w.element
        writer.perform(pid: w.pid) { [weak self, weak w] in
            let actual = AX.frame(element)
            DispatchQueue.main.async {
                guard let self, let w, let actual else { return }
                self.compareFrame(w, actual)
            }
        }
    }

    private func compareFrame(_ w: ManagedWindow, _ actual: CGRect) {
        guard enabled, !isMoving, windows[w.id] === w, !w.parked, let expected = w.lastFrame else { return }
        let moved = abs(actual.minX - expected.minX) > 3 || abs(actual.minY - expected.minY) > 3
        let resizedH = abs(actual.height - expected.height) > 3
        let resizedW = abs(actual.width - expected.width) > 3
        guard let (key, strip) = locate(w.id), let (r, _) = strip.locate(w.id),
              let screen = Geometry.screen(displayID: key.display) else { return }
        let vh = viewport(screen).height
        if resizedW && !moved && !resizedH {
            // Width changed without the live path (a quick drag): same rules as live resizing.
            let rowWidth = viewport(screen).width * settings.width
            if strip.rows[r].windows.count > 1 {
                strip.setWidthFraction(w.id, actual.width / (rowWidth - settings.gap * CGFloat(strip.rows[r].windows.count - 1)))
            } else {
                strip.setLoneWidth(w.id, actual.width / rowWidth)
                strip.packRow(containing: w.id)
            }
            w.lastFrame = nil
            relayout(key, animated: true)
            return
        }
        guard moved || resizedH else {
            w.lastFrame = actual
            return
        }

        if resizedH && !w.shrunk {
            strip.rows[r].height = min(max(actual.height, 60), vh).rounded()
            Log.debug("adopt height \(actual.height) for \(w.id)")
        } else if moved {
            let c = CGPoint(x: actual.midX, y: actual.midY)
            if let target = Geometry.screen(containingAX: c), Geometry.displayID(target) != key.display {
                strip.remove(w.id)
                if strip.isEmpty { strips.removeValue(forKey: key) }
                let tkey = StripKey(space: Spaces.current(on: target), display: Geometry.displayID(target))
                let ts = self.strip(tkey)
                ts.insert(w.id, height: min(strip.rows.indices.contains(r) ? strip.rows[r].height : actual.height,
                                            viewport(target).height),
                          anchor: ts.focused, position: .below)
                ts.focused = w.id
                w.lastFrame = nil
                ts.scrollY = ts.scrollToReveal(w.id, viewportHeight: viewport(target).height, gap: settings.gap)
                relayout(tkey, animated: true)
            }
        }
        w.lastFrame = nil
        relayout(key, animated: false)
    }

    // MARK: Live resize

    /// The user is dragging an edge of `w`: read its frame (on the app's queue, so it comes
    /// after our own moves) and reflow everything else around it, at most once per read.
    private func trackLiveResize(_ w: ManagedWindow) {
        if let lr = liveResize, lr.id != w.id { return }
        guard !w.parked, !overlays.isShowing(w.id) else {
            Log.debug("live resize \(w.id) skipped: parked=\(w.parked) overlay=\(overlays.isShowing(w.id))")
            return
        }
        if liveReadInFlight {
            liveReadAgain = true
            return
        }
        liveReadInFlight = true
        let id = w.id
        let element = w.element
        writer.perform(pid: w.pid) { [weak self] in
            let frame = AX.frame(element)
            DispatchQueue.main.async { self?.liveResizeRead(id, frame) }
        }
    }

    private func liveResizeRead(_ id: CGWindowID, _ frame: CGRect?) {
        liveReadInFlight = false
        defer {
            if liveReadAgain, let w = windows[id] {
                liveReadAgain = false
                trackLiveResize(w)
            }
        }
        guard let f = frame, let w = windows[id], let (key, strip) = locate(id), let (r, _) = strip.locate(id),
              let screen = visibleScreen(key) else { return }
        if liveResize == nil {
            // A frame equal to what we set is just one of our own moves landing.
            guard let expected = w.lastFrame, !f.approxEqual(expected, tolerance: 2),
                  NSEvent.pressedMouseButtons & 1 != 0 else { return }
            liveResize = (id, key)
            Log.debug("live resize \(id) \(w.appName)")
        }
        let vp = viewport(screen)
        let row = strip.rows[r]
        row.height = min(max(f.height, 60), vp.height).rounded()
        w.savedHeight = nil
        let rowWidth = vp.width * settings.width
        if row.windows.count > 1 {
            let available = rowWidth - settings.gap * CGFloat(row.windows.count - 1)
            strip.setWidthFraction(id, f.width / available)
        } else {
            // Alone in its row: it may be narrowed, leaving room beside it.
            strip.setLoneWidth(id, f.width / rowWidth)
        }
        // Keep the dragged window exactly where it is; the rest of the strip moves around it.
        strip.scrollY = strip.rowTop(r, gap: settings.gap) - (f.minY - vp.minY)
        strip.renderScrollY = strip.scrollY
        w.lastFrame = f
        markDirty(key)
    }

    /// Mouse released: settle into the exact layout (snaps width back for a lone window).
    private func endLiveResize() {
        guard let lr = liveResize else { return }
        liveResize = nil
        liveReadAgain = false
        windows[lr.id]?.lastFrame = nil
        // A narrowed lone window takes in neighbouring narrow windows that fit beside it.
        if let strip = strips[lr.key], strip.packRow(containing: lr.id) {
            Log.debug("packed row around \(lr.id)")
        }
        if let strip = strips[lr.key], let screen = visibleScreen(lr.key) {
            strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: viewport(screen).height, gap: settings.gap)
        }
        relayout(lr.key, animated: true)
    }

    // MARK: Gestures

    func handleGesture(_ e: GestureEvent) {
        guard enabled else { return }
        switch e {
        case .swipeBegan:
            guard settings.swipe.enabled, let screen = Geometry.screenUnderMouse() else { return }
            let key = visibleKey(for: screen)
            guard let strip = strips[key], !strip.isEmpty else { return }
            stopAnimation(key)
            pendingActivation[key] = nil
            pinned.subtract(strip.windowIDs)
            strip.scrollY = strip.renderScrollY
            gesture = GestureState(key: key, strip: strip, screen: screen)
            overlays.wake()
            prepareProxies(strip)
            Log.debug("swipe began")

        case .swipeChanged(let dy):
            guard let g = gesture else { return }
            let vh = viewport(g.screen).height
            let delta = CGFloat(dy * settings.swipe.sensitivity) * vh * (settings.swipe.natural ? 1 : -1)
            let maxS = g.strip.maxScroll(viewportHeight: vh, gap: settings.gap)
            var s = g.strip.scrollY + delta
            if s < 0 || s > maxS {
                // Rubber band past the ends.
                s = g.strip.scrollY + delta * 0.3
                s = min(max(s, -vh * 0.25), maxS + vh * 0.25)
            }
            g.strip.scrollY = s
            g.strip.renderScrollY = s
            markDirty(g.key)

        case .swipeEnded(let v):
            guard let g = gesture else { return }
            gesture = nil
            FrameStats.report("swipe")
            let vh = viewport(g.screen).height
            let velocity = CGFloat(v * settings.swipe.sensitivity) * vh * (settings.swipe.natural ? 1 : -1)
            let s = g.strip.scrollY
            let target: CGFloat
            switch settings.swipe.snap {
            case .always:
                target = g.strip.snapTarget(from: s, velocity: velocity, viewportHeight: vh, gap: settings.gap)
            case .near, .off:
                target = g.strip.restingScroll(from: s, velocity: velocity, viewportHeight: vh, gap: settings.gap,
                                               snapDistance: settings.swipe.snap == .near ? settings.swipe.snapDistance : 0,
                                               momentum: CGFloat(settings.swipe.momentum))
            }
            g.strip.scrollY = target
            // Ease-out starts at 3x its average speed: pick the duration that matches the
            // finger's release speed, so the glide continues the swipe without a jolt.
            let distance = abs(target - s)
            var duration = max(0.15, settings.animationDuration * 1.2)
            if abs(velocity) > 50 && distance > 1 {
                duration = min(max(Double(3 * distance / abs(velocity)), 0.15), 0.7)
            }
            animate(g.key, duration: duration)
            if settings.swipe.focus {
                var focusID = g.strip.focused
                if focusID == nil || !g.strip.isFullyVisible(focusID!, scroll: target, viewportHeight: vh, gap: settings.gap),
                   let r = g.strip.topVisibleRow(scroll: target, viewportHeight: vh, gap: settings.gap) {
                    focusID = g.strip.rows[r].windows.first
                }
                // Our tracked focus is kept current by AX notifications; asking the system here
                // would be a blocking round trip right as the glide starts.
                if let id = focusID, id != g.strip.focused {
                    g.strip.focused = id
                    activateAfterScroll(id, key: g.key)
                }
            }
            Log.debug("swipe ended v=\(Int(velocity)) -> \(Int(target))")
            emit?("swipeEnded", ["scroll": target])

        case .tap, .doubleTap:
            break
        }
    }

    // MARK: Layout

    private func strip(_ key: StripKey) -> Strip {
        if let s = strips[key] { return s }
        let s = Strip()
        strips[key] = s
        return s
    }

    private func locate(_ id: CGWindowID) -> (StripKey, Strip)? {
        for (k, s) in strips where s.contains(id) { return (k, s) }
        return nil
    }

    private func viewport(_ screen: NSScreen) -> CGRect {
        Geometry.ax(screen.visibleFrame).insetBy(dx: settings.outerGap, dy: settings.outerGap)
    }

    private func params(_ screen: NSScreen) -> LayoutParams {
        let vf = Geometry.ax(screen.visibleFrame)
        return LayoutParams(viewport: viewport(screen), hardTop: vf.minY,
                            hardBottom: Geometry.ax(screen.frame).maxY, gap: settings.gap,
                            widthRatio: settings.width, topOverflow: settings.topOverflow,
                            minVisible: settings.minVisible)
    }

    private func visibleKey(for screen: NSScreen, displays: [Spaces.Display]? = nil) -> StripKey {
        StripKey(space: Spaces.current(on: screen, displays: displays ?? Spaces.displays()),
                 display: Geometry.displayID(screen))
    }

    private func visibleKeys() -> [StripKey: NSScreen] {
        let d = Spaces.displays()
        var out: [StripKey: NSScreen] = [:]
        for s in NSScreen.screens { out[visibleKey(for: s, displays: d)] = s }
        return out
    }

    private func isVisible(_ key: StripKey) -> Bool { visibleScreen(key) != nil }

    private func visibleScreen(_ key: StripKey) -> NSScreen? {
        guard let screen = Geometry.screen(displayID: key.display),
              visibleKey(for: screen).space == key.space else { return nil }
        return screen
    }

    func layoutVisible(animated: Bool) {
        for (key, _) in visibleKeys() where strips[key] != nil {
            relayout(key, animated: animated)
        }
    }

    private func relayout(_ key: StripKey, animated: Bool) {
        guard let strip = strips[key] else { return }
        guard let screen = visibleScreen(key) else {
            strip.renderScrollY = strip.scrollY
            return
        }
        if gesture?.key == key { return }
        if animated && settings.animationDuration > 0 && abs(strip.renderScrollY - strip.scrollY) > 1 {
            animate(key, duration: settings.animationDuration)
        } else {
            stopAnimation(key)
            strip.renderScrollY = strip.scrollY
            apply(strip, screen: screen)
            settle(strip, screen: screen)
        }
    }

    private func animate(_ key: StripKey, duration: Double) {
        guard let strip = strips[key] else { return }
        // Retargeted mid-way: a pinned window's final frame is no longer final.
        if animations[key] != nil { pinned.subtract(strip.windowIDs) }
        animations[key] = Animation(strip: strip, from: strip.renderScrollY, to: strip.scrollY,
                                    start: CACurrentMediaTime(), duration: duration)
        prepareProxies(strip)
        driver.start()
    }

    private func markDirty(_ key: StripKey) {
        dirty.insert(key)
        driver.start()
    }

    private func stopAnimation(_ key: StripKey) {
        animations.removeValue(forKey: key)
        if let id = pendingActivation.removeValue(forKey: key), let w = windows[id] ?? floating[id] {
            activate(w)
        }
        if let strip = strips[key] { pinned.subtract(strip.windowIDs) }
    }

    /// One display frame: advance animations, then lay out every strip that changed,
    /// at most once per frame however many swipe events arrived in between.
    private func frame() {
        let now = CACurrentMediaTime()
        var finished: [StripKey] = []
        for (key, a) in animations {
            let t = min(1, (now - a.start) / max(a.duration, 0.001))
            let eased = 1 - pow(1 - t, 3)
            a.strip.renderScrollY = a.from + (a.to - a.from) * CGFloat(eased)
            dirty.insert(key)
            if t >= 1 {
                animations.removeValue(forKey: key)
                finished.append(key)
            }
        }
        // The last frame of an animation lays out every window, including ones pinned for it.
        for key in finished { if let strip = strips[key] { pinned.subtract(strip.windowIDs) } }
        if gesture == nil { for key in finished { releaseProxies(key) } }
        for key in dirty {
            guard let strip = strips[key], let screen = Geometry.screen(displayID: key.display) else { continue }
            apply(strip, screen: screen)
        }
        dirty.removeAll()
        for key in finished {
            FrameStats.report("animation")
            if let id = pendingActivation.removeValue(forKey: key), let w = windows[id] ?? floating[id] {
                activate(w)
            }
            if let strip = strips[key], let screen = Geometry.screen(displayID: key.display) {
                settle(strip, screen: screen)
            }
        }
        if animations.isEmpty && gesture == nil { driver.pause() }
    }

    private func apply(_ strip: Strip, screen: NSScreen) {
        FrameStats.measure {
            let p = params(screen)
            let resizing = liveResize?.id
            for item in strip.layout(p, scroll: strip.renderScrollY, minHeights: minHeights) {
                // Never fight the user's drag: the window being resized stays where they put it.
                // Pinned (just opened) windows are already at their final frame.
                guard item.id != resizing, !pinned.contains(item.id), let w = windows[item.id] else { continue }
                place(w, item.placement, screen: screen, rowHeight: item.rowHeight, hardTop: p.hardTop)
            }
        }
    }

    private func place(_ w: ManagedWindow, _ placement: Placement, screen: NSScreen, rowHeight: CGFloat,
                       hardTop: CGFloat) {
        if proxyPlace(w, placement, screen: screen, hardTop: hardTop) { return }
        if case .overflow(let full) = placement {
            // Capture only now, as the window starts to peek (keeps the recording indicator off
            // otherwise). A real, unshrunk window can be captured wherever it is.
            // A parked window captures greyer (no wallpaper tint): keep an on-screen one if we have it.
            if !overlays.isShowing(w.id) && !w.shrunk && snapshots.age(w.id) > 0.3
                && !(w.parked && snapshots.isOnScreenCapture(w.id)) {
                snapshots.capture(w.id, size: full.size, onScreen: !w.parked)
            }
            if let image = snapshots.image(w.id, size: full.size) {
                // Draw the snapshot first, then move the real window away, so nothing flickers.
                // It stays as a clickable "peek" at rest too, since the real window can't sit there.
                let wasShowing = overlays.isShowing(w.id)
                if !wasShowing { Log.debug("overlay on \(w.id) \(w.appName)") }
                overlays.show(w.id, image: image, full: full, clipTop: hardTop,
                              trueColor: snapshots.isOnScreenCapture(w.id))
                // Park it (at its full row size, so the live mirror isn't squashed) only once
                // the stand-in is on screen: a fresh overlay needs a frame or two to appear.
                if w.parked || pendingParks[w.id] != nil {
                    // already away / about to go
                } else if wasShowing {
                    park(w, screen: screen, size: full.size)
                } else {
                    let size = full.size
                    let item = DispatchWorkItem { [weak self, weak w] in
                        guard let self, let w else { return }
                        self.pendingParks[w.id] = nil
                        if self.overlays.isShowing(w.id) { self.park(w, screen: screen, size: size) }
                    }
                    pendingParks[w.id] = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
                }
                return
            }
            // Snapshot on its way (a frame or two): leave the real window where it is meanwhile.
            if snapshots.isCapturing(w.id) && !w.shrunk { return }
            // No snapshot possible (no Screen Recording permission): pin to the top edge and
            // shrink, or hide if the app can't get that small.
            if !w.parked && !w.shrunk { Log.debug("no usable snapshot for \(w.id) \(w.appName), shrinking") }
            let visible = full.maxY - hardTop
            let needed = max(settings.minVisible, minHeights[w.id] ?? 0)
            let fallback: Placement = visible >= needed
                ? .frame(CGRect(x: full.minX, y: hardTop, width: full.width, height: visible))
                : .park
            return place(w, fallback, screen: screen, rowHeight: rowHeight, hardTop: hardTop)
        }
        pendingParks.removeValue(forKey: w.id)?.cancel()
        if overlays.isShowing(w.id) {
            if case .frame(let r) = placement {
                // Bring the real window back, and keep the stand-in over it for a moment:
                // the window server shows the moved window a frame or two later.
                placeReal(w, placement, screen: screen, rowHeight: rowHeight)
                overlays.handoff(w.id, to: r)
                return
            }
            overlays.hide(w.id)
        }
        placeReal(w, placement, screen: screen, rowHeight: rowHeight)
    }

    // MARK: Slow-app stand-ins

    private func isSlow(_ w: ManagedWindow) -> Bool {
        settings.slowAppProxy && writer.moveLatency(pid: w.pid) > settings.slowAppThreshold
    }

    /// Motion is starting: snapshot the visible windows of slow apps so they can be stood in for.
    private func prepareProxies(_ strip: Strip) {
        guard settings.slowAppProxy else { return }
        // Parked windows too: they may scroll into view, and the capture reads a window's own
        // content wherever it is.
        for id in strip.windowIDs {
            guard let w = windows[id], !w.shrunk, let f = w.lastFrame, isSlow(w),
                  snapshots.age(id) > 0.5, !(w.parked && snapshots.isOnScreenCapture(id)) else { continue }
            Log.debug(String(format: "proxy prepare %d %@ (moves take %.0f ms)", id, w.appName, writer.moveLatency(pid: w.pid)))
            snapshots.capture(id, size: f.size, onScreen: !w.parked)
        }
    }

    /// While moving, a slow app's window is drawn by its stand-in at the new frame every
    /// display frame, and the real window waits (parked) until the motion ends.
    private func proxyPlace(_ w: ManagedWindow, _ placement: Placement, screen: NSScreen, hardTop: CGFloat) -> Bool {
        guard isMoving else {
            // Laid out at rest (e.g. an animation was cut short): the normal path takes over.
            proxied.remove(w.id)
            return false
        }
        switch placement {
        case .frame(let r):
            if !proxied.contains(w.id) {
                guard isSlow(w), !w.shrunk,
                      let image = snapshots.image(w.id, size: r.size) ?? overlays.currentImage(w.id) else { return false }
                overlays.show(w.id, image: image, full: r, clipTop: hardTop,
                              trueColor: snapshots.isOnScreenCapture(w.id))
                proxied.insert(w.id)
                pendingParks.removeValue(forKey: w.id)?.cancel()
                park(w, screen: screen, size: r.size)
                Log.debug("proxy on \(w.id) \(w.appName)")
                return true
            }
            guard let image = overlays.currentImage(w.id) ?? snapshots.image(w.id, size: r.size) else { return false }
            overlays.show(w.id, image: image, full: r, clipTop: hardTop)
            return true
        case .overflow:
            // Becomes a regular top-edge peek (also a stand-in over a parked window).
            proxied.remove(w.id)
            return false
        case .park:
            if proxied.remove(w.id) != nil { overlays.hide(w.id) }
            return false
        }
    }

    /// Motion ended: move each stood-in window to its final frame in one go, and keep the
    /// stand-in on top until the app has actually moved it.
    private func releaseProxies(_ key: StripKey) {
        guard let strip = strips[key], let screen = visibleScreen(key) else { return }
        let ids = strip.windowIDs.filter { proxied.contains($0) }
        guard !ids.isEmpty else { return }
        proxied.subtract(ids)
        let p = params(screen)
        for item in strip.layout(p, scroll: strip.renderScrollY, minHeights: minHeights) where ids.contains(item.id) {
            guard let w = windows[item.id] else { continue }
            guard case .frame(let r) = item.placement else {
                place(w, item.placement, screen: screen, rowHeight: item.rowHeight, hardTop: p.hardTop)
                continue
            }
            overlays.handoff(w.id, to: r, delay: 0.6)  // fallback if the app never answers
            placeReal(w, item.placement, screen: screen, rowHeight: item.rowHeight)
            let id = w.id
            writer.perform(pid: w.pid) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let self, !self.proxied.contains(id) else { return }
                    self.overlays.fadeOut(id)
                }
            }
        }
    }

    private func park(_ w: ManagedWindow, screen: NSScreen, size wanted: CGSize? = nil) {
        guard !w.parked else { return }
        var size = w.lastFrame?.size ?? AX.size(w.element) ?? CGSize(width: 800, height: 600)
        var setSize = false
        if let wanted, abs(wanted.width - size.width) > 0.5 || abs(wanted.height - size.height) > 0.5 {
            size = wanted
            setSize = true
        }
        let p = parkPoint(screen, size: size)
        writer.move(w.id, pid: w.pid, element: w.element, to: CGRect(origin: p, size: size), setSize: setSize)
        w.parked = true
        w.shrunk = false
        w.lastFrame = CGRect(origin: p, size: size)
    }

    private func placeReal(_ w: ManagedWindow, _ placement: Placement, screen: NSScreen, rowHeight: CGFloat) {
        switch placement {
        case .frame(let r):
            if !w.parked, let lf = w.lastFrame, lf.approxEqual(r) { return }
            let sizeChanged = w.lastFrame.map { abs($0.width - r.width) > 0.5 || abs($0.height - r.height) > 0.5 } ?? true
            w.shrunk = r.height < rowHeight - 1
            // Shrunk at the top edge: have the writer report it if the app refuses that height.
            writer.move(w.id, pid: w.pid, element: w.element, to: r, setSize: sizeChanged, checkMinHeight: w.shrunk)
            w.lastFrame = r
            w.parked = false
            if sizeChanged && !w.shrunk { w.needsSizeCheck = true }
        case .park:
            park(w, screen: screen)
        case .overflow:
            break
        }
    }

    var isMoving: Bool { gesture != nil || !animations.isEmpty }

    private func setupSnapshots() {
        overlays.onClick = { [weak self] id in
            Log.debug("peek clicked \(id)")
            self?.focus(id)
        }
        // A snapshot arrived for a window that started peeking: draw it now.
        snapshots.onReady = { [weak self] id in
            guard let self, let (key, _) = self.locate(id) else { return }
            self.markDirty(key)
        }
    }



    /// Off-screen spot for windows outside the viewport (macOS keeps ≥1px of a window on screen).
    private func parkPoint(_ screen: NSScreen, size: CGSize) -> CGPoint {
        let sf = Geometry.ax(screen.frame)
        let others = NSScreen.screens.filter { $0 != screen }.map { Geometry.ax($0.frame) }
        let candidates = [
            CGPoint(x: sf.maxX - 1, y: sf.maxY - 1),
            CGPoint(x: sf.minX - size.width + 1, y: sf.maxY - 1),
        ]
        return candidates.first { c in
            let r = CGRect(origin: c, size: size).insetBy(dx: 2, dy: 2)
            return !others.contains { $0.intersects(r) }
        } ?? candidates[0]
    }

    /// After a layout comes to rest, check (off the main thread) whether resized windows
    /// actually took their new height; adopt the height of any that refused to get smaller.
    private func settle(_ strip: Strip, screen: NSScreen) {
        let vh = viewport(screen).height
        for row in strip.rows {
            for id in row.windows {
                guard let w = windows[id], w.needsSizeCheck, !w.parked, !w.shrunk, let lf = w.lastFrame else { continue }
                w.needsSizeCheck = false
                let expected = lf.height
                let element = w.element
                writer.perform(pid: w.pid) { [weak self] in
                    guard let actual = AX.size(element), actual.height > expected + 4, actual.height <= vh + 1 else { return }
                    DispatchQueue.main.async { self?.adoptHeight(id, actual.height) }
                }
            }
        }
    }

    private func adoptHeight(_ id: CGWindowID, _ height: CGFloat) {
        guard !isMoving, let (key, strip) = locate(id), let (r, _) = strip.locate(id),
              strip.rows[r].height < height else { return }
        Log.debug("window \(id) refused height \(Int(strip.rows[r].height)), adopting \(Int(height))")
        strip.rows[r].height = height.rounded()
        relayout(key, animated: false)
    }

    // MARK: Focus

    private func systemFocusedWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        guard let el = AX.element(appEl, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(el)
    }

    /// Focuses the window. Runs on the app's writer queue: after its pending moves, and
    /// without blocking the main thread on a slow app.
    private func activate(_ w: ManagedWindow) {
        trackedFocus = w.id
        let pid = w.pid
        let element = w.element
        let name = w.appName
        writer.perform(pid: pid) {
            let t0 = CACurrentMediaTime()
            AX.set(element, kAXMainAttribute, kCFBooleanTrue)
            AX.set(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, kCFBooleanTrue)
            AX.raise(element)
            Log.debug(String(format: "[focus] activating %@ took %.0f ms", name, (CACurrentMediaTime() - t0) * 1000))
        }
    }

    func focus(_ id: CGWindowID) {
        guard let w = windows[id] ?? floating[id] else { return }
        if let (key, strip) = locate(id) {
            strip.focused = id
            if let screen = visibleScreen(key) {
                strip.scrollY = strip.scrollToReveal(id, viewportHeight: viewport(screen).height, gap: settings.gap)
                relayout(key, animated: true)
                activateAfterScroll(id, key: key)
                return
            }
        }
        activate(w)
    }

    /// Focuses now if the strip is at rest, otherwise as soon as its animation ends.
    private func activateAfterScroll(_ id: CGWindowID, key: StripKey) {
        trackedFocus = id
        if animations[key] != nil {
            pendingActivation[key] = id
        } else if let w = windows[id] ?? floating[id] {
            pendingActivation[key] = nil
            activate(w)
        }
    }

    // MARK: Commands

    private struct Context {
        let key: StripKey
        let strip: Strip
        let screen: NSScreen
        let id: CGWindowID?
        var vh: CGFloat
    }

    /// Focused window: the one AX last reported, if it still belongs to the frontmost app
    /// (a local check); otherwise ask the app.
    private func focusedWindowID() -> CGWindowID? {
        if let id = trackedFocus, let w = windows[id] ?? floating[id],
           w.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return id
        }
        return systemFocusedWindowID()
    }

    private func context() -> Context? {
        if let fid = focusedWindowID(), let (key, strip) = locate(fid), let screen = visibleScreen(key) {
            strip.focused = fid
            return Context(key: key, strip: strip, screen: screen, id: fid, vh: viewport(screen).height)
        }
        guard let screen = Geometry.screenUnderMouse() else { return nil }
        let key = visibleKey(for: screen)
        let strip = self.strip(key)
        return Context(key: key, strip: strip, screen: screen, id: strip.focused, vh: viewport(screen).height)
    }

    @discardableResult
    func perform(_ name: String, arg: Any? = nil) -> Bool {
        guard let cmd = Command(rawValue: name) else {
            Log.info("unknown command: \(name)")
            return false
        }
        switch cmd {
        case .toggleTiling: setEnabled(!enabled); return true
        case .reloadConfig: reloadConfig?(); return true
        case .missionControl: SystemActions.missionControl(); return true
        case .appExpose: SystemActions.appExpose(); return true
        case .showDesktop: SystemActions.showDesktop(); return true
        case .launchpad: SystemActions.launchpad(); return true
        case .retile:
            for w in windows.values { w.lastFrame = nil; w.parked = false }
            scanAll(initial: false)
            return true
        default: break
        }
        guard enabled, let c = context() else { return false }
        let gap = settings.gap
        let s = c.strip

        func reveal(_ id: CGWindowID) {
            s.scrollY = s.scrollToReveal(id, viewportHeight: c.vh, gap: gap)
        }
        func number(_ v: Any?) -> CGFloat? {
            (v as? NSNumber).map { CGFloat($0.doubleValue) } ?? (v as? Double).map { CGFloat($0) }
        }

        switch cmd {
        case .focusUp, .focusDown, .focusLeft, .focusRight:
            guard let id = c.id else {
                if let first = s.rows.first?.windows.first { focus(first) }
                return true
            }
            let dir: Direction = [.focusUp: .up, .focusDown: .down, .focusLeft: .left, .focusRight: .right][cmd]!
            if let n = s.neighbor(of: id, dir) { focus(n) }
        case .focusFirst:
            if let n = s.rows.first?.windows.first { focus(n) }
        case .focusLast:
            if let n = s.rows.last?.windows.first { focus(n) }
        case .focusRow:
            // 1-based row number, like workspace numbers.
            guard let n = number(arg).map({ Int($0) }), n >= 1, n <= s.rows.count else { return false }
            if let id = s.rows[n - 1].windows.first { focus(id) }

        case .moveUp, .moveDown, .moveLeft, .moveRight, .moveFirst, .moveLast, .slurpIn, .barfOut,
             .joinUp, .joinDown:
            guard let id = c.id else { return false }
            switch cmd {
            case .moveUp: s.moveVertical(id, by: -1)
            case .moveDown: s.moveVertical(id, by: 1)
            case .moveLeft: s.moveHorizontal(id, by: -1)
            case .moveRight: s.moveHorizontal(id, by: 1)
            case .moveFirst: s.moveToEdge(id, top: true)
            case .moveLast: s.moveToEdge(id, top: false)
            case .slurpIn: s.slurpIn(id)
            case .joinUp: s.joinVertical(id, by: -1)
            case .joinDown: s.joinVertical(id, by: 1)
            case .barfOut: s.barfOut(id)
            default: break
            }
            reveal(id)
            relayout(c.key, animated: true)

        case .cycleWidth, .cycleWidthBack, .setWidth, .resizeWidth, .equalizeRow:
            guard let id = c.id, let (r, _) = s.locate(id) else { return false }
            if s.rows[r].windows.count == 1 {
                // Alone in its row: the share is of the whole row, the rest stays empty unless
                // neighbouring narrow windows fit there (then they join the row).
                let cur = min(s.weight(id), 1)
                switch cmd {
                case .cycleWidth, .cycleWidthBack:
                    let presets = (settings.widths + [1]).sorted()
                    let next = cmd == .cycleWidth ? presets.first { $0 > cur + 0.01 } ?? presets.first!
                                                  : presets.last { $0 < cur - 0.01 } ?? presets.last!
                    s.setLoneWidth(id, next)
                case .setWidth:
                    guard let f = number(arg), f > 0, f <= 1 else { return false }
                    s.setLoneWidth(id, f)
                case .resizeWidth:
                    s.setLoneWidth(id, cur + (number(arg) ?? settings.resizeStep))
                default:
                    s.setLoneWidth(id, nil)
                }
                s.packRow(containing: id)
                windows[id]?.lastFrame = nil
                relayout(c.key, animated: true)
                return true
            }
            switch cmd {
            case .cycleWidth, .cycleWidthBack:
                if let f = s.cycledWidthFraction(id, ratios: settings.widths, forward: cmd == .cycleWidth) {
                    s.setWidthFraction(id, f)
                }
            case .setWidth:
                guard let f = number(arg), f > 0, f < 1 else { return false }
                s.setWidthFraction(id, f)
            case .resizeWidth:
                let step = number(arg) ?? settings.resizeStep
                s.setWidthFraction(id, (s.widthFraction(id) ?? 0.5) + step)
            default:
                s.equalizeRow(of: id)
            }
            relayout(c.key, animated: true)

        case .cycleHeight, .cycleHeightBack, .setHeight, .toggleFullHeight, .resizeHeight:
            guard let id = c.id, let (r, _) = s.locate(id), let w = windows[id] else { return false }
            switch cmd {
            case .cycleHeight, .cycleHeightBack:
                if let h = s.cycledHeight(id, ratios: settings.heights, viewportHeight: c.vh, gap: gap,
                                          forward: cmd == .cycleHeight) {
                    s.rows[r].height = h
                }
                w.savedHeight = nil
            case .resizeHeight:
                let step = (number(arg) ?? settings.resizeStep) * c.vh
                s.rows[r].height = min(max(s.rows[r].height + step, 80), c.vh).rounded()
                w.savedHeight = nil
            case .setHeight:
                guard let ratio = number(arg), ratio > 0 else { return false }
                s.rows[r].height = ratio <= 1
                    ? Strip.height(forRatio: ratio, viewportHeight: c.vh, gap: gap)
                    : min(ratio, c.vh)
            default:
                if let saved = w.savedHeight {
                    s.rows[r].height = saved
                    w.savedHeight = nil
                } else {
                    w.savedHeight = s.rows[r].height
                    s.rows[r].height = c.vh
                }
            }
            reveal(id)
            relayout(c.key, animated: true)

        case .center, .alignTop:
            guard let id = c.id else { return false }
            s.scrollY = cmd == .center
                ? s.scrollToCenter(id, viewportHeight: c.vh, gap: gap)
                : s.scrollToTop(id, gap: gap)
            relayout(c.key, animated: true)

        case .scrollUp, .scrollDown, .scrollBy:
            var delta: CGFloat
            if cmd == .scrollBy {
                delta = number(arg) ?? 0
            } else {
                delta = (number(arg) ?? 0.5) * c.vh * (cmd == .scrollUp ? -1 : 1)
            }
            s.scrollY = s.clampScroll(s.scrollY + delta, viewportHeight: c.vh, gap: gap)
            relayout(c.key, animated: true)
        case .scrollToTop:
            s.scrollY = 0
            relayout(c.key, animated: true)
        case .scrollToBottom:
            s.scrollY = s.maxScroll(viewportHeight: c.vh, gap: gap)
            relayout(c.key, animated: true)

        case .toggleFloat:
            toggleFloat(c)
        case .closeWindow:
            guard let id = c.id ?? systemFocusedWindowID(), let w = windows[id] ?? floating[id],
                  let button = AX.element(w.element, kAXCloseButtonAttribute) else { return false }
            AX.press(button)
        case .moveToNextScreen:
            moveToNextScreen(c)
        default:
            return false
        }
        return true
    }

    private func toggleFloat(_ c: Context) {
        guard let fid = systemFocusedWindowID() else { return }
        if let w = windows[fid] {
            // Tiled -> floating: take it out and center it.
            windows.removeValue(forKey: fid)
            c.strip.remove(fid)
            floating[fid] = w
            let vp = viewport(c.screen)
            let size = CGSize(width: min(vp.width * 0.6, 1200), height: min(vp.height * 0.7, 900))
            let origin = CGPoint(x: vp.midX - size.width / 2, y: vp.midY - size.height / 2)
            pendingParks.removeValue(forKey: fid)?.cancel()
            overlays.hide(fid)
            writer.move(fid, pid: w.pid, element: w.element, to: CGRect(origin: origin, size: size), setSize: true)
            let element = w.element
            writer.perform(pid: w.pid) { AX.raise(element) }
            c.strip.scrollY = c.strip.clampScroll(c.strip.scrollY, viewportHeight: c.vh, gap: settings.gap)
            relayout(c.key, animated: true)
        } else if let w = floating.removeValue(forKey: fid) {
            windows[fid] = w
            w.lastFrame = nil
            let h = Strip.height(forRatio: settings.defaultHeight, viewportHeight: c.vh, gap: settings.gap)
            c.strip.insert(fid, height: h, anchor: c.strip.focused, position: settings.newWindowPosition)
            c.strip.focused = fid
            c.strip.scrollY = c.strip.scrollToReveal(fid, viewportHeight: c.vh, gap: settings.gap)
            relayout(c.key, animated: true)
        }
    }

    private func moveToNextScreen(_ c: Context) {
        let screens = NSScreen.screens
        guard screens.count > 1, let id = c.id, let (r, _) = c.strip.locate(id),
              let i = screens.firstIndex(of: c.screen) else { return }
        let height = c.strip.rows[r].height
        let target = screens[(i + 1) % screens.count]
        c.strip.remove(id)
        let tkey = visibleKey(for: target)
        let ts = strip(tkey)
        ts.insert(id, height: min(height, viewport(target).height), anchor: ts.focused, position: .below)
        ts.focused = id
        windows[id]?.lastFrame = nil
        relayout(c.key, animated: true)
        focus(id)
    }

    // MARK: Introspection (for the JS config)

    func info(_ w: ManagedWindow) -> [String: Any] {
        var d: [String: Any] = [
            "id": Int(w.id), "app": w.appName, "bundleId": w.bundleID ?? "", "title": w.title,
            "floating": floating[w.id] != nil,
        ]
        if let (key, strip) = locate(w.id), let (r, c) = strip.locate(w.id) {
            d["row"] = r
            d["column"] = c
            d["height"] = strip.rows[r].height
            d["focused"] = strip.focused == w.id
            d["space"] = key.space
            d["display"] = key.display
        }
        return d
    }

    func allWindowsInfo() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (_, strip) in strips {
            for id in strip.windowIDs { if let w = windows[id] { out.append(info(w)) } }
        }
        out += floating.values.map(info)
        return out
    }

    func focusedInfo() -> [String: Any]? {
        guard let id = systemFocusedWindowID(), let w = windows[id] ?? floating[id] else { return nil }
        return info(w)
    }
}

extension CGRect {
    func approxEqual(_ o: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - o.minX) <= tolerance && abs(minY - o.minY) <= tolerance
            && abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}
