@testable import Throttle
import XCTest

final class LocalWorkerModelSelectionTests: XCTestCase {
    func testExactOllamaTagWins() {
        XCTAssertEqual(
            LocalWorkerRouter.installedModelName(
                matching: "qwen3:4b", in: ["throttle-worker:latest", "qwen3:4b"]
            ),
            "qwen3:4b"
        )
    }

    func testUntaggedAliasResolvesLatestTag() {
        XCTAssertEqual(
            LocalWorkerRouter.installedModelName(
                matching: "throttle-worker", in: ["qwen3:4b", "throttle-worker:latest"]
            ),
            "throttle-worker:latest"
        )
    }

    func testMissingModelDoesNotInventASelection() {
        XCTAssertNil(
            LocalWorkerRouter.installedModelName(
                matching: "throttle-worker", in: ["qwen3:4b"]
            )
        )
    }
}
