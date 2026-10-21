import Foundation

enum Log {
    static var debugEnabled = false
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/OzWM.log")

    private static let queue = DispatchQueue(label: "oz.log")
    /// Over this the log moves to OzWM.old.log and starts again (also while running: Oz is
    /// meant to stay open for weeks).
    private static let maxSize: UInt64 = 2_000_000
    private static var handle: FileHandle? = open()

    private static func open() -> FileHandle? {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.uint64Value > maxSize {
            rotate()
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }

    private static func rotate() {
        let old = url.deletingLastPathComponent().appendingPathComponent("OzWM.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let data = Data(line.utf8)
            FileHandle.standardError.write(data)
            handle?.write(data)
            if let h = handle, h.offsetInFile > maxSize {
                try? h.close()
                rotate()
                handle = open()
            }
        }
    }

    static func debug(_ message: @autoclosure () -> String) {
        if debugEnabled { info("[debug] " + message()) }
    }
}
