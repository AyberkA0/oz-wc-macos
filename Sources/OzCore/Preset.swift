import CoreGraphics
import Foundation

/// A saved desktop: the apps on it and how their windows were arranged, to open again later
/// (apps launched, windows put back in place). Up to `Preset.limit` are kept.
public struct Preset: Codable, Equatable {
    public struct App: Codable, Equatable {
        public var bundleID: String?
        public var name: String
        /// Where the app was, for apps without a bundle id (or one Launch Services can't find).
        public var path: String?

        public init(bundleID: String?, name: String, path: String?) {
            self.bundleID = bundleID
            self.name = name
            self.path = path
        }
    }

    public static let limit = 5

    public var name: String
    public var created: Date
    /// The windows' arrangement (window ids in it are only hints: they change when apps restart).
    public var desktop: StripState
    /// The desktop's scroll area as fractions of the screen (x, y from the top, width, height).
    public var scrollArea: [Double]?
    /// Apps to open, in the order their windows appear.
    public var apps: [App]

    public init(name: String, created: Date = Date(), desktop: StripState, scrollArea: [Double]?, apps: [App]) {
        self.name = name
        self.created = created
        self.desktop = desktop
        self.scrollArea = scrollArea
        self.apps = apps
    }

    /// A name from the apps: "Chrome, Claude, WhatsApp" or "Chrome, Claude and 3 more".
    public static func defaultName(for apps: [App]) -> String {
        let names = apps.map(\.name)
        guard !names.isEmpty else { return "Empty desktop" }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
    }
}

extension WindowMatcher {
    /// For a preset opened later, when windows are new (new ids, often new titles: a browser's
    /// tab title changes): the same window if it's still there, else a window of the same app
    /// with the same title, else the app's next window not used yet.
    public static func matchLoosely(_ saved: StripState.Window, in candidates: [WindowDescription],
                                    excluding used: Set<WinID>) -> WinID? {
        if let id = match(saved, in: candidates, excluding: used) { return id }
        return candidates.first { !used.contains($0.id) && $0.sameApp(saved) }?.id
    }
}
