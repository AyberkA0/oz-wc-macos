import Foundation

enum Log {
    static var debugEnabled = false
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/OzWM.log")

    private static let queue = DispatchQueue(label: "oz.log")
    private static var handle: FileHandle? = {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 2_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            handle?.write(line.data(using: .utf8)!)
        }
    }

    static func debug(_ message: @autoclosure () -> String) {
        if debugEnabled { info("[debug] " + message()) }
    }
}
