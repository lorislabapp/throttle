@testable import Throttle
import XCTest

@MainActor
final class SessionResourceEnvelopeTests: XCTestCase {
    func testCPURequiresThreeConsecutiveHighSamples() {
        let tab = CockpitTab(projectName: "Test", cwd: "/tmp", runtime: .codex)
        tab.recordCPUPercent(300)
        tab.recordCPUPercent(300)
        XCTAssertEqual(tab.resourceState, .healthy)
        tab.recordCPUPercent(300)
        XCTAssertEqual(tab.resourceState, .constrained)
        XCTAssertNotNil(tab.resourceReason)
        tab.recordCPUPercent(1)
        XCTAssertEqual(tab.resourceState, .healthy)
    }

    func testMemoryEnvelopeHasSafeOrdering() {
        let envelope = CockpitTab.resourceEnvelope
        XCTAssertGreaterThan(envelope.warningBytes, 0)
        XCTAssertGreaterThan(envelope.criticalBytes, envelope.warningBytes)
    }
}
