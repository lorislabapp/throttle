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
            capabilities: MissionCapabilityCompatibility(
                source: MissionCapabilityInventory(skills: ["swift-review", "shared"], mcpServers: ["mailpilot"]),
                target: MissionCapabilityInventory(skills: ["shared"], mcpServers: [])
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
        XCTAssertTrue(prompt.contains("Skills available on both providers: shared"))
        XCTAssertTrue(prompt.contains("Source skills unavailable on target: swift-review"))
        XCTAssertTrue(prompt.contains("Source MCP servers unavailable on target: mailpilot"))
        XCTAssertFalse(prompt.contains("transcript content"))
    }

    func testCapabilityCompatibilityReadsNamesOnlyAcrossProviders() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-capabilities-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [
            home.appendingPathComponent(".claude/skills/shared"),
            home.appendingPathComponent(".claude/skills/claude-only"),
            home.appendingPathComponent(".codex/skills/shared"),
            cwd.appendingPathComponent(".codex/skills/project-codex")
        ] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try "---\nname: test\n---".write(
                to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        try #"{"mcpServers":{"shared-mcp":{"env":{"TOKEN":"SECRET"}},"claude-only":{"command":"secret-command"}}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true
        )
        try "[mcp_servers.shared-mcp]\ncommand = \"do-not-copy\"\n\n[mcp_servers.codex-only]\nurl = \"https://secret.invalid\""
            .write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)

        let compatibility = MissionRuntimeService.capabilityCompatibility(
            source: .claudeCode, target: .codex, cwd: cwd.path, home: home
        )
        XCTAssertEqual(compatibility.sharedSkills, ["shared"])
        XCTAssertEqual(compatibility.missingSkillsOnTarget, ["claude-only"])
        XCTAssertEqual(compatibility.sharedMCPServers, ["shared-mcp"])
        XCTAssertEqual(compatibility.missingMCPServersOnTarget, ["claude-only"])
        let description = MissionHandoff(
            sourceTabID: UUID(), missionID: UUID(), projectName: "Project", cwd: cwd.path,
            source: .claudeCode, target: .codex, sourceSessionID: nil, objective: "Continue",
            capabilities: compatibility, git: .unavailable
        ).prompt
        XCTAssertFalse(description.contains("SECRET"))
        XCTAssertFalse(description.contains("secret-command"))
        XCTAssertFalse(description.contains("secret.invalid"))
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

    func testHandoffPromptForcesFreshTargetSession() {
        XCTAssertTrue(MissionRuntimeService.shouldDiscoverResumeSession(initialPrompt: nil))
        XCTAssertTrue(MissionRuntimeService.shouldDiscoverResumeSession(initialPrompt: "  "))
        XCTAssertFalse(MissionRuntimeService.shouldDiscoverResumeSession(initialPrompt: "continue here"))
    }

    func testClaudeIdentityValidationAndPortableContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-claude-context-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/tmp/Project With Space"
        let project = root.appendingPathComponent(
            MultiCockpitModel.claudeProjectDirName(cwd), isDirectory: true
        )
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = [
            #"{"type":"user","message":{"role":"user","content":"Fix the Dock reopen bug"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret"},{"type":"text","text":"I found the activation-policy race."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"PRIVATE TOOL OUTPUT"}]}}"#
        ].joined(separator: "\n")
        try transcript.write(
            to: project.appendingPathComponent("claude-id.jsonl"), atomically: true, encoding: .utf8
        )

        XCTAssertTrue(MissionRuntimeService.claudeSessionExists(
            id: "claude-id", cwd: cwd, projectsRoot: root
        ))
        XCTAssertFalse(MissionRuntimeService.claudeSessionExists(
            id: "codex-id", cwd: cwd, projectsRoot: root
        ))
        let context = MissionRuntimeService.portableConversationContext(
            runtime: .claudeCode, sessionID: "claude-id", cwd: cwd, claudeProjectsRoot: root
        )
        XCTAssertTrue(context.contains("USER: Fix the Dock reopen bug"))
        XCTAssertTrue(context.contains("ASSISTANT: I found the activation-policy race."))
        XCTAssertFalse(context.contains("secret"))
        XCTAssertFalse(context.contains("PRIVATE TOOL OUTPUT"))
    }

    func testCodexPortableContextExcludesToolsAndSystemMaterial() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-codex-context-\(UUID().uuidString)", isDirectory: true)
        let day = root.appendingPathComponent("2026/08/17", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = [
            #"{"type":"session_meta","payload":{"id":"codex-id","cwd":"/tmp/Throttle"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"SYSTEM SECRET"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Keep my context"}]}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"PRIVATE COMMAND"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The handoff is ready."}]}}"#
        ].joined(separator: "\n")
        try transcript.write(
            to: day.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8
        )

        let context = MissionRuntimeService.portableConversationContext(
            runtime: .codex, sessionID: "codex-id", cwd: "/tmp/Throttle", codexSessionsRoot: root
        )
        XCTAssertTrue(context.contains("USER: Keep my context"))
        XCTAssertTrue(context.contains("ASSISTANT: The handoff is ready."))
        XCTAssertFalse(context.contains("SYSTEM SECRET"))
        XCTAssertFalse(context.contains("PRIVATE COMMAND"))
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

/// The encoding has to match Claude Code byte for byte: a transcript written to a
/// directory claude does not read comes back as "No conversation found with
/// session ID" — an offload that reports success and silently loses the session.
final class ClaudeProjectDirNameTests: XCTestCase {
    func testAccentedPathKeepsTheLetterAndDashesTheAccent() {
        // Decomposed, the way the macOS filesystem hands it over: E + U+0301.
        let decomposed = "/root/offload/E\u{0301}clair"
        XCTAssertEqual(MultiCockpitModel.claudeProjectDirName(decomposed),
                       "-root-offload-E-clair")
    }

    func testPrecomposedAccentBecomesASingleDash() {
        // One scalar, so one dash — and claude, walking the same scalars, agrees.
        XCTAssertEqual(MultiCockpitModel.claudeProjectDirName("/a/\u{00C9}clair"),
                       "-a--clair")
    }

    func testSpacesAndDotsCollapseLikeBefore() {
        XCTAssertEqual(MultiCockpitModel.claudeProjectDirName("/Users/k/Opnsens Prod"),
                       "-Users-k-Opnsens-Prod")
        XCTAssertEqual(MultiCockpitModel.claudeProjectDirName("/a/b.c"), "-a-b-c")
    }
}

/// Codex names rollouts by timestamp and files them by date, so the path cannot be
/// derived from the session id — it has to be found, or an offloaded Codex tab
/// ships nothing and reports success anyway.
final class CodexRolloutLocatorTests: XCTestCase {
    func testFindsTheRolloutCarryingTheSessionID() throws {
        let now = Date()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-loc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let p = cal.dateComponents([.year, .month, .day], from: now)
        let dir = root
            .appendingPathComponent(String(format: "%04d", p.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", p.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", p.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "01a01f90-94fb-7030-b853-3ca8b5f8c3a9"
        let name = "rollout-2026-08-20T16-26-04-\(id).jsonl"
        try "{}".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let found = MissionRuntimeService.codexRolloutURL(id: id, now: now, sessionsRoot: root)
        XCTAssertEqual(found?.lastPathComponent, name)
    }

    func testUnknownSessionFindsNothing() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-empty-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(MissionRuntimeService.codexRolloutURL(id: "does-not-exist", sessionsRoot: root))
    }
    /// The hand-written newline scan replaces `Data.split(separator:)`, which the
    /// stable toolchain rejects as ambiguous however the separator is spelled.
    /// Since only CI can compile that path, the behaviour is pinned here.
    func testNewlineScanMatchesSplitSemantics() {
        func chunks(_ text: String) -> [String] {
            MissionRuntimeService.newlineSeparatedChunksForTesting(Data(text.utf8))
                .compactMap { String(bytes: $0, encoding: .utf8) }
        }
        XCTAssertEqual(chunks("a\nb\nc"), ["a", "b", "c"])
        XCTAssertEqual(chunks("a\nb\n"), ["a", "b"], "a trailing newline yields no empty line")
        XCTAssertEqual(chunks("\n\na"), ["a"], "empty lines are omitted, as split did")
        XCTAssertEqual(chunks(""), [])
        XCTAssertEqual(chunks("solo"), ["solo"])
    }

}
