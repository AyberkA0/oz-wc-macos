import AppKit
import ServiceManagement

/// Start Oz when you log in: Oz registered as a login item (System Settings > General >
/// Login Items lists it, and can turn it off there too).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but macOS wants it allowed in System Settings first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("start at login \(on ? "on" : "off") (status \(SMAppService.mainApp.status.rawValue))")
        } catch {
            Log.info("start at login \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
