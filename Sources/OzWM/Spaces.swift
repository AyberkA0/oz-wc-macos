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
    }

    static func displays() -> [Display] {
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return arr.map { d in
            let id = d["Display Identifier"] as? String ?? "Main"
            let cur = spaceID(d["Current Space"] as? [String: Any])
            var fs = Set<SpaceID>()
            for s in (d["Spaces"] as? [[String: Any]]) ?? [] where (s["type"] as? NSNumber)?.intValue == 4 {
                fs.insert(spaceID(s))
            }
            return Display(identifier: id, current: cur, fullscreen: fs)
        }
    }

    private static func spaceID(_ d: [String: Any]?) -> SpaceID {
        ((d?["ManagedSpaceID"] ?? d?["id64"]) as? NSNumber)?.uint64Value ?? 0
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(Geometry.displayID(screen))?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
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

    static func isFullscreen(_ space: SpaceID) -> Bool {
        displays().contains { $0.fullscreen.contains(space) }
    }

    static func space(of wid: CGWindowID) -> SpaceID? {
        guard let arr = CGSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray) as? [NSNumber],
              let first = arr.first else { return nil }
        return first.uint64Value
    }
}
