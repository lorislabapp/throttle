import Foundation
import GRDB
import OSLog

actor DatabaseManager {
    static let shared = DatabaseManager()
    private var pool: DatabasePool?
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "Database")

    func open() throws -> DatabasePool {
        if let pool = pool { return pool }
        let url = try Self.databaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = Configuration()
        let pool = try DatabasePool(path: url.path, configuration: config)
        try Migrations.register(on: pool)
        self.pool = pool
        logger.info("Opened database at \(url.path, privacy: .public)")
        return pool
    }

    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("com.lorislab.throttle", isDirectory: true)
            .appendingPathComponent("usage.db")
    }

    func close() {
        pool = nil
    }
}
