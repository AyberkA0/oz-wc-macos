import Cocoa

// Private SkyLight/CoreGraphics calls for Mission Control Spaces. They are
// read-only, work without disabling SIP, and are used by yabai, AeroSpace, AltTab.
private typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ wids: CFArray) -> CFArray?

typealias SpaceID = UInt64

enum Spaces {
    private static let cid = CGSMainConnectionID()
    static var connection: Int32 { cid }

    struct Display {
        let identifier: String
        let current: SpaceID
        let fullscreen: Set<SpaceID>
        /// Every Space on the display with a name that survives restarts (see `persistentKey`).
        let keys: [SpaceID: String]
    }

    /// Main thread only: the last answer, reused for a moment (it's a window-server round
    /// trip, and layout, commands and focus changes ask for it many times in a row).
    /// `invalidate` drops it when the desktop or the displays change.
    private static var cached: (at: CFTimeInterval, displays: [Display])?
    private static let cacheLifetime: CFTimeInterval = 0.5

    static func invalidate() { cached = nil }

    static func displays() -> [Display] {
        guard Thread.isMainThread else { return fetchDisplays() }
        let now = CACurrentMediaTime()
        if let c = cached, now - c.at < cacheLifetime { return c.displays }
        let fresh = fetchDisplays()
        cached = (now, fresh)
        return fresh
    }

    private static func fetchDisplays() -> [Display] {
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return arr.map { d in
            let id = d["Display Identifier"] as? String ?? "Main"
            let cur = spaceID(d["Current Space"] as? [String: Any])
            var fs = Set<SpaceID>()
            var keys: [SpaceID: String] = [:]
            for s in (d["Spaces"] as? [[String: Any]]) ?? [] {
                let sid = spaceID(s)
                if (s["type"] as? NSNumber)?.intValue == 4 { fs.insert(sid) }
                // The display's first desktop has no uuid; it can't be removed, so name it by its display.
                let uuid = s["uuid"] as? String ?? ""
                keys[sid] = uuid.isEmpty ? "main:\(id)" : uuid
            }
            return Display(identifier: id, current: cur, fullscreen: fs, keys: keys)
        }
    }

    private static func spaceID(_ d: [String: Any]?) -> SpaceID {
        ((d?["ManagedSpaceID"] ?? d?["id64"]) as? NSNumber)?.uint64Value ?? 0
    }

    /// A display's UUID never changes for its ID; layout asks for it every frame.
    private static var uuids: [CGDirectDisplayID: String] = [:]

    static func uuid(of screen: NSScreen) -> String? {
        let id = Geometry.displayID(screen)
        if Thread.isMainThread, let u = uuids[id] { return u }
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, u) as String? else { return nil }
        if Thread.isMainThread { uuids[id] = s }
        return s
    }

    /// The Space currently shown on `screen`.
    static func current(on screen: NSScreen, displays: [Display] = Spaces.displays()) -> SpaceID {
        let uuid = uuid(of: screen)
        if let d = displays.first(where: { $0.identifier.caseInsensitiveCompare(uuid ?? "") == .orderedSame }) {
            return d.current
        }
        // "Displays have separate Spaces" off: one entry ("Main") spans all screens.
        return displays.first?.current ?? 0
    }

    /// A name for the Space that stays the same across restarts (ManagedSpaceIDs don't).
    static func persistentKey(_ space: SpaceID, displays: [Display] = Spaces.displays()) -> String? {
        displays.lazy.compactMap { $0.keys[space] }.first
    }

    static func isFullscreen(_ space: SpaceID) -> Bool {
        displays().contains { $0.fullscreen.contains(space) }
    }

    static func space(of wid: CGWindowID) -> SpaceID? {
        guard let arr = CGSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray) as? [NSNumber],
              let first = arr.first else { return nil }
        return first.uint64Value
    }
}
