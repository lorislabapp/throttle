@testable import Throttle
import XCTest

final class CockpitOnboardingTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "onboarding-\(UUID().uuidString)"))
    }

    func testTheCurrentStepFollowsThePathOrder() throws {
        let store = try defaults()
        XCTAssertEqual(CockpitOnboarding.current(in: CockpitOnboarding.completed(
            hasPlan: false, hasSettledDecision: false, defaults: store)), .openProject)
        store.set(true, forKey: "cockpitOnboarding.done.openProject")
        XCTAssertEqual(CockpitOnboarding.current(in: CockpitOnboarding.completed(
            hasPlan: false, hasSettledDecision: false, defaults: store)), .createPlan)
    }

    func testStateOnDiskTicksAStepNobodyRecorded() throws {
        let done = CockpitOnboarding.completed(hasPlan: true, hasSettledDecision: true, defaults: try defaults())
        XCTAssertTrue(done.contains(.createPlan), "a plan that exists means the step is done, whoever made it")
        XCTAssertTrue(done.contains(.settleDecision))
        XCTAssertEqual(CockpitOnboarding.current(in: done), .openProject)
    }
}
