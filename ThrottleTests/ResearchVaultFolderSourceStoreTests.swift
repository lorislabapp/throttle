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
        XCTAssertEqual(first.urls.map(\.relative), ["evidence.md"])

        source.fingerprints = first.fingerprints
        XCTAssertTrue(
            try ResearchVaultFolderSourceStore.changedFiles(for: source, at: root).urls.isEmpty
        )

        try Data("second and longer".utf8).write(to: markdown, options: .atomic)
        XCTAssertEqual(
            try ResearchVaultFolderSourceStore.changedFiles(for: source, at: root)
                .urls.map(\.relative),
            ["evidence.md"]
        )
    }

    /// A library granted once has to route each file to the project its own path
    /// names, or ninety projects would need ninety permissions against a ceiling
    /// of thirty-two watched folders.
    func testLibraryFolderRoutesFilesToTheProjectInTheirPath() {
        let library = ResearchVaultFolderSource(
            spaceID: "portfolio",
            projectKey: "library",
            name: "GitHub/library",
            bookmark: Data(),
            projectSegment: 1
        )
        XCTAssertEqual(
            library.projectKey(forRelativePath: "audits-and-reviews/throttle/note.md"),
            "throttle"
        )
        XCTAssertEqual(
            library.projectKey(forRelativePath: "market-and-competitors/e-clair/report.md"),
            "e-clair"
        )
        // Too shallow to name a project: the folder's own key stands rather than
        // a guess.
        XCTAssertEqual(library.projectKey(forRelativePath: "loose-note.md"), "library")

        let plain = ResearchVaultFolderSource(
            spaceID: "project:throttle",
            projectKey: "throttle",
            name: "audits-and-reviews/throttle",
            bookmark: Data()
        )
        XCTAssertEqual(plain.projectKey(forRelativePath: "anything/at/all.md"), "throttle")
    }

    /// Seven folders all named `throttle` were seven identical sidebar rows.
    func testDisplayNameCarriesTheParentFolder() {
        XCTAssertEqual(
            ResearchVaultFolderSourceStore.displayName(
                for: URL(fileURLWithPath: "/tmp/library/audits-and-reviews/throttle")
            ),
            "audits-and-reviews/throttle"
        )
    }
}
