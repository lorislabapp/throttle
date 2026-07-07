import XCTest
@testable import Throttle

/// Decoder tests run against a REAL captured OTLP/JSON body (a `session-tag`
/// skill run against Claude Code v2.1.202, fixture `traycer-otlp-logs.json`) —
/// ground truth, no mocks. Proves the join key + skill + tool attribution the
/// Traycer readout depends on.
final class TraycerDecoderTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "traycer-otlp-logs", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func test_decodesRealCapture_sessionIdOnEveryEvent() throws {
        let events = TraycerDecoder.decodeLogs(try fixture())
        XCTAssertFalse(events.isEmpty, "should extract kept events from the real capture")
        XCTAssertTrue(events.allSatisfy { !$0.sessionId.isEmpty }, "session.id (join key) present on all")
        // exactly one session in this capture
        XCTAssertEqual(Set(events.map(\.sessionId)).count, 1)
    }

    func test_skillActivated_carriesSkillName() throws {
        let events = TraycerDecoder.decodeLogs(try fixture())
        let skill = events.first { $0.eventName == "skill_activated" }
        XCTAssertNotNil(skill, "skill_activated event present")
        XCTAssertEqual(skill?.skillName, "session-tag")
    }

    func test_toolResult_forSkillTool() throws {
        let events = TraycerDecoder.decodeLogs(try fixture())
        let tr = events.first { $0.eventName == "tool_result" && $0.toolName == "Skill" }
        XCTAssertNotNil(tr, "Skill tool_result present")
        // skill name parsed out of the tool_input JSON blob
        XCTAssertEqual(tr?.skillName, "session-tag")
    }

    func test_dropsUninterestingEvents() throws {
        let events = TraycerDecoder.decodeLogs(try fixture())
        // api_request / mcp_server_connection / hook_* / user_prompt are not kept
        XCTAssertTrue(events.allSatisfy { TraycerDecoder.kept.contains($0.eventName) })
    }

    func test_failOpen_onGarbage() {
        XCTAssertEqual(TraycerDecoder.decodeLogs(Data("not json".utf8)).count, 0)
        XCTAssertEqual(TraycerDecoder.decodeLogs(Data()).count, 0)
        XCTAssertEqual(TraycerDecoder.decodeLogs(Data("{}".utf8)).count, 0)
    }
}
