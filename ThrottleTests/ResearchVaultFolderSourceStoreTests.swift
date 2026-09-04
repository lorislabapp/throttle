@testable import Throttle
import XCTest

final class ResearchVaultFolderSourceStoreTests: XCTestCase {
    func testFolderFingerprintDetectsOnlyNewAndRevisedSupportedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "research-folder-source-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("evidence.md")
        let ignored = root.appendingPathComponent("ignored.bin")
        try Data("first".utf8).write(to: markdown)
        try Data([0x00]).write(to: ignored)

        let bookmark = try root.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var source = ResearchVaultFolderSource(
            spaceID: "project:throttle",
            projectKey: "throttle",
            name: root.lastPathComponent,
            bookmark: bookmark
        )
        let first = try ResearchVaultFolderSourceStore.changedFiles(for: source, at: root)
        XCTAssertEqual(first.urls.map(\.lastPathComponent), ["evidence.md"])

        source.fingerprints = first.fingerprints
        XCTAssertTrue(
            try ResearchVaultFolderSourceStore.changedFiles(for: source, at: root).urls.isEmpty
        )

        try Data("second and longer".utf8).write(to: markdown, options: .atomic)
        XCTAssertEqual(
            try ResearchVaultFolderSourceStore.changedFiles(for: source, at: root)
                .urls.map(\.lastPathComponent),
            ["evidence.md"]
        )
    }
}
