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

    func testWatcherDetectsNewTopLevelTranscriptInsideExistingProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleWatcherTest_\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let detected = expectation(description: "new top-level transcript detected")
        let transcript = project.appendingPathComponent("session.jsonl")
        let watcher = LiveFileWatcher(rootURL: root) { url in
            if url.standardizedFileURL == transcript.standardizedFileURL {
                detected.fulfill()
            }
        }

        watcher.start()
        defer { watcher.stop() }

        // Let the watcher's serial queue attach its root and project sources before
        // creating the file whose parent-directory event is under test.
        Thread.sleep(forTimeInterval: 0.2)
        try Data("{}\n".utf8).write(to: transcript)

        wait(for: [detected], timeout: 3)
    }

    func testWatcherDoesNotReportSubagentTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleWatcherTest_\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-test-project", isDirectory: true)
        let subagents = project.appendingPathComponent("session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unexpected = expectation(description: "subagent transcript ignored")
        unexpected.isInverted = true
        let watcher = LiveFileWatcher(rootURL: root) { _ in unexpected.fulfill() }

        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        try Data("{}\n".utf8).write(to: subagents.appendingPathComponent("agent-1.jsonl"))

        wait(for: [unexpected], timeout: 0.8)
    }
}
