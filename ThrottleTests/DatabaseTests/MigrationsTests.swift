import XCTest
import GRDB
@testable import Throttle

final class MigrationsTests: XCTestCase {
    func test_freshDatabase_appliesAllMigrations() throws {
        let dbQueue = try DatabaseQueue() // in-memory
        try Migrations.register(on: dbQueue)
        let tables: [String] = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'grdb_%'
                  AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
        }
        XCTAssertEqual(tables, [
            "calibration",
            "file_state",
            "settings",
            "tokopt_savings",
            "usage_events",
            "usage_snapshots"
        ])
    }

    func test_migrationsAreIdempotent() throws {
        let dbQueue = try DatabaseQueue()
        try Migrations.register(on: dbQueue)
        try Migrations.register(on: dbQueue) // second call should not throw
    }
}
