@testable import Throttle
import XCTest

final class ProjectKnowledgeExplorerTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-explorer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha\nbeta needle\ngamma\n".write(
            to: root.appendingPathComponent("docs/one.md"),
            atomically: true,
            encoding: .utf8
        )
        try "needle again\n".write(
            to: root.appendingPathComponent("two.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadReturnsBoundedTextAndAnExactDigestReceipt() throws {
        let result = try ProjectKnowledgeExplorer(projectRoot: root).read(
            relativePath: "docs/one.md",
            maximumCharacters: 1_000,
            now: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(result.text, "alpha\nbeta needle\ngamma\n")
        XCTAssertEqual(result.receipt.operation, .read)
        XCTAssertEqual(result.receipt.accesses.map(\.path), ["docs/one.md"])
        XCTAssertEqual(result.receipt.accesses.first?.sha256.count, 64)
        XCTAssertFalse(result.receipt.truncated)
        XCTAssertTrue(result.rendered().contains("RECEIPT"))
    }

    func testEscapeAndSymlinkedFileAreRefused() throws {
        let explorer = ProjectKnowledgeExplorer(projectRoot: root)
        XCTAssertThrowsError(try explorer.read(relativePath: "../outside.md")) {
            XCTAssertEqual($0 as? ProjectKnowledgeError, .invalidRequest)
        }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("docs/link.md"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try explorer.read(relativePath: "docs/link.md")) {
            XCTAssertEqual($0 as? ProjectKnowledgeError, .symlinkRefused)
        }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("docs/inside-link.md"),
            withDestinationURL: root.appendingPathComponent("docs/one.md")
        )
        XCTAssertThrowsError(try explorer.read(relativePath: "docs/inside-link.md")) {
            XCTAssertEqual($0 as? ProjectKnowledgeError, .symlinkRefused)
        }
    }

    func testSensitivePathsAreRefusedAndCredentialShapesAreRedacted() throws {
        try "TOKEN=sk-ant-api03-SYNTHETICcanary0123456789\n".write(
            to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8
        )
        let explorer = ProjectKnowledgeExplorer(projectRoot: root)
        XCTAssertThrowsError(try explorer.read(relativePath: ".env")) {
            XCTAssertEqual($0 as? ProjectKnowledgeError, .sensitivePathRefused)
        }

        try "let fixture = \"sk-ant-api03-SYNTHETICcanary0123456789\"\n".write(
            to: root.appendingPathComponent("docs/canary.swift"), atomically: true, encoding: .utf8
        )
        let read = try explorer.read(relativePath: "docs/canary.swift", maximumCharacters: 1_000)
        XCTAssertFalse(read.text.contains("SYNTHETICcanary"))
        XCTAssertEqual(read.receipt.redactions, ["anthropic-key"])

        let search = try explorer.search(literal: "SYNTHETICcanary")
        XCTAssertFalse(search.text.contains("SYNTHETICcanary"))
        XCTAssertEqual(search.receipt.redactions, ["anthropic-key"])
    }

    func testSearchMarksIncompleteWhenATextCandidateCannotBeInspected() throws {
        try Data([0xFF, 0xFE, 0xFD]).write(to: root.appendingPathComponent("docs/not-utf8.md"))
        let result = try ProjectKnowledgeExplorer(projectRoot: root).search(literal: "absent")
        XCTAssertTrue(result.receipt.truncated)
        XCTAssertEqual(result.text, "(no exact matches)")
    }

    func testExactSearchNamesEveryFileItRead() throws {
        let result = try ProjectKnowledgeExplorer(projectRoot: root).search(
            literal: "needle"
        )
        XCTAssertTrue(result.text.contains("docs/one.md:2"))
        XCTAssertTrue(result.text.contains("two.swift:1"))
        XCTAssertEqual(Set(result.receipt.accesses.map(\.path)), ["docs/one.md", "two.swift"])
        XCTAssertTrue(result.receipt.accesses.allSatisfy { $0.sha256.count == 64 })
    }

    func testMCPReadGrantCannotExploreASiblingProject() {
        let other = root.deletingLastPathComponent()
            .appendingPathComponent("knowledge-sibling", isDirectory: true)
        let now = Date()
        let grant = PlanMCPAuthority(
            projectRoots: [root],
            author: "codex:t1",
            operations: [.read],
            taskID: "T1",
            missionID: UUID(),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let response = ProjectKnowledgeMCP.call(
            ["project": other.path, "operation": "list"],
            authority: .success(grant)
        )
        XCTAssertTrue(response.contains("only act on its own project"), response)
    }

    func testMCPRequiresAnExplicitGrantAndIsAdvertisedThroughTheSharedRouter() {
        let response = ProjectKnowledgeMCP.call(
            ["project": root.path, "operation": "list"],
            authority: .success(nil)
        )
        XCTAssertTrue(response.contains("requires an explicit read grant"), response)
        XCTAssertTrue(PlanMCPTools.advertisedSchemas.contains {
            $0["name"] as? String == "throttle_project_explore"
        })
    }
}
