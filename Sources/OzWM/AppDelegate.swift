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

        wm.rulesProvider = { [unowned self] w in config.rules(for: w) }
        wm.emit = { [unowned self] event, payload in config.emit(event, payload) }
        wm.reloadConfig = { [unowned self] in config.load() }
        wm.onEnabledChanged = { [weak self] _ in self?.statusItem.button?.appearsDisabled = !(self?.wm.enabled ?? true) }
        config.onLoaded = { [unowned self] s in
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

    /// macOS tints window backgrounds with the wallpaper colour behind them. Windows Oz
    /// parks off screen lose that tint, so their stand-ins can look slightly different.
    /// Turning the tint off (System Settings › Appearance) removes the difference entirely.
    private var wallpaperTintingOn: Bool {
        !(CFPreferencesCopyAppValue("AppleReduceDesktopTinting" as CFString,
                                    kCFPreferencesAnyApplication) as? Bool ?? false)
    }

    @objc private func toggleWallpaperTinting() {
        let turnOff = wallpaperTintingOn
        if turnOff {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Turn off wallpaper tinting in windows?"
            alert.informativeText = """
            macOS tints window backgrounds with the colour of the wallpaper behind them. \
            Windows that Oz draws from a capture (sliding off the top, slow apps while \
            scrolling) can't get that tint, so they look slightly different.

            This changes the macOS setting System Settings › Appearance › \
            "Allow wallpaper tinting in windows". Apps pick it up when they are reopened.
            """
            alert.addButton(withTitle: "Turn Off")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        SystemActions.run("/usr/bin/defaults", ["write", "-g", "AppleReduceDesktopTinting", "-bool", turnOff ? "true" : "false"])
        Log.info("wallpaper tinting \(turnOff ? "off" : "on")")
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
        item("Wallpaper Tinting in Windows", #selector(toggleWallpaperTinting)).state = wallpaperTintingOn ? .on : .off
        menu.addItem(.separator())
        item("Quit Oz", #selector(quit), key: "q")
    }

    @objc private func toggleTiling() { wm.setEnabled(!wm.enabled) }
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
