@testable import Throttle
import XCTest

final class CodexProgressServiceTests: XCTestCase {
    func testProjectsLifecycleWithoutCopyingMessageContent() throws {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec_command","arguments":"secret"}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
        ].map { Data($0.utf8) }
        let result = try XCTUnwrap(CodexProgressService.decode(lines))
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.title, "Ready for review")
        XCTAssertEqual(result.commandsCompleted, 1)
        XCTAssertFalse(result.title.contains("secret"))
    }

    func testRequestUserInputBecomesActionRequired() throws {
        let line = Data(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"request_user_input"}}"#.utf8)
        let result = try XCTUnwrap(CodexProgressService.decode([line]))
        XCTAssertEqual(result.phase, .waiting)
        XCTAssertEqual(result.title, "Action required")
    }

    func testFailureWinsAfterWork() throws {
        let lines = [
            Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8),
            Data(#"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#.utf8),
        ]
        XCTAssertEqual(CodexProgressService.decode(lines)?.phase, .failed)
    }
}
