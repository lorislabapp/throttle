@testable import Throttle
import XCTest

final class BashSandboxTests: XCTestCase {
    func testAllLegacyShellCommandsAreRefused() {
        for command in ["git --version", "git config --global x y", "find . -delete",
                        "cat ~/.ssh/id_rsa", "ls", "swift test", "xcodebuild -list", ""] {
            XCTAssertTrue(BashSandbox.run(command: command).contains("generic shell execution is disabled"))
        }
    }
}
