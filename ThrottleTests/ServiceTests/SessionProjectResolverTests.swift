@testable import Throttle
import XCTest

final class SessionProjectResolverTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let files = FileManager.default
        for folder in ["App/.git", "App/Sources/Deep", "worktrees/feature", "loose"] {
            try files.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "gitdir: \(root.path)/App/.git/worktrees/feature\n"
            .write(to: root.appendingPathComponent("worktrees/feature/.git"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testASubfolderBelongsToItsRepository() {
        XCTAssertEqual(SessionProjectResolver.projectRoot(
            forWorkingDirectory: root.appendingPathComponent("App/Sources/Deep").path, overrides: [:]),
                       root.appendingPathComponent("App").path)
    }

    func testAWorktreeFoldsBackIntoTheRepositoryItCameFrom() {
        XCTAssertEqual(SessionProjectResolver.projectRoot(
            forWorkingDirectory: root.appendingPathComponent("worktrees/feature").path, overrides: [:]),
                       root.appendingPathComponent("App").path)
    }

    func testAManualAttachmentWinsAndAFolderOutsideAnyRepositoryHasNoProject() {
        let loose = root.appendingPathComponent("loose").path
        XCTAssertNil(SessionProjectResolver.projectRoot(forWorkingDirectory: loose, overrides: [:]))
        XCTAssertEqual(SessionProjectResolver.projectRoot(forWorkingDirectory: loose,
                                                          overrides: [loose: "/Projects/Chosen"]),
                       "/Projects/Chosen")
    }

    func testOverridesPersistAndDetach() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "resolver-\(UUID().uuidString)"))
        SessionProjectResolver.setOverride(cwd: "/a/b", projectRoot: "/p", defaults: defaults)
        XCTAssertEqual(SessionProjectResolver.storedOverrides(defaults), ["/a/b": "/p"])
        SessionProjectResolver.setOverride(cwd: "/a/b", projectRoot: nil, defaults: defaults)
        XCTAssertEqual(SessionProjectResolver.storedOverrides(defaults), [:])
    }
}
