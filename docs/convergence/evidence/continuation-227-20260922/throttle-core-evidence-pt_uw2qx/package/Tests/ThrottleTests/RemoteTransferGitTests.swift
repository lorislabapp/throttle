@testable import Throttle
import XCTest

final class RemoteTransferGitTests: XCTestCase {
    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("throttle-git-'literal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try RemoteTransferGit.git(["init", "--quiet"], cwd: root.path)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@localhost"),
                             ("core.hooksPath", "/dev/null"), ("commit.gpgsign", "false"),
                             ("core.fsmonitor", "false"), ("core.attributesFile", "/dev/null")] {
            _ = try RemoteTransferGit.git(["config", key, value], cwd: root.path)
        }
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("delete me\n".utf8).write(to: root.appendingPathComponent("removed.txt"))
        try Data("ignored.cache\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try RemoteTransferGit.git(["add", "-A"], cwd: root.path)
        _ = try RemoteTransferGit.git(["commit", "--quiet", "-m", "fixture"], cwd: root.path)
        return root
    }

    func testBundleCarriesStagedUnstagedUntrackedAndDeletedFilesWithoutChangingIndex() throws {
        let root = try repository()
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        _ = try RemoteTransferGit.git(["add", "tracked.txt"], cwd: root.path)
        try Data("staged and unstaged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("new work\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        try Data("excluded fixture\n".utf8).write(to: root.appendingPathComponent("ignored.cache"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let beforeHead = try RemoteTransferGit.git(["rev-parse", "HEAD"], cwd: root.path)
        let id = UUID().uuidString.lowercased()
        let snapshot = try RemoteTransferGit.snapshot(cwd: root.path, transferID: id,
                                                      directory: root.appendingPathComponent(".git/transfer-fixture"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), beforeIndex)
        XCTAssertEqual(try RemoteTransferGit.git(["rev-parse", "HEAD"], cwd: root.path), beforeHead)
        let clone = root.appendingPathComponent(".git/clone-fixture")
        _ = try RemoteTransferGit.git(["clone", "--quiet", snapshot.bundle.path, clone.path], cwd: root.path)
        let ref = "refs/throttle/transfers/\(id)/outbound"
        _ = try RemoteTransferGit.git(["fetch", "--quiet", snapshot.bundle.path, "\(ref):\(ref)"], cwd: clone.path)
        _ = try RemoteTransferGit.git(["checkout", "--quiet", "--detach", ref], cwd: clone.path)
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("tracked.txt"), encoding: .utf8),
                       "staged and unstaged\n")
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("new.txt"), encoding: .utf8), "new work\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.appendingPathComponent("removed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.appendingPathComponent("ignored.cache").path))
        XCTAssertEqual(try RemoteTransferGit.git(["rev-parse", "HEAD^{tree}"], cwd: clone.path), snapshot.tree)
        XCTAssertEqual(try RemoteTransferJournal.sha256(snapshot.bundle), snapshot.sha256)
    }

    func testIgnoredFilesRequireTheExplicitIncludeListAndMissingEntriesFail() throws {
        let root = try repository()
        try Data("explicit fixture\n".utf8).write(to: root.appendingPathComponent("ignored.cache"))
        try Data("ignored.cache\n".utf8).write(to: root.appendingPathComponent(".throttleinclude"))
        let id = UUID().uuidString.lowercased()
        _ = try RemoteTransferGit.snapshot(cwd: root.path, transferID: id,
                                           directory: root.appendingPathComponent(".git/include-fixture"))
        let ref = "refs/throttle/transfers/\(id)/outbound"
        XCTAssertEqual(try RemoteTransferGit.git(["show", "\(ref):ignored.cache"], cwd: root.path), "explicit fixture")
        try Data("missing-required-file\n".utf8).write(to: root.appendingPathComponent(".throttleinclude"))
        XCTAssertThrowsError(try RemoteTransferGit.snapshot(cwd: root.path, transferID: UUID().uuidString.lowercased(),
                directory: root.appendingPathComponent(".git/missing-fixture")))
    }
    func testSubdirectoryRefusesTransferBeforeCreatingArtifacts() throws {
        let root = try repository()
        let subdirectory = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let artifacts = root.appendingPathComponent(".git/refused-transfer")
        XCTAssertThrowsError(try RemoteTransferGit.snapshot(
            cwd: subdirectory.path, transferID: UUID().uuidString.lowercased(), directory: artifacts))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.path))
    }

}
