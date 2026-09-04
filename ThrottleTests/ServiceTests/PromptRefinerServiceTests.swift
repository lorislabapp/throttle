@testable import Throttle
import XCTest

private struct PromptRefinerStubProvider: AIProvider {
    let displayName: String
    let kind: AIProviderKind
    let reply: String?
    var isAvailable: Bool { get async { true } }

    struct ProviderFailure: Error {}

    func streamChat(
        messages: [ChatMessage],
        context: ProjectChatContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        let reply = self.reply
        return AsyncThrowingStream { continuation in
            if let reply {
                continuation.yield(reply)
                continuation.finish()
            } else {
                continuation.finish(throwing: ProviderFailure())
            }
        }
    }
}

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
        let metrics = PromptRefinerService.metrics("abcd\nefgh")
        XCTAssertEqual(metrics.lines, 2)
        XCTAssertEqual(metrics.bytes, 9)
        XCTAssertEqual(metrics.approxTokens, 2)   // bytes / 4, floor 1
    }

    func test_metrics_emptyTextIsZeroLinesAndOneToken() {
        let metrics = PromptRefinerService.metrics("")
        XCTAssertEqual(metrics.lines, 0)
        XCTAssertEqual(metrics.bytes, 0)
        XCTAssertEqual(metrics.approxTokens, 1)
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
        let refinement = PromptRefinerService.parse(reply, fallback: "fix scroll")
        XCTAssertEqual(refinement.proposed, "Fix the trackpad scroll in DroppableTerminalView.\nAdd a regression test.")
        XCTAssertEqual(refinement.why, ["named the file", "asked for a test"])
        XCTAssertTrue(refinement.changed)
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
        let refinement = PromptRefinerService.parse("the model rambled", fallback: "fix scroll")
        XCTAssertEqual(refinement.proposed, "fix scroll")
        XCTAssertFalse(refinement.changed)
        XCTAssertTrue(refinement.why.isEmpty)
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
            let prompt = PromptRefinerService.systemPrompt(mode: mode, runtime: .claudeCode, nudge: nil)
            XCTAssertTrue(prompt.contains("===THROTTLE-PROMPT==="), "\(mode) lost the delimiter instruction")
            XCTAssertTrue(prompt.contains("===THROTTLE-WHY==="), "\(mode) lost the why instruction")
        }
    }
    // MARK: - Provider walk

    func test_localOnlyExcludesEveryNetworkProvider() {
        let excluded = PromptRefinerService.excludedProviderKinds(
            tried: [.appleIntelligence],
            forceLocal: true
        )
        XCTAssertTrue(excluded.contains(.appleIntelligence))
        XCTAssertTrue(excluded.contains(.claudeWebSession))
        XCTAssertTrue(excluded.contains(.claudeAPIKey))
        XCTAssertFalse(excluded.contains(.embeddedModel))
    }

    func test_networkAllowedExcludesOnlyProvidersAlreadyTried() {
        let tried: Set<AIProviderKind> = [.appleIntelligence]
        XCTAssertEqual(
            PromptRefinerService.excludedProviderKinds(tried: tried, forceLocal: false),
            tried
        )
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
        let flaky = PromptRefinerStubProvider(displayName: "Flaky", kind: .claudeWebSession, reply: nil)
        let good = PromptRefinerStubProvider(
            displayName: "Apple Intelligence",
            kind: .appleIntelligence,
            reply: wellFormedReply("Fix the scroll in DroppableTerminalView.")
        )
        let refinement = try await PromptRefinerService.refine(
            draft: "fix scroll", mode: .session, runtime: .claudeCode,
            projectName: "Throttle", projectPath: nil,
            resolve: { tried in tried.isEmpty ? flaky : good })

        XCTAssertEqual(refinement.proposed, "Fix the scroll in DroppableTerminalView.")
        XCTAssertEqual(refinement.provider, "Apple Intelligence")
        XCTAssertEqual(refinement.why, ["tightened the scope"])
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
        let silent = PromptRefinerStubProvider(displayName: "Silent", kind: .appleIntelligence, reply: "   ")
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

    func test_refine_rejectsAControlSequenceReturnedByTheProvider() async {
        let unsafeProvider = PromptRefinerStubProvider(
            displayName: "Unsafe",
            kind: .appleIntelligence,
            reply: wellFormedReply("fix \u{1b}[2J scroll")
        )
        do {
            _ = try await PromptRefinerService.refine(
                draft: "fix scroll", mode: .session, runtime: .claudeCode,
                projectName: "Throttle", projectPath: nil,
                resolve: { _ in unsafeProvider })
            XCTFail("expected .controlSequence")
        } catch {
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .controlSequence)
        }
    }

    func test_insertionPayload_thenValidate_isTheExactContractInsertRelieson() throws {
        // What Insert actually does, in order: strip the trailing Enter, then
        // refuse control bytes. A model that emits an ANSI escape must not reach
        // a live PTY even though the payload looks otherwise fine.
        let clean = PromptRefinerService.insertionPayload("refactor auth\n")
        XCTAssertNoThrow(try PromptRefinerService.validate(clean))

        let dirty = PromptRefinerService.insertionPayload("refactor \u{1b}[2J auth\n")
        XCTAssertEqual(dirty, "refactor \u{1b}[2J auth")
        XCTAssertThrowsError(try PromptRefinerService.validate(dirty))
    }

}
