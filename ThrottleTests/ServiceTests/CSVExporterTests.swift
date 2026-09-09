import GRDB
@testable import Throttle
import XCTest

/// The usage CSV is the user's own data on their own disk. It must actually be
/// produced — the previous query named a column the table never had — and it
/// must not carry a credential-shaped string, whatever put it in a path.
@MainActor
final class CSVExporterTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Migrations.register(on: queue)
        try queue.write { database in
            for (index, session) in ["s-attributed", "s-orphan"].enumerated() {
                var event = UsageEvent(id: nil, sessionId: session, timestamp: 1_800_000_000 + Int64(index),
                                       model: "claude-opus-5", inputTokens: 10 + index, outputTokens: 5,
                                       cacheCreate: 1, cacheRead: 2, serviceTier: nil)
                try event.insert(database)
            }
            try database.execute(sql: """
                INSERT INTO file_state (path, last_offset, last_mtime, encoded_project, session_id)
                VALUES (?, 0, 0, ?, ?)
                """, arguments: ["/synthetic/projects/-Users-synthetic-App/s-attributed.jsonl",
                                 "-Users-synthetic-App-sk-ant-api03-SYNTHETICcanary0123456789", "s-attributed"])
        }
        return queue
    }

    func test_exportProducesEveryEventWithItsProjectAndMasksCredentials() throws {
        let url = try XCTUnwrap(CSVExporter.export(database: try database(), to: directory))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "header plus one line per event")
        XCTAssertEqual(lines[0], "timestamp_iso,model,input_tokens,output_tokens,cache_create,cache_read,project")
        XCTAssertTrue(lines[1].hasSuffix(",10,5,1,2,-Users-synthetic-App-[redacted:anthropic-key]"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix(",11,5,1,2,"), "a session without file state exports a blank project")
        XCTAssertFalse(lines.joined().contains("SYNTHETICcanary"))
    }

    func test_exportFailsClosedOnAnUnusableDatabase() throws {
        let empty = try DatabaseQueue()
        XCTAssertNil(CSVExporter.export(database: empty, to: directory), "no schema, no file claimed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
                       "a header-only file must not be left behind to pass for an export")
    }
}
