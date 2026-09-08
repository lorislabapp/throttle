import Foundation
@testable import Throttle
import XCTest

@MainActor
final class CockpitUsageGenerationTests: XCTestCase {
    func testStatisticsRejectAResultFromThePreviousNativeIdentityOrProcessGeneration() {
        let model = MultiCockpitModel()
        let nativeID = UUID().uuidString
        let tab = CockpitTab(projectName: "Fixture", cwd: "/fixture", resumeSessionId: nativeID)
        tab.spawnedAt = Date(timeIntervalSince1970: 1_000)
        model.sessions = [tab]
        let original = CockpitSessionProbe(tab)
        var usage = CockpitSessionUsage(id: tab.id)
        usage.financial = .init(eur: 2, tokens: 42, model: "Fable", impact: nil)
        tab.sessionId = UUID().uuidString
        model.applyUsage(usage, originals: [original])
        XCTAssertNil(tab.tokens)
        tab.sessionId = nativeID
        tab.spawnedAt = Date(timeIntervalSince1970: 2_000)
        model.applyUsage(usage, originals: [original])
        XCTAssertNil(tab.tokens)
        model.applyUsage(usage, originals: [CockpitSessionProbe(tab)])
        XCTAssertEqual(tab.tokens, 42)
        XCTAssertEqual(tab.eur, 2)
        XCTAssertEqual(tab.model, "Fable")
    }
}
