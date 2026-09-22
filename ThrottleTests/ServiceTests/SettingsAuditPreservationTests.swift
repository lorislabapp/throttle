@testable import Throttle
import XCTest

final class SettingsAuditPreservationTests: XCTestCase {
    func testExplicitModelReasoningCredentialsAndHooksArePreserved() throws {
        for thinking in [true, false] {
            let original: [String: Any] = [
                "model": "chosen-model", "alwaysThinkingEnabled": thinking,
                "effortLevel": "high", "env": ["SYNTHETIC_KEY": "SYNTHETIC_SECRET"],
                "hooks": ["UserPromptSubmit": [["command": "SYNTHETIC_PRIVATE_COMMAND"]]],
                "permissions": ["allow": ["Read(./src/**)"], "deny": ["Read(./private/**)"]]
            ]
            let data = try JSONSerialization.data(withJSONObject: original)
            let input = try XCTUnwrap(String(data: data, encoding: .utf8))
            let result = SettingsAuditService.audit(currentJSON: input)
            let proposed = try object(result.proposed)
            for key in ["model", "alwaysThinkingEnabled", "effortLevel", "env", "hooks"] {
                XCTAssertEqual(proposed[key] as? NSObject, original[key] as? NSObject, key)
            }
            let permissions = try XCTUnwrap(proposed["permissions"] as? [String: Any])
            XCTAssertEqual(permissions["allow"] as? [String], ["Read(./src/**)"])
            XCTAssertTrue(try XCTUnwrap(permissions["deny"] as? [String]).contains("Read(./private/**)"))
            XCTAssertFalse(result.why.joined().contains("SYNTHETIC_SECRET"))
        }
    }

    func testUnsetModelAndReasoningStayUnset() throws {
        let proposed = try object(SettingsAuditService.audit(currentJSON: "{}").proposed)
        XCTAssertNil(proposed["model"])
        XCTAssertNil(proposed["alwaysThinkingEnabled"])
        XCTAssertNil(proposed["effortLevel"])
    }

    func testUnknownPermissionsShapesAndMalformedJSONRemainByteIdentical() {
        for input in ["broken", "[]", #"{"permissions":null}"#, #"{"permissions":"future"}"#,
                      #"{"permissions":{"deny":true}}"#, #"{"permissions":{"deny":[42]}}"#] {
            let result = SettingsAuditService.audit(currentJSON: input)
            XCTAssertFalse(result.changed)
            XCTAssertEqual(result.proposed, input)
        }
    }

    func testSecondAuditIsIdempotentWithoutReformatting() {
        let first = SettingsAuditService.audit(currentJSON: "{}")
        let input = first.proposed + "\n"
        let second = SettingsAuditService.audit(currentJSON: input)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.proposed, input)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
