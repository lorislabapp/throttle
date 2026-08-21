@testable import Throttle
import GRDB
import XCTest

final class CodexUsageServiceTests: XCTestCase {
    func testDecodesProviderNativeUsageAndRateLimits() throws {
        let json = #"{"timestamp":"2026-08-16T10:15:30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"cached_input_tokens":300,"output_tokens":90,"reasoning_output_tokens":40,"total_tokens":1330},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":37.5,"window_minutes":300,"resets_at":1786878000},"secondary":{"used_percent":62,"window_minutes":10080,"resets_at":1787356800},"plan_type":"pro"}}}"#

        let snapshot = try XCTUnwrap(CodexUsageService.decodeLine(Data(json.utf8)))
        XCTAssertEqual(snapshot.tokens?.total, 1_330)
        XCTAssertEqual(snapshot.tokens?.cachedInput, 300)
        XCTAssertEqual(snapshot.contextWindow, 258_400)
        XCTAssertEqual(snapshot.primary?.usedPercent, 37.5)
        XCTAssertEqual(snapshot.primary?.windowMinutes, 300)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 62)
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.highestPressure, 0.62)
    }

    func testUnknownOrEmptyEnvelopeFailsClosed() {
        XCTAssertNil(CodexUsageService.decodeLine(Data(#"{"type":"event_msg","payload":{"type":"other"}}"#.utf8)))
        XCTAssertNil(CodexUsageService.decodeLine(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#.utf8)))
    }

    func testLatestFileAndLatestEventWin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-codex-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.jsonl")
        let latest = root.appendingPathComponent("latest.jsonl")
        try #"{"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10}}}}"#
            .write(to: old, atomically: true, encoding: .utf8)
        let latestBody = [
            #"{"timestamp":"2026-08-16T10:01:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":20}}}}"#,
            #"{"timestamp":"2026-08-16T10:02:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":44}}}}"#,
        ].joined(separator: "\n")
        try latestBody.write(to: latest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: latest.path)

        XCTAssertEqual(CodexUsageService.latestSnapshot(sessionsRoot: root)?.primary?.usedPercent, 44)
    }

    func testFreshnessRejectsOldOrFutureObservations() {
        let now = Date(timeIntervalSince1970: 10_000)
        let base = CodexUsageSnapshot(
            sessionID: nil,
            tokens: nil,
            contextWindow: nil,
            primary: .init(kind: .primary, usedPercent: 5, windowMinutes: nil, resetsAt: nil),
            secondary: nil,
            planType: nil,
            observedAt: now.addingTimeInterval(-601)
        )
        XCTAssertFalse(base.isFresh(now: now))
        let future = CodexUsageSnapshot(
            sessionID: nil, tokens: nil, contextWindow: nil,
            primary: base.primary, secondary: nil, planType: nil,
            observedAt: now.addingTimeInterval(120)
        )
        XCTAssertFalse(future.isFresh(now: now))
    }
}

/// The property that matters for `codex_usage` is idempotence. Codex reports a
/// session's CUMULATIVE totals, so an ingester that appended would inflate the
/// bill a little more on every poll — silently, and in the direction that
/// flatters the product. These tests exist to make that failure loud.
final class CodexUsageIngesterTests: XCTestCase {
    private func rollout(_ dir: URL, name: String, total: Int, at iso: String) throws -> URL {
        let json = """
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"token_count","session_id":"\(name)","info":{"total_token_usage":{"input_tokens":\(total - 30),"cached_input_tokens":10,"cache_write_input_tokens":5,"output_tokens":30,"reasoning_output_tokens":12,"total_tokens":\(total)},"model_context_window":121600}}}
        """
        let url = dir.appendingPathComponent("rollout-\(name).jsonl")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Build the YYYY/MM/DD layout Codex writes and that the scanner walks,
    /// returning both the root to point the ingester at and the day directory
    /// the rollouts belong in.
    private func makeRoot(for date: Date) throws -> (root: URL, day: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-test-\(UUID().uuidString)", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        return (root, day)
    }

    @MainActor
    func testRepeatedIngestOfTheSameRolloutDoesNotAccumulate() async throws {
        let now = Date()
        let (root, dayDir) = try makeRoot(for: now)
        defer { try? FileManager.default.removeItem(at: root) }
        let iso = ISO8601DateFormatter().string(from: now)
        _ = try rollout(dayDir, name: "aaaa", total: 1_000, at: iso)

        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        let ingester = CodexUsageIngester(database: db, sessionsRoot: root)

        for _ in 0..<5 { await ingester.ingest(now: now) }

        let rows = try await db.read { try CodexUsageRow.fetchAll($0) }
        XCTAssertEqual(rows.count, 1, "one session must stay one row no matter how often it is read")
        XCTAssertEqual(rows.first?.totalTokens, 1_000, "totals are absolute, never summed")
        XCTAssertEqual(rows.first?.cacheWriteInputTokens, 5)
    }

    @MainActor
    func testAStaleRereadNeverLowersASessionTotal() async throws {
        let now = Date()
        let (root, dayDir) = try makeRoot(for: now)
        defer { try? FileManager.default.removeItem(at: root) }
        let iso = ISO8601DateFormatter().string(from: now)
        let url = try rollout(dayDir, name: "bbbb", total: 5_000, at: iso)

        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        let ingester = CodexUsageIngester(database: db, sessionsRoot: root)
        await ingester.ingest(now: now)

        // Same session id, smaller totals, older observation: a truncated or
        // partially written rollout must not erase what was already recorded.
        try FileManager.default.removeItem(at: url)
        _ = try rollout(dayDir, name: "bbbb", total: 900,
                        at: ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)))
        await ingester.ingest(now: now)

        let rows = try await db.read { try CodexUsageRow.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.totalTokens, 5_000, "a session total must only ever move forward")
    }

    /// Codex reports `total_tokens` equal to the context window, all components
    /// zero, when a session has no usage to describe. Crediting that as spend
    /// inflates the bill with tokens nobody used.
    @MainActor
    func testAWindowSizedTotalWithNoComponentsIsNotStored() async throws {
        let now = Date()
        let (root, dayDir) = try makeRoot(for: now)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
        {"timestamp":"\(ISO8601DateFormatter().string(from: now))","type":"event_msg","payload":{"type":"token_count","session_id":"empty","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":121600},"model_context_window":121600}}}
        """
        try json.write(to: dayDir.appendingPathComponent("rollout-empty.jsonl"),
                       atomically: true, encoding: .utf8)

        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        await CodexUsageIngester(database: db, sessionsRoot: root).ingest(now: now)

        let rows = try await db.read { try CodexUsageRow.fetchAll($0) }
        XCTAssertTrue(rows.isEmpty, "a window-sized total with no components is not usage")
    }

    @MainActor
    func testSessionIDFallsBackToTheRolloutFilenameUUID() {
        let url = URL(fileURLWithPath: "/x/rollout-2026-08-20T16-26-04-01a01f90-94fb-7030-b853-3ca8b5f8c3a9.jsonl")
        XCTAssertEqual(CodexUsageIngester.sessionID(fromRolloutAt: url),
                       "01a01f90-94fb-7030-b853-3ca8b5f8c3a9")
    }

    func testUncachedInputExcludesWhatTheCacheServed() {
        let row = CodexUsageRow(sessionId: "s", observedAt: 0, inputTokens: 7_393_372,
                                cachedInputTokens: 7_169_920, cacheWriteInputTokens: 0,
                                outputTokens: 50_396, reasoningOutputTokens: 39_562,
                                totalTokens: 7_443_768, contextWindow: 121_600)
        XCTAssertEqual(row.uncachedInputTokens, 223_452)
    }
}
