@testable import Throttle
import XCTest

final class ResearchVaultSpaceStoreTests: XCTestCase {
    func testExistingProjectKeysMigrateOneToOneBesidePortfolio() throws {
        let suite = "ResearchVaultSpaceStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try ResearchVaultSpaceStore.saveProjectKeys(["throttle", "cheatcode"], defaults: defaults)
        let spaces = ResearchVaultSpaceStore.load(defaults: defaults)

        XCTAssertEqual(spaces.first, .portfolio)
        XCTAssertEqual(spaces.filter { $0.kind == .project }.map(\.projectKeys), [
            ["cheatcode"], ["throttle"]
        ])
        XCTAssertEqual(Set(spaces.map(\.id)).count, spaces.count)
    }
}
