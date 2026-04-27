import XCTest
@testable import Throttle

final class UsageExtractorTests: XCTestCase {
    func test_extractsUsageFromAssistantLine() throws {
        let line = #"""
{"type":"assistant","sessionId":"abc-123","timestamp":"2026-04-27T10:00:00Z","message":{"role":"assistant","model":"claude-opus-4-7","content":"hi","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":2000,"cache_read_input_tokens":1000,"service_tier":"standard"}}}
"""#
        let event = try UsageExtractor.extract(fromLine: line)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.sessionId, "abc-123")
        XCTAssertEqual(event?.model, "claude-opus-4-7")
        XCTAssertEqual(event?.inputTokens, 100)
        XCTAssertEqual(event?.outputTokens, 50)
        XCTAssertEqual(event?.cacheCreate, 2000)
        XCTAssertEqual(event?.cacheRead, 1000)
        XCTAssertEqual(event?.serviceTier, "standard")
    }

    func test_returnsNilForUserLine() throws {
        let line = #"{"type":"user","sessionId":"abc-123","message":{"role":"user","content":"hello"}}"#
        let event = try UsageExtractor.extract(fromLine: line)
        XCTAssertNil(event)
    }

    func test_returnsNilForMalformedJson() throws {
        let line = "not json at all"
        let event = try UsageExtractor.extract(fromLine: line)
        XCTAssertNil(event)
    }

    func test_returnsNilForAssistantWithoutUsage() throws {
        let line = #"{"type":"assistant","sessionId":"abc","message":{"role":"assistant","content":"hi"}}"#
        let event = try UsageExtractor.extract(fromLine: line)
        XCTAssertNil(event)
    }
}
