import ApplicationServices
import Cocoa
import OzCore

let commandNotification = Notification.Name("dev.oz.wm.command")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let wm = WindowManager()
    private lazy var config = ConfigEngine(wm: wm)
    private let gestures = GestureController()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var started = false
    private var signalSources: [DispatchSourceSignal] = []
    /// Keeps App Nap off: as a background agent Oz would otherwise get its timers and
    /// main-thread work throttled by hundreds of milliseconds (measured), which showed up
    /// as random hitches in swipes and animations.
    private var activity: NSObjectProtocol?
    private var areaEditor: ScrollAreaEditor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        installSignalHandlers()
        if AXIsProcessTrusted() {
            startOz()
        } else {
            requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    private func shutdown() {
        gestures.stop()
        if started { wm.restoreAll() }
        restoreWallpaperTinting()
    }

    // MARK: Startup

    private func requestAccessibility() {
        Log.info("waiting for Accessibility permission")
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.startOz()
        }
    }

    private func startOz() {
        guard !started else { return }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Window management reacts to gestures in real time")
        Watchdog.start()
        disableWallpaperTinting()

        wm.rulesProvider = { [unowned self] w in config.rules(for: w) }
        wm.emit = { [unowned self] event, payload in config.emit(event, payload) }
        wm.reloadConfig = { [unowned self] in config.load() }
        wm.onEnabledChanged = { [weak self] _ in self?.updateStatusIcon() }
        wm.editScrollArea = { [weak self] screen in self?.openScrollAreaEditor(screen) }
        config.onLoaded = { [unowned self] s in
            var s = s
            // The menu's choice wins over the config file's `livePeek`.
            if let live = UserDefaults.standard.object(forKey: "livePeek") as? Bool { s.livePeek = live }
            if let smooth = UserDefaults.standard.object(forKey: "smoothScroll") as? Bool { s.smoothScroll = smooth }
            wm.settings = s
            Log.debugEnabled = s.debug
            gestures.configure(s)
            if started { wm.settingsChanged() }
        }
        config.load()
        config.watch()
        wm.start()
        started = true

        gestures.handler = { [unowned self] e in
            if case .doubleTap = e {
                runDoubleTap()
            } else {
                wm.handleGesture(e)
            }
        }
        gestures.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.gestures.restart() }
        }

        DistributedNotificationCenter.default().addObserver(forName: commandNotification, object: nil,
                                                            queue: .main) { [weak self] n in
            guard let name = n.object as? String else { return }

            let arg = n.userInfo?["arg"] as? String
            self?.wm.perform(name, arg: arg.flatMap { Double($0) }.map { NSNumber(value: $0) } ?? arg)
        }

        Log.info("Oz started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerTrackpadSetup() }
    }

    private func runDoubleTap() {
        let action = wm.settings.doubleTap.action
        Log.debug("double tap -> \(action)")
        if action.hasPrefix("binding:"), let id = Int(action.dropFirst("binding:".count)) {
            config.runBinding(id)
        } else {
            wm.perform(action)
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Trackpad

    private func offerTrackpadSetup() {
        guard wm.settings.swipe.enabled, wm.settings.swipe.fingers == 3,
              TrackpadSetup.systemOwnsThreeFingerSwipe,
              !UserDefaults.standard.bool(forKey: "trackpadSetupDeclined") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Give the three-finger vertical swipe to Oz?"
        alert.informativeText = """
        Right now a three-finger swipe up opens Mission Control. Oz uses this gesture \
        to scroll the window strip.

        If you choose Apply:
        • Three fingers up/down → Oz scrolls the strip
        • Mission Control → three-finger double tap (also four fingers up and F3)
        • App Exposé → four fingers down

        You can undo this any time from the Oz menu in the menu bar.
        """
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        switch alert.runModal() {
        case .alertFirstButtonReturn: applyTrackpad()
        case .alertThirdButtonReturn: UserDefaults.standard.set(true, forKey: "trackpadSetupDeclined")
        default: break
        }
    }

    @objc private func applyTrackpad() {
        TrackpadSetup.run("apply")
        gestures.restart()
    }

    @objc private func restoreTrackpad() {
        TrackpadSetup.run("restore")
    }

    // MARK: Wallpaper tinting

    /// macOS tints window backgrounds with the wallpaper colour behind them (System Settings ›
    /// Appearance › "Allow wallpaper tinting in windows"). Windows Oz parks off screen lose
    /// that tint, so the stand-ins drawn from their captures would look different from the
    /// real windows. Oz therefore keeps the tint off while it runs and restores the user's
    /// choice when it quits.
    private static let tintKey = "AppleReduceDesktopTinting" as CFString
    private static let savedTintKey = "tintingWasOnBeforeOz"

    private var wallpaperTintingOn: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return !(CFPreferencesCopyAppValue(AppDelegate.tintKey, kCFPreferencesAnyApplication) as? Bool ?? false)
    }

    private func disableWallpaperTinting() {
        guard wallpaperTintingOn else { return }
        UserDefaults.standard.set(true, forKey: AppDelegate.savedTintKey)
        SystemActions.run("/usr/bin/defaults", ["write", "-g", "AppleReduceDesktopTinting", "-bool", "true"])
        Log.info("macOS wallpaper tinting turned off (restored when Oz quits)")
    }

    private func restoreWallpaperTinting() {
        guard UserDefaults.standard.bool(forKey: AppDelegate.savedTintKey) else { return }
        UserDefaults.standard.removeObject(forKey: AppDelegate.savedTintKey)
        // Synchronous: this runs while quitting.
        _ = SystemActions.shellSync("/usr/bin/defaults write -g AppleReduceDesktopTinting -bool false")
        Log.info("macOS wallpaper tinting restored")
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Oz") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "oz"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
            return i
        }

        if !started {
            item("Waiting for Accessibility permission…", nil).isEnabled = false
            item("Open Accessibility Settings", #selector(openAccessibilitySettings))
        } else {
            let count = wm.allWindowsInfo().count
            item("Oz WM — \(count) window\(count == 1 ? "" : "s")", nil).isEnabled = false
            if let err = config.lastError {
                item("⚠︎ Config error: \(err)", nil).isEnabled = false
            }
            if wm.settings.topOverflow == .slide && !SnapshotCache.hasPermission {
                item("⚠︎ Allow Screen Recording for the slide-off effect…", #selector(openScreenRecordingSettings))
            }
            if TouchSource.shared.deviceCount == 0 {
                item("⚠︎ No trackpad found", nil).isEnabled = false
            }
            menu.addItem(.separator())
            item("Tiling Enabled", #selector(toggleTiling)).state = wm.enabled ? .on : .off
            if wm.enabled, let screen = Geometry.screenUnderMouse() {
                item("Tile This Desktop", #selector(toggleSpaceTiling)).state = wm.isTiled(screen: screen) ? .on : .off
                if wm.isTiled(screen: screen) {
                    item("Set Scroll Area…", #selector(setScrollArea))
                    if wm.scrollAreaFraction(screen) != nil {
                        item("Reset Scroll Area", #selector(resetScrollArea))
                    }
                }
            }
            item("Keep Windows Alive (Live Capture)", #selector(toggleLivePeek)).state = wm.settings.livePeek ? .on : .off
            item("Smooth Scrolling (Snapshots While Moving)", #selector(toggleSmoothScroll)).state = wm.settings.smoothScroll ? .on : .off
            item("Retile", #selector(retile))
        }
        menu.addItem(.separator())
        item("Edit Config", #selector(editConfig), key: ",")
        item("Reload Config", #selector(reloadConfig))
        item("Show Config Folder", #selector(revealConfig))
        item("Open Log", #selector(openLog))
        menu.addItem(.separator())
        if TrackpadSetup.systemOwnsThreeFingerSwipe {
            item("Trackpad: Give Three-Finger Swipe to Oz", #selector(applyTrackpad))
        } else {
            item("Trackpad: Restore macOS Gestures", #selector(restoreTrackpad))
        }
        menu.addItem(.separator())
        item("Quit Oz", #selector(quit), key: "q")
    }

    @objc private func toggleTiling() { wm.setEnabled(!wm.enabled) }
    @objc private func toggleSpaceTiling() { wm.perform("toggleSpaceTiling") }

    /// On: windows peeking over an edge are captured continuously (video keeps playing).
    /// Off: one picture when a window starts to peek, shown as is.
    @objc private func toggleLivePeek() {
        let on = !wm.settings.livePeek
        UserDefaults.standard.set(on, forKey: "livePeek")
        wm.setLivePeek(on)
    }

    /// On: while the strip moves every window is a snapshot, the real ones move once at the end.
    @objc private func toggleSmoothScroll() {
        let on = !wm.settings.smoothScroll
        UserDefaults.standard.set(on, forKey: "smoothScroll")
        wm.setSmoothScroll(on)
    }

    @objc private func setScrollArea() {
        guard let screen = Geometry.screenUnderMouse() else { return }
        openScrollAreaEditor(screen)
    }

    @objc private func resetScrollArea() {
        guard let screen = Geometry.screenUnderMouse() else { return }
        wm.setScrollArea(nil, screen: screen)
    }

    /// The editor covers the screen; the area is saved for the desktop shown there.
    private func openScrollAreaEditor(_ screen: NSScreen) {
        guard areaEditor == nil else { return }
        let editor = ScrollAreaEditor(screen: screen, fraction: wm.scrollAreaFraction(screen)) { [weak self] area in
            self?.wm.setScrollArea(area, screen: screen)
        }
        areaEditor = editor
        editor.onClose = { [weak self] in self?.areaEditor = nil }
        editor.show()
    }

    /// Dimmed while Oz doesn't tile what's on screen (off, or off for this desktop).
    private func updateStatusIcon() {
        let tiled = wm.enabled && (Geometry.screenUnderMouse().map(wm.isTiled) ?? true)
        statusItem.button?.appearsDisabled = !tiled
    }
    @objc private func retile() { wm.perform("retile") }
    @objc private func reloadConfig() { config.load() }

    @objc private func editConfig() {
        config.ensureConfigFile()
        SystemActions.run("/usr/bin/open", ["-t", ConfigEngine.configURL.path])
    }

    @objc private func revealConfig() {
        config.ensureConfigFile()
        NSWorkspace.shared.activateFileViewerSelecting([ConfigEngine.configURL])
    }

    @objc private func openLog() {
        SystemActions.run("/usr/bin/open", ["-a", "Console", Log.url.path])
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecordingSettings() {
        wm.snapshots.requestPermissionOnce()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
