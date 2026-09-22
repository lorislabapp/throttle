import Darwin
@testable import Throttle
import XCTest

final class ProjectKnowledgeBoundaryTests: XCTestCase {
    func testLinksSpecialFilesAndReplacedRootAreRefused() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("project")
        let outside = container.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try "OUTSIDE_CANARY".write(to: outside.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
        let explorer = ProjectKnowledgeExplorer(projectRoot: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try explorer.read(relativePath: "link/file.md"))
        XCTAssertThrowsError(try explorer.list(relativeDirectory: "link"))
        XCTAssertEqual(
            link(outside.appendingPathComponent("file.md").path, root.appendingPathComponent("hard.md").path), 0
        )
        XCTAssertThrowsError(try explorer.read(relativePath: "hard.md"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.md").path, 0o600), 0)
        XCTAssertThrowsError(try explorer.read(relativePath: "pipe.md"))
        try FileManager.default.moveItem(at: root, to: container.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try explorer.list())
    }

    func testFileAndTraversalBudgetsAreExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: ProjectKnowledgeExplorer.maximumFileBytes + 1)
            .write(to: root.appendingPathComponent("large.md"))
        let explorer = ProjectKnowledgeExplorer(projectRoot: root)
        XCTAssertThrowsError(try explorer.read(relativePath: "large.md"))
        for index in 0..<270 {
            try "needle".write(to: root.appendingPathComponent("file-\(index).md"), atomically: true, encoding: .utf8)
        }
        let listed = try explorer.list()
        XCTAssertTrue(listed.receipt.truncated)
        XCTAssertEqual(listed.text.split(separator: "\n").count, ProjectKnowledgeExplorer.maximumEntries)
        let search = try explorer.search(literal: "absent")
        XCTAssertTrue(search.receipt.truncated)
        XCTAssertLessThanOrEqual(search.receipt.accesses.count, ProjectKnowledgeExplorer.maximumSearchFiles)
        var remaining = 3
        let scan = try explorer.directoryEntries("", remaining: &remaining)
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(scan.truncated)
        XCTAssertLessThanOrEqual(scan.values.count, 3)
    }
}
