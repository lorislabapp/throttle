@testable import Throttle
import XCTest

final class MissionRuntimeServiceTests: XCTestCase {
    func testRoutingUsesCodexOnlyAfterConfirmedLimitInAuto() {
        XCTAssertEqual(MissionRuntimeService.resolve(.automatic, claudeRateLimited: false), .claudeCode)
        XCTAssertEqual(MissionRuntimeService.resolve(.automatic, claudeRateLimited: true), .codex)
        XCTAssertEqual(MissionRuntimeService.resolve(.claudeCode, claudeRateLimited: true), .claudeCode)
        XCTAssertEqual(MissionRuntimeService.resolve(.codex, claudeRateLimited: false), .codex)
        XCTAssertEqual(MissionRuntimeService.resolve(.hybrid, claudeRateLimited: false), .claudeCode)
        XCTAssertEqual(
            MissionRuntimeService.resolveHybrid(claudeRateLimited: false, claudeSessions: 2, codexSessions: 0), .codex
        )
        XCTAssertEqual(
            MissionRuntimeService.resolveHybrid(
                claudeRateLimited: false, claudeSessions: 0, codexSessions: 2
            ),
            .claudeCode
        )
        XCTAssertEqual(
            MissionRuntimeService.resolveHybrid(claudeRateLimited: true, claudeSessions: 0, codexSessions: 4), .codex
        )
    }

    func testHandoffRendersProviderNeutralSafetyPacket() throws {
        let mission = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let handoff = MissionHandoff(
            sourceTabID: UUID(),
            missionID: mission,
            projectName: "Throttle",
            cwd: "/tmp/Throttle",
            source: .claudeCode,
            target: .codex,
            sourceSessionID: "abc-123",
            objective: "Finish the runtime selector.",
            context: MissionHandoffContext(
                completed: "Added the selector.",
                remaining: "Wire persistence.",
                validation: "Unit tests pass.",
                blockers: "None known."
            ),
            git: MissionGitEvidence(
                branch: "feature/runtime",
                head: "deadbee",
                statusLines: [" M Throttle/App.swift", "?? notes.md"]
            )
        )

        let prompt = handoff.prompt
        XCTAssertTrue(prompt.contains("Claude Code → Codex"))
        XCTAssertTrue(prompt.contains("Finish the runtime selector."))
        XCTAssertTrue(prompt.contains("feature/runtime"))
        XCTAssertTrue(prompt.contains("Added the selector."))
        XCTAssertTrue(prompt.contains("Wire persistence."))
        XCTAssertTrue(prompt.contains("Preserve every existing tracked and untracked change"))
        XCTAssertFalse(prompt.contains("transcript content"))
    }

    func testCodexDiscoveryReadsOnlyMatchingSessionMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-codex-tests-\(UUID().uuidString)", isDirectory: true)
        let day = root.appendingPathComponent("2026/08/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrong = day.appendingPathComponent("rollout-wrong.jsonl")
        let right = day.appendingPathComponent("rollout-right.jsonl")
        try #"{"type":"session_meta","payload":{"id":"wrong-id","cwd":"/tmp/Other"}}"#
            .write(to: wrong, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"right-id","cwd":"/tmp/Throttle"}}"#
            .write(to: right, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: right.path)

        let found = MissionRuntimeService.newestCodexSession(
            cwd: "/tmp/Throttle",
            since: .distantPast,
            sessionsRoot: root
        )
        XCTAssertEqual(found?.id, "right-id")
        XCTAssertTrue(MissionRuntimeService.codexSessionExists(
            id: "right-id", cwd: "/tmp/Throttle", sessionsRoot: root
        ))
        XCTAssertFalse(MissionRuntimeService.codexSessionExists(
            id: "wrong-id", cwd: "/tmp/Throttle", sessionsRoot: root
        ))
    }

    func testCodexDiscoveryBuildsOneSharedIndexForMultipleTabs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-codex-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"type":"session_meta","payload":{"id":"one","cwd":"/tmp/One"}}"#
            .write(to: root.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"two","cwd":"/tmp/Two"}}"#
            .write(to: root.appendingPathComponent("two.jsonl"), atomically: true, encoding: .utf8)

        let before = MissionRuntimeService.codexSessionIndexBuildCount
        XCTAssertEqual(
            MissionRuntimeService.newestCodexSession(
                cwd: "/tmp/One", since: .distantPast, sessionsRoot: root
            )?.id,
            "one"
        )
        XCTAssertEqual(
            MissionRuntimeService.newestCodexSession(
                cwd: "/tmp/Two", since: .distantPast, sessionsRoot: root
            )?.id,
            "two"
        )
        XCTAssertEqual(MissionRuntimeService.codexSessionIndexBuildCount - before, 1)
    }

    func testShellQuoteHandlesApostrophesWithoutInterpolation() {
        XCTAssertEqual(MissionRuntimeService.shellQuote("don't $expand"), "'don'\\''t $expand'")
    }

    func testProcessDrainDoesNotDeadlockWhenOutputExceedsPipeCapacity() throws {
        let lines = MissionRuntimeService.runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "100000"],
            cwd: FileManager.default.temporaryDirectory.path,
            outputLimit: 128 * 1024
        )
        XCTAssertEqual(lines?.first, "1")
        XCTAssertGreaterThan(lines?.count ?? 0, 10_000)
        XCTAssertLessThanOrEqual(lines?.joined(separator: "\n").utf8.count ?? 0, 128 * 1024)
    }

    func testProcessRunnerTimesOut() {
        let started = Date()
        let lines = MissionRuntimeService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            cwd: FileManager.default.temporaryDirectory.path,
            timeout: 0.05
        )
        XCTAssertNil(lines)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
