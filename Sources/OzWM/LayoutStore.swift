import Foundation
import OzCore

/// Every desktop's arrangement on disk (`~/Library/Application Support/Oz/layout.json`), so
/// rows, widths, places and docked windows survive a restart of Oz (or of the Mac, for windows
/// that come back with the same app and title).
enum LayoutStore {
    struct File: Codable {
        /// Desktop (its `Spaces.persistentKey`) -> arrangement.
        var desktops: [String: StripState]
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }()

    static func load() -> [String: StripState] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return file.desktops
    }

    /// The encoded file (sorted keys, so an unchanged layout gives the same bytes).
    static func encode(_ desktops: [String: StripState]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(File(desktops: desktops))
    }

    static func write(_ data: Data) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.info("could not save the layout: \(error)")
        }
    }
}
