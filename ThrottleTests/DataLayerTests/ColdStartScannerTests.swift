import XCTest
import GRDB
@testable import Throttle

final class ColdStartScannerTests: XCTestCase {
    func test_scanInsertsEventsAndUpdatesFileState() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleScannerTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Copy fixture into temp dir
        let bundle = Bundle(for: Self.self)
        guard let fixture = bundle.url(forResource: "sample-session", withExtension: "jsonl") else {
            throw XCTSkip("Fixture missing")
        }
        let target = tempDir.appendingPathComponent("session.jsonl")
        try FileManager.default.copyItem(at: fixture, to: target)

        let db = try DatabaseQueue()
        try Migrations.register(on: db)

        let scanner = ColdStartScanner(database: db)
        try scanner.scan(rootDirectory: tempDir)

        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events") ?? 0
        }
        XCTAssertEqual(count, 2)

        // Match the scanner's normalization (handles macOS /private/var symlink).
        let state = try db.read { db in
            try FileState.fetchOne(db, key: target.standardizedFileURL.path)
        }
        XCTAssertNotNil(state)
        XCTAssertGreaterThan(state!.lastOffset, 0)
    }

    func test_scanIsIncrementalOnRerun() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleScannerTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundle = Bundle(for: Self.self)
        guard let fixture = bundle.url(forResource: "sample-session", withExtension: "jsonl") else {
            throw XCTSkip("Fixture missing")
        }
        let target = tempDir.appendingPathComponent("session.jsonl")
        try FileManager.default.copyItem(at: fixture, to: target)

        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        let scanner = ColdStartScanner(database: db)

        try scanner.scan(rootDirectory: tempDir)
        try scanner.scan(rootDirectory: tempDir)

        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events") ?? 0
        }
        XCTAssertEqual(count, 2, "Re-scan must not duplicate events")
    }
}
