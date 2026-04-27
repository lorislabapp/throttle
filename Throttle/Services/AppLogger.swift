import Foundation
import OSLog

enum AppLogger {
    static let subsystem = "com.lorislab.throttle"
    static let app = Logger(subsystem: subsystem, category: "App")
    static let ui = Logger(subsystem: subsystem, category: "UI")

    /// File where structured logs are also written for the in-app log viewer.
    static let logFileURL: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.lorislab.throttle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("throttle.log")
    }()

    static func appendToFile(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}
