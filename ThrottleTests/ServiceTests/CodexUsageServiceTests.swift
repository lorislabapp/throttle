@testable import Throttle
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
