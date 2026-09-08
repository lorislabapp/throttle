import Observation
import os
import SwiftUI
@testable import Throttle
import XCTest

@MainActor
final class SessionStateDotTests: XCTestCase {
    func testConstructingDotDoesNotObserveSessionStateInParent() {
        let tab = CockpitTab(projectName: "observation", cwd: "/tmp/observation")
        let invalidated = OSAllocatedUnfairLock(initialState: false)

        withObservationTracking {
            _ = SessionStateDot(tab: tab)
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        // Dormant -> hibernated changes the real state without starting a PTY.
        tab.isHibernated = true
        XCTAssertFalse(invalidated.withLock { $0 })
    }

    func testDotBodyObservesSessionStateForShapeAndTooltip() {
        let tab = CockpitTab(projectName: "observation", cwd: "/tmp/observation")
        let invalidated = OSAllocatedUnfairLock(initialState: false)

        withObservationTracking {
            _ = SessionStateDot(tab: tab).body
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        tab.isHibernated = true
        XCTAssertTrue(invalidated.withLock { $0 })
    }
}
