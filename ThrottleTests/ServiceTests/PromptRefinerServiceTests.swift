@testable import Throttle
import XCTest

/// The refiner proposes; the user applies. These tests pin the invariants that
/// make that promise true: a payload can never carry its own Enter, control
/// bytes never reach a live PTY, and the cost shown is the cost measured.
final class PromptRefinerServiceTests: XCTestCase {

    // MARK: - Insertion payload

    func test_insertionPayload_stripsTrailingNewlinesSoInsertNeverFires() {
        XCTAssertEqual(PromptRefinerService.insertionPayload("fix the scroll\n"), "fix the scroll")
        XCTAssertEqual(PromptRefinerService.insertionPayload("fix the scroll\n\n\n"), "fix the scroll")
        XCTAssertEqual(PromptRefinerService.insertionPayload("a\nb\n"), "a\nb")
    }

    func test_insertionPayload_keepsInteriorNewlines() {
        XCTAssertEqual(PromptRefinerService.insertionPayload("one\ntwo\nthree"), "one\ntwo\nthree")
    }

    // MARK: - Validation

    func test_validate_rejectsEscapeAndNul() {
        XCTAssertThrowsError(try PromptRefinerService.validate("safe \u{1b}[31m red")) { error in
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .controlSequence)
        }
        XCTAssertThrowsError(try PromptRefinerService.validate("safe \u{0} nul")) { error in
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .controlSequence)
        }
    }

    func test_validate_acceptsOrdinaryMultilinePrompt() {
        XCTAssertNoThrow(try PromptRefinerService.validate("line one\nline two\n\ttabbed"))
    }

    func test_validate_rejectsOverOneMebibyte() {
        let big = String(repeating: "a", count: 1024 * 1024 + 1)
        XCTAssertThrowsError(try PromptRefinerService.validate(big)) { error in
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .tooLarge)
        }
    }

    // MARK: - Metrics

    func test_metrics_countsLinesBytesAndApproxTokens() {
        let m = PromptRefinerService.metrics("abcd\nefgh")
        XCTAssertEqual(m.lines, 2)
        XCTAssertEqual(m.bytes, 9)
        XCTAssertEqual(m.approxTokens, 2)   // bytes / 4, floor 1
    }

    func test_metrics_emptyTextIsZeroLinesAndOneToken() {
        let m = PromptRefinerService.metrics("")
        XCTAssertEqual(m.lines, 0)
        XCTAssertEqual(m.bytes, 0)
        XCTAssertEqual(m.approxTokens, 1)
    }

    // MARK: - Reply parsing

    func test_parse_extractsProposalAndWhyBullets() {
        let reply = """
        Here you go.
        ===THROTTLE-PROMPT===
        Fix the trackpad scroll in DroppableTerminalView.
        Add a regression test.
        ===THROTTLE-ENDPROMPT===
        ===THROTTLE-WHY===
        - named the file
        - asked for a test
        """
        let r = PromptRefinerService.parse(reply, fallback: "fix scroll")
        XCTAssertEqual(r.proposed, "Fix the trackpad scroll in DroppableTerminalView.\nAdd a regression test.")
        XCTAssertEqual(r.why, ["named the file", "asked for a test"])
        XCTAssertTrue(r.changed)
    }

    func test_parse_stripsAnOuterCodeFenceTheModelAddedAnyway() {
        let reply = """
        ===THROTTLE-PROMPT===
        ```
        Refactor the auth layer.
        ```
        ===THROTTLE-ENDPROMPT===
        """
        XCTAssertEqual(PromptRefinerService.parse(reply, fallback: "x").proposed, "Refactor the auth layer.")
    }

    func test_parse_keepsInteriorFencesThatBelongToThePrompt() {
        let reply = """
        ===THROTTLE-PROMPT===
        Run this and paste the output:
        ```
        swift test
        ```
        ===THROTTLE-ENDPROMPT===
        """
        let proposed = PromptRefinerService.parse(reply, fallback: "x").proposed
        XCTAssertTrue(proposed.contains("swift test"))
        XCTAssertTrue(proposed.contains("```"))
    }

    func test_parse_withoutDelimitersFallsBackToTheDraftAndReportsNoChange() {
        let r = PromptRefinerService.parse("the model rambled", fallback: "fix scroll")
        XCTAssertEqual(r.proposed, "fix scroll")
        XCTAssertFalse(r.changed)
        XCTAssertTrue(r.why.isEmpty)
    }

    // MARK: - System prompt

    func test_systemPrompt_namesTheRuntimeSoIdiomsDiffer() {
        let claude = PromptRefinerService.systemPrompt(mode: .session, runtime: .claudeCode, nudge: nil)
        let codex = PromptRefinerService.systemPrompt(mode: .session, runtime: .codex, nudge: nil)
        XCTAssertTrue(claude.contains("Claude Code"))
        XCTAssertTrue(codex.contains("Codex"))
        XCTAssertNotEqual(claude, codex)
    }

    func test_systemPrompt_loopModeDemandsATerminationCondition() {
        let loop = PromptRefinerService.systemPrompt(mode: .loop, runtime: .claudeCode, nudge: nil)
        XCTAssertTrue(loop.lowercased().contains("terminat"))
    }

    func test_systemPrompt_carriesTheNudgeInstruction() {
        let nudged = PromptRefinerService.systemPrompt(mode: .session, runtime: .claudeCode, nudge: .shorter)
        XCTAssertTrue(nudged.contains(RefinerNudge.shorter.instruction))
    }

    func test_systemPrompt_alwaysAsksForTheDelimiters() {
        for mode in RefinerMode.allCases {
            let p = PromptRefinerService.systemPrompt(mode: mode, runtime: .claudeCode, nudge: nil)
            XCTAssertTrue(p.contains("===THROTTLE-PROMPT==="), "\(mode) lost the delimiter instruction")
            XCTAssertTrue(p.contains("===THROTTLE-WHY==="), "\(mode) lost the why instruction")
        }
    }
    // MARK: - Provider walk

    /// A provider that either fails or answers, so the fallback can be observed
    /// rather than assumed.
    private struct StubProvider: AIProvider {
        let displayName: String
        let kind: AIProviderKind
        let reply: String?          // nil = throw a recoverable error
        var isAvailable: Bool { get async { true } }

        struct Boom: Error {}

        func streamChat(messages: [ChatMessage],
                        context: ProjectChatContext) async throws -> AsyncThrowingStream<String, Error> {
            let reply = self.reply
            return AsyncThrowingStream { continuation in
                if let reply {
                    continuation.yield(reply)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: Boom())
                }
            }
        }
    }

    private func wellFormedReply(_ prompt: String) -> String {
        [
            "===THROTTLE-PROMPT===",
            prompt,
            "===THROTTLE-ENDPROMPT===",
            "===THROTTLE-WHY===",
            "- tightened the scope"
        ].joined(separator: "\n")
    }

    func test_refine_fallsThroughToTheNextProviderWhenTheFirstFails() async throws {
        let flaky = StubProvider(displayName: "Flaky", kind: .claudeWebSession, reply: nil)
        let good = StubProvider(displayName: "Apple Intelligence", kind: .appleIntelligence,
                                reply: wellFormedReply("Fix the scroll in DroppableTerminalView."))
        let r = try await PromptRefinerService.refine(
            draft: "fix scroll", mode: .session, runtime: .claudeCode,
            projectName: "Throttle", projectPath: nil,
            resolve: { tried in tried.isEmpty ? flaky : good })

        XCTAssertEqual(r.proposed, "Fix the scroll in DroppableTerminalView.")
        XCTAssertEqual(r.provider, "Apple Intelligence")
        XCTAssertEqual(r.why, ["tightened the scope"])
    }

    func test_refine_withNoProviderThrowsNoProvider() async {
        do {
            _ = try await PromptRefinerService.refine(
                draft: "fix scroll", mode: .session, runtime: .claudeCode,
                projectName: "Throttle", projectPath: nil,
                resolve: { _ in nil })
            XCTFail("expected .noProvider")
        } catch {
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .noProvider)
        }
    }

    func test_refine_withAnEmptyAnswerThrowsEmpty() async {
        let silent = StubProvider(displayName: "Silent", kind: .appleIntelligence, reply: "   ")
        do {
            _ = try await PromptRefinerService.refine(
                draft: "fix scroll", mode: .session, runtime: .claudeCode,
                projectName: "Throttle", projectPath: nil,
                resolve: { _ in silent })
            XCTFail("expected .empty")
        } catch {
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .empty)
        }
    }

    func test_refine_rejectsAControlSequenceBeforeSpendingAnything() async {
        do {
            _ = try await PromptRefinerService.refine(
                draft: "fix \u{1b}[2J scroll", mode: .session, runtime: .claudeCode,
                projectName: "Throttle", projectPath: nil,
                resolve: { _ in
                    XCTFail("must not reach a provider")
                    return nil
                })
            XCTFail("expected .controlSequence")
        } catch {
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .controlSequence)
        }
    }

}
