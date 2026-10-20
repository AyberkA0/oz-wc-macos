import Cocoa

enum SystemActions {
    private static let missionControlBinary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"

    /// Same as F3 / the old three-finger swipe up.
    static func missionControl() { run(missionControlBinary, []) }
    /// Windows of the current app (old three-finger swipe down).
    static func appExpose() { run(missionControlBinary, ["2"]) }
    static func showDesktop() { run(missionControlBinary, ["1"]) }

    static func launchpad() {
        for path in ["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }

    static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { Log.info("failed to run \(path): \(error)") }
    }

    /// Runs a shell command in the background (oz.exec in the config).
    static func shell(_ command: String) {
        run("/bin/sh", ["-c", command])
    }

    /// Runs a shell command and returns stdout (oz.shell in the config).
    static func shellSync(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Frees the three-finger vertical swipe from Mission Control / App Exposé
/// (moves them to four fingers) so Oz can use it for scrolling.
enum TrackpadSetup {
    static var scriptPath: String? {
        if let p = Bundle.main.path(forResource: "trackpad-gestures", ofType: "sh") { return p }
        let dev = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/trackpad-gestures.sh").standardized.path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// True while macOS still owns the three-finger vertical swipe.
    static var systemOwnsThreeFingerSwipe: Bool {
        CFPreferencesAppSynchronize("com.apple.AppleMultitouchTrackpad" as CFString)
        let v = CFPreferencesCopyAppValue("TrackpadThreeFingerVertSwipeGesture" as CFString,
                                          "com.apple.AppleMultitouchTrackpad" as CFString) as? NSNumber
        return (v?.intValue ?? 2) != 0
    }

    @discardableResult
    static func run(_ action: String) -> String {
        guard let script = scriptPath else { return "trackpad-gestures.sh not found" }
        let out = SystemActions.shellSync("/bin/bash '\(script)' \(action) 2>&1")
        Log.info("trackpad \(action): \(out)")
        return out
    }
}
