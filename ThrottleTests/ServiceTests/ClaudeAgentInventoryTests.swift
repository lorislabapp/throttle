@testable import Throttle
import XCTest

final class ClaudeAgentInventoryTests: XCTestCase {
    private let payload = """
    [
      {"id":"46160a8d","cwd":"/repo","kind":"background","startedAt":1783860946311,
       "sessionId":"46160a8d-8a23-47e7-9971-121a5ee1fe5e","name":"Vault setup","state":"failed"},
      {"id":"c1","cwd":"/repo","kind":"interactive","startedAt":1783860946311,"sessionId":"c1-uuid"},
      {"id":"cloud1","kind":"cloud","state":"running","name":"Thread"},
      {"missing":"id"}
    ]
    """

    func testMalformedRowsAreDroppedNotFatal() {
        let sessions = ClaudeAgentInventory.parse(Data(payload.utf8))
        XCTAssertEqual(sessions.map(\.id), ["46160a8d", "c1", "cloud1"])
    }

    func testCloudAndBackgroundCountAsOutsideInteractiveDoesNot() {
        let sessions = ClaudeAgentInventory.parse(Data(payload.utf8))
        XCTAssertEqual(sessions.filter(\.isBackgroundOrCloud).map(\.id), ["46160a8d", "cloud1"])
    }

    func testFailedAndBlockedAskForAttention() {
        let sessions = ClaudeAgentInventory.parse(Data(payload.utf8))
        XCTAssertTrue(sessions[0].needsAttention)
        XCTAssertFalse(sessions[2].needsAttention)
    }

    func testStartedAtIsReadInMilliseconds() {
        let sessions = ClaudeAgentInventory.parse(Data(payload.utf8))
        XCTAssertEqual(sessions[0].startedAt?.timeIntervalSince1970 ?? 0, 1_783_860_946.311, accuracy: 0.01)
    }

    func testOnlyTheCLIsOwnIdentifierShapeReachesAShellLine() {
        XCTAssertEqual(OutsideAgentsCard.safeIdentifier("46160a8d"), "46160a8d")
        XCTAssertNil(OutsideAgentsCard.safeIdentifier("a; rm -rf /"))
        XCTAssertNil(OutsideAgentsCard.safeIdentifier(""))
    }
}
