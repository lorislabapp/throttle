@testable import Throttle
import XCTest

final class PeerControlAdmissionTests: XCTestCase {
    func testMirrorConsentDoesNotPermitTerminalControl() {
        let admission = PeerControlAdmission()
        XCTAssertFalse(admission.permitsCurrentConnection)
        let listener = admission.start(controlEnabled: false)
        XCTAssertNil(admission.ticket(for: listener))
    }

    func testRevocationRefusesQueuedFramesEvenAfterNewConsent() throws {
        let admission = PeerControlAdmission()
        let listener = admission.start(controlEnabled: true)
        let old = try XCTUnwrap(admission.ticket(for: listener))
        XCTAssertTrue(admission.permits(old))
        admission.setControlEnabled(false)
        XCTAssertFalse(admission.permits(old))
        XCTAssertNil(admission.ticket(for: listener))
        admission.setControlEnabled(true)
        XCTAssertFalse(admission.permits(old))
        XCTAssertTrue(admission.permits(try XCTUnwrap(admission.ticket(for: listener))))
    }

    func testListenerReplacementRefusesFramesFromOldConnection() throws {
        let admission = PeerControlAdmission()
        let old = admission.start(controlEnabled: true)
        let ticket = try XCTUnwrap(admission.ticket(for: old))
        admission.stop()
        XCTAssertFalse(admission.permits(ticket))
        let new = admission.start(controlEnabled: true)
        XCTAssertNil(admission.ticket(for: old))
        XCTAssertNotNil(admission.ticket(for: new))
        XCTAssertFalse(admission.permits(ticket))
    }
}
