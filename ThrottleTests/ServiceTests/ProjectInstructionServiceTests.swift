@testable import Throttle
import XCTest

final class ProjectInstructionServiceTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")
    private var backups = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("repo", isDirectory: true)
        backups = base.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func section(status: ProjectInstructionClaimStatus = .confirmed,
                         text: String = "Run the exact project verifier before review.")
        -> ProjectInstructionSection {
        ProjectInstructionSection(
            id: "verification", revision: 1, title: "Verification",
            statements: [ProjectInstructionStatement(
                id: "verify", text: text, status: status, sourceRefs: ["decision:verification-v1"]
            )]
        )
    }

    func testDiscoveryUsesCodexOverrideAndKeepsNestedProviderPrecedence() throws {
        try write("AGENTS.md", "root agents")
        try write("CLAUDE.md", "root claude")
        try write("Sources/AGENTS.md", "nested agents")
        try write("Sources/AGENTS.override.md", "nested override")
        try write("Sources/Feature/CLAUDE.md", "feature claude")
        let target = root.appendingPathComponent("Sources/Feature")
        let snapshot = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: target)
        XCTAssertNotNil(snapshot.digest)
        XCTAssertEqual(snapshot.targetDirectory, "Sources/Feature")
        XCTAssertEqual(snapshot.sources.filter(\.active).map(\.relativePath), [
            "AGENTS.md", "CLAUDE.md", "Sources/AGENTS.override.md", "Sources/Feature/CLAUDE.md"
        ])
        XCTAssertEqual(snapshot.sources.first { $0.relativePath == "Sources/AGENTS.md" }?.active, false)
    }

    func testReviewedApplyPreservesHumanTextAndSecondReconciliationIsIdempotent() async throws {
        let original = "# Human rules\n\nKeep this paragraph byte-for-byte.\n"
        try write("AGENTS.md", original)
        let snapshot = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)
        let proposal = try XCTUnwrap(ProjectInstructionService.propose(
            projectRoot: root, snapshot: snapshot, targetRelativePath: "AGENTS.md", section: section()
        ))
        let review = ProjectInstructionReview(
            proposalDigest: try XCTUnwrap(proposal.digest), decision: .approved,
            reviewer: "human:reviewer", reviewedAt: Date()
        )
        let reconciler = ProjectInstructionReconciler(backupRoot: backups)
        let receipt = try await reconciler.apply(proposal, review: review, projectRoot: root)
        let applied = try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(applied.hasPrefix(original))
        XCTAssertTrue(applied.contains("BEGIN THROTTLE PROJECT INSTRUCTIONS: verification"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.evidenceDirectory + "/receipt.json"))

        let after = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)
        XCTAssertNil(try ProjectInstructionService.propose(
            projectRoot: root, snapshot: after, targetRelativePath: "AGENTS.md", section: section()
        ))
        try await reconciler.rollback(receipt, projectRoot: root)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8), original)
    }

    func testApplyRequiresExactHumanReview() async throws {
        try write("AGENTS.md", "human\n")
        let snapshot = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)
        let proposal = try XCTUnwrap(ProjectInstructionService.propose(
            projectRoot: root, snapshot: snapshot, targetRelativePath: "AGENTS.md", section: section()
        ))
        let reconciler = ProjectInstructionReconciler(backupRoot: backups)
        for review in [
            ProjectInstructionReview(proposalDigest: "wrong", decision: .approved,
                                     reviewer: "human", reviewedAt: Date()),
            ProjectInstructionReview(proposalDigest: try XCTUnwrap(proposal.digest), decision: .rejected,
                                     reviewer: "human", reviewedAt: Date())
        ] {
            do {
                _ = try await reconciler.apply(proposal, review: review, projectRoot: root)
                XCTFail("unreviewed mutation succeeded")
            } catch {
                XCTAssertEqual(error as? ProjectInstructionError, .reviewRequired)
            }
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8), "human\n")
    }

    func testAnyApplicableInstructionChangeMakesProposalStale() async throws {
        try write("AGENTS.md", "human\n")
        try write("CLAUDE.md", "claude v1\n")
        let snapshot = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)
        let proposal = try XCTUnwrap(ProjectInstructionService.propose(
            projectRoot: root, snapshot: snapshot, targetRelativePath: "AGENTS.md", section: section()
        ))
        try write("CLAUDE.md", "claude v2\n")
        let review = ProjectInstructionReview(
            proposalDigest: try XCTUnwrap(proposal.digest), decision: .approved,
            reviewer: "human", reviewedAt: Date()
        )
        do {
            _ = try await ProjectInstructionReconciler(backupRoot: backups)
                .apply(proposal, review: review, projectRoot: root)
            XCTFail("stale proposal applied")
        } catch {
            XCTAssertEqual(error as? ProjectInstructionError, .staleSnapshot)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8), "human\n")
    }

    func testUnconfirmedSecretAndTaskStateStatementsAreRefused() throws {
        let snapshot = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)
        let unsafe = [
            section(status: .hypothesis),
            section(text: "Use token sk-abcdefghijklmnop1234"),
            section(text: "Read .throttle/log/task.ndjson on startup")
        ]
        for value in unsafe {
            XCTAssertThrowsError(try ProjectInstructionService.propose(
                projectRoot: root, snapshot: snapshot, targetRelativePath: "AGENTS.md", section: value
            ))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
    }

    func testSymlinkedInstructionFileIsRefusedWithoutReadingTarget() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("AGENTS.md"), withDestinationURL: outside
        )
        XCTAssertThrowsError(try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)) {
            XCTAssertEqual($0 as? ProjectInstructionError, .unsafeSource(root.appendingPathComponent("AGENTS.md").path))
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
    }

    func testSymlinkedRuleDirectoryCannotHideExternalInstructions() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-rules", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "external rule".write(to: outside.appendingPathComponent("rule.md"),
                                  atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".claude/rules"), withDestinationURL: outside
        )
        XCTAssertThrowsError(try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root))
    }

    func testRollbackRefusesToOverwriteAConcurrentHumanEdit() async throws {
        try write("AGENTS.md", "human v1\n")
        let snapshot = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)
        let proposal = try XCTUnwrap(ProjectInstructionService.propose(
            projectRoot: root, snapshot: snapshot, targetRelativePath: "AGENTS.md", section: section()
        ))
        let review = ProjectInstructionReview(
            proposalDigest: try XCTUnwrap(proposal.digest), decision: .approved,
            reviewer: "human", reviewedAt: Date()
        )
        let reconciler = ProjectInstructionReconciler(backupRoot: backups)
        let receipt = try await reconciler.apply(proposal, review: review, projectRoot: root)
        try write("AGENTS.md", "human v2\n")
        do {
            try await reconciler.rollback(receipt, projectRoot: root)
            XCTFail("rollback overwrote a concurrent edit")
        } catch {
            XCTAssertEqual(error as? ProjectInstructionError, .rollbackWouldOverwrite)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8), "human v2\n")
    }

    func testRollbackRefusesAForgedBackupPath() async throws {
        try write("AGENTS.md", "human v1\n")
        let snapshot = try ProjectInstructionService.capture(projectRoot: root, targetDirectory: root)
        let proposal = try XCTUnwrap(ProjectInstructionService.propose(
            projectRoot: root,
            snapshot: snapshot,
            targetRelativePath: "AGENTS.md",
            section: section()
        ))
        let review = ProjectInstructionReview(
            proposalDigest: try XCTUnwrap(proposal.digest),
            decision: .approved,
            reviewer: "human",
            reviewedAt: Date()
        )
        let reconciler = ProjectInstructionReconciler(backupRoot: backups)
        var receipt = try await reconciler.apply(proposal, review: review, projectRoot: root)
        let applied = try Data(contentsOf: root.appendingPathComponent("AGENTS.md"))
        let forgedBackup = root.deletingLastPathComponent().appendingPathComponent("forged.bin")
        let forgedData = Data("attacker-selected instructions".utf8)
        try forgedData.write(to: forgedBackup)
        receipt.backupPath = forgedBackup.path
        receipt.previousContentDigest = ProjectInstructionService.digest(forgedData)

        do {
            try await reconciler.rollback(receipt, projectRoot: root)
            XCTFail("forged rollback receipt was accepted")
        } catch {
            XCTAssertEqual(error as? ProjectInstructionError, .evidenceFailure)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("AGENTS.md")), applied)
    }
}
