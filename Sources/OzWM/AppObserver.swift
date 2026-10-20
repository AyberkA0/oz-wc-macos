import ApplicationServices
import Cocoa

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let o = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    o.handler?(notification as String, element, o.pid)
}

/// Accessibility notifications for one application.
final class AppObserver {
    let pid: pid_t
    let app: AXUIElement
    var handler: ((String, AXUIElement, pid_t) -> Void)?
    private var observer: AXObserver?
    private var appRegistered = false

    static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    init?(pid: pid_t) {
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return nil }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        registerApp(attempt: 0)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Freshly launched apps often reject registration for a moment; retry a few times.
    private func registerApp(attempt: Int) {
        guard let observer else { return }
        var ok = true
        for n in AppObserver.appNotifications {
            let err = AXObserverAddNotification(observer, app, n as CFString, refcon)
            if err != .success && err != .notificationAlreadyRegistered { ok = false }
        }
        appRegistered = ok
        if !ok && attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.registerApp(attempt: attempt + 1)
            }
        }
    }

    func watch(window: AXUIElement) {
        guard let observer else { return }
        for n in AppObserver.windowNotifications {
            AXObserverAddNotification(observer, window, n as CFString, refcon)
        }
    }
}
