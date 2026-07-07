import XCTest
import GRDB
@testable import Throttle

/// Store tests on an in-memory DB seeded from the real OTLP fixture. Proves
/// idempotent ingestion (replayed OTLP batch = no double-count) and the
/// session→skill read path.
final class TraycerStoreTests: XCTestCase {

    private func decodedFixture() throws -> [TraycerEvent] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "traycer-otlp-logs", withExtension: "json"))
        return TraycerDecoder.decodeLogs(try Data(contentsOf: url))
    }

    private func migratedDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()   // in-memory, matching MigrationsTests
        try Migrations.register(on: dbq)
        return dbq
    }

    func test_insert_thenReplay_isIdempotent() throws {
        let dbq = try migratedDB()
        let events = try decodedFixture()
        XCTAssertFalse(events.isEmpty)

        let first = TraycerStore.insert(events, into: dbq)
        XCTAssertEqual(first, events.count, "all fresh events written")

        let replay = TraycerStore.insert(events, into: dbq)
        XCTAssertEqual(replay, 0, "replayed OTLP batch must write nothing (UNIQUE session_id+sequence)")

        let total = try dbq.read { try TraycerRow.fetchCount($0) }
        XCTAssertEqual(total, events.count)
    }

    func test_skillCounts_findsSessionTag() throws {
        let dbq = try migratedDB()
        _ = TraycerStore.insert(try decodedFixture(), into: dbq)
        // fixture ts is real (2026-07-07); use a wide window to stay date-agnostic
        let counts = try dbq.read { try TraycerStore.skillCounts(in: $0, days: 36_500) }
        XCTAssertTrue(counts.contains { $0.skill == "session-tag" }, "session-tag skill activation recorded")
    }

    func test_events_forSession_orderedBySequence() throws {
        let dbq = try migratedDB()
        let events = try decodedFixture()
        _ = TraycerStore.insert(events, into: dbq)
        let sid = try XCTUnwrap(events.first?.sessionId)
        let rows = try dbq.read { try TraycerStore.events(in: $0, sessionId: sid) }
        XCTAssertEqual(rows.map(\.sequence), rows.map(\.sequence).sorted(), "ascending by sequence")
        XCTAssertFalse(rows.isEmpty)
    }
}
