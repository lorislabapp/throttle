@testable import Throttle
import XCTest

/// A native picker left open in one project must not block resuming in another,
/// yet must keep blocking every worktree of its own repository.
final class PickerScopeTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-scope-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let files = FileManager.default
        for dir in ["a/.git/worktrees/wt", "a/src", "b/.git", "wt", "loose"] {
            try files.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "gitdir: \(root.path)/a/.git/worktrees/wt\n"
            .write(to: root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: root.appendingPathComponent("a/.git/worktrees/wt/commondir"),
                           atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func scope(_ path: String) -> String {
        CockpitTab.pickerScope(cwd: root.appendingPathComponent(path).path)
    }

    func testWorktreesAndSubdirectoriesShareTheirRepositoryScope() {
        XCTAssertEqual(scope("a"), scope("a/src"))
        XCTAssertEqual(scope("a"), scope("wt"))
    }

    func testOtherRepositoriesAndLooseFoldersAreSeparate() {
        XCTAssertNotEqual(scope("a"), scope("b"))
        XCTAssertNotEqual(scope("a"), scope("loose"))
        XCTAssertEqual(scope("loose"), root.appendingPathComponent("loose").path)
    }
}
