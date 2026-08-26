# Cockpit Prompt Refiner Implementation Plan (M1 + M2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a right sidebar to the Throttle cockpit with two segments, Audit and Refiner, where the Refiner turns a rough draft into a prompt worth sending to the agent in the active tab and applies it only on an explicit user action.

**Architecture:** A pure `enum` service builds the prompt, walks the existing `AIProviderRegistry` chain and parses the reply; an `@Observable` model outside the view tree holds the draft, the proposal and the screen state; a SwiftUI pane renders direction 1c's full-column focus screens; a segment host replaces the direct `CockpitAuditInspector()` call in the cockpit root. Insertion goes through SwiftTerm bracketed paste and never appends a newline.

**Tech Stack:** Swift 6, SwiftUI, AppKit, SwiftTerm, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-26-cockpit-prompt-refiner-design.md`

## Global Constraints

- Swift 6 strict concurrency. `ThrottleTests` builds with `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` (`project.yml:331`) — a warning in test code fails the build.
- The Xcode project is generated. After creating any new source file, run `xcodegen generate` before building, or the file is not in the target.
- New code must not add SwiftLint violations: the repo pins `.swiftlint-baseline.json`, and CI has failed on lint before the build step ever runs.
- **The macOS test bundle is app-hosted** (`TEST_HOST: $(BUILT_PRODUCTS_DIR)/Throttle.app/...`, `project.yml:333`). Running it launches a Throttle app host. The user has a standing rule that Throttle must not be installed or relaunched without their explicit OK each time, and a prior session had to cancel a test run for this reason. **Ask before running any `xcodebuild test` against the `Throttle` scheme.** Write the tests in every task regardless; batch the run at a moment the user approves.
- Nothing in M1 may send text to an agent without an explicit user action. The default output pastes without a newline.
- Accent tokens: `#0071E3` for filled primaries, `#0A84FF` for accent text and icons, `#FF9F0A` for warnings.

Build command (safe, no app host):

```bash
xcodebuild build -project Throttle.xcodeproj -scheme Throttle \
  -configuration Debug -destination 'platform=macOS' \
  -disableAutomaticPackageResolution -skipPackagePluginValidation \
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Test command (**needs user approval first** — launches an app host):

```bash
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS' \
  -only-testing:ThrottleTests/PromptRefinerServiceTests \
  -disableAutomaticPackageResolution -skipPackagePluginValidation \
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

---

## File Structure

| File | Responsibility |
|---|---|
| `Throttle/Services/PromptRefinerService.swift` (create) | pure `enum`: modes, system prompts, validation, metrics, provider walk, reply parsing |
| `Throttle/Services/PromptRefinerModel.swift` (create) | `@Observable` state outside the view tree: screen, mode, draft, proposal, history, settings |
| `Throttle/UI/Cockpit/PromptRefinerPane.swift` (create) | direction 1c focus screens |
| `Throttle/UI/Cockpit/CockpitSidebar.swift` (create) | Audit / Refiner segment host |
| `Throttle/UI/Cockpit/DroppableTerminalView.swift` (modify) | expose bracketed paste for Throttle-composed text |
| `Throttle/UI/Cockpit/MultiCockpitModel.swift` (modify) | `insertDraft(_:)` on the active tab |
| `Throttle/UI/Cockpit/MultiCockpitRoot.swift` (modify) | host the sidebar; seed a refined mission objective |
| `ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift` (create) | service tests |
| `ThrottleTests/ServiceTests/PromptRefinerModelTests.swift` (create) | model/state tests |

---

### Task 1: PromptRefinerService — modes, validation, metrics

**Files:**
- Create: `Throttle/Services/PromptRefinerService.swift`
- Test: `ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `RefinerMode`, `RefinerNudge`, `PromptRefinerService.Refinement`, `PromptRefinerService.RefinerError`, `PromptRefinerService.PromptMetrics`, `PromptRefinerService.validate(_:)`, `PromptRefinerService.metrics(_:)`, `PromptRefinerService.insertionPayload(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the build command from Global Constraints.
Expected: FAIL — "cannot find 'PromptRefinerService' in scope".

- [ ] **Step 3: Write the implementation**

Create `Throttle/Services/PromptRefinerService.swift`:

```swift
import Foundation

/// What the user is refining. The target decides both the system prompt and
/// where an accepted proposal lands.
enum RefinerMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case session, mission, loop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "Session"
        case .mission: return "Mission"
        case .loop:    return "/loop"
        }
    }

    var help: String {
        switch self {
        case .session: return "Refine the next instruction for the running session"
        case .mission: return "Refine a long autonomous mission objective"
        case .loop:    return "Refine a /loop objective — it must be able to self-terminate"
        }
    }
}

/// A one-word re-refinement asked for from the result screen.
enum RefinerNudge: String, CaseIterable, Identifiable, Sendable {
    case shorter, precise, constraints

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shorter:     return "shorter"
        case .precise:     return "precise"
        case .constraints: return "+ constraints"
        }
    }

    var instruction: String {
        switch self {
        case .shorter:     return "Cut the length hard. Keep every constraint and every file path."
        case .precise:     return "Tighten the scope: name the exact files, symbols and commands."
        case .constraints: return "Add explicit guardrails: what must not change, and what evidence proves it worked."
        }
    }
}

/// Proposes an improved prompt. It never writes a file, never touches a PTY and
/// never sends anything — the caller applies, the user fires.
enum PromptRefinerService {

    struct Refinement: Sendable, Equatable {
        let proposed: String
        let why: [String]
        let changed: Bool
        var provider: String = ""
    }

    struct PromptMetrics: Sendable, Equatable {
        let lines: Int
        let bytes: Int
        let approxTokens: Int
    }

    enum RefinerError: LocalizedError, Equatable {
        case noProvider
        case empty
        case controlSequence
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "No AI provider available — sign in to claude.ai or add an API key in the Assistant tab."
            case .empty:
                return "The model returned nothing usable."
            case .controlSequence:
                return "The text contains a control sequence and was not applied."
            case .tooLarge:
                return "Prompts are limited to 1 MiB."
            }
        }
    }

    /// Same ceiling as a reviewed terminal paste — a live PTY is the consumer in
    /// both cases.
    static let maximumBytes = 1024 * 1024

    // MARK: - Payload safety

    /// Text ready to paste into a terminal. Trailing newlines are stripped: a
    /// newline reaching the TUI IS the Enter key, and the whole promise of this
    /// feature is that only the user presses it.
    static func insertionPayload(_ text: String) -> String {
        var out = text
        while out.hasSuffix("\n") || out.hasSuffix("\r") { out.removeLast() }
        return out
    }

    /// Hard invariants, kept from `ReviewedPasteService`: no NUL, no ESC, 1 MiB.
    /// The confirmation ALERT is deliberately not reused — the result screen
    /// already shows the whole text plus its line/byte/token cost, which is more
    /// review than a truncated preview.
    static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else { throw RefinerError.tooLarge }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x1b }) else {
            throw RefinerError.controlSequence
        }
    }

    /// The cost evidence shown before applying. `bytes / 4` is the same
    /// approximation the reviewed-paste sheet already shows, so two surfaces
    /// never quote the user two different numbers for one payload.
    static func metrics(_ text: String) -> PromptMetrics {
        let bytes = text.utf8.count
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return PromptMetrics(lines: lines, bytes: bytes, approxTokens: max(1, bytes / 4))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `xcodegen generate`, then the build command. Then request approval for the test command and run it.
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Throttle/Services/PromptRefinerService.swift ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift
git commit -m "[throttle] feat: the refiner's payload can never carry its own Enter"
```

---

### Task 2: PromptRefinerService — system prompts, provider walk, parsing

**Files:**
- Modify: `Throttle/Services/PromptRefinerService.swift`
- Test: `ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift`

**Interfaces:**
- Consumes: `RefinerMode`, `RefinerNudge`, `Refinement`, `RefinerError` (Task 1); `AIProviderRegistry.shared.resolveActive()`, `.firstAvailable(excluding:)`, `AIProvider.streamChat(messages:context:)`, `ChatMessage`, `ProjectChatContext`, `AgentRuntime`.
- Produces: `PromptRefinerService.parse(_:fallback:)`, `.systemPrompt(mode:runtime:nudge:)`, `.ProviderResolver`, `.registryResolver`, `.refine(draft:mode:runtime:nudge:projectName:projectPath:resolve:)`.

- [ ] **Step 1: Write the failing tests**

Append to `ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift`, inside the class:

```swift
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

```

- [ ] **Step 2: Run tests to verify they fail**

Run the build command.
Expected: FAIL — "type 'PromptRefinerService' has no member 'parse'".

- [ ] **Step 3: Write the implementation**

Append inside `enum PromptRefinerService` in `Throttle/Services/PromptRefinerService.swift`:

```swift
    // MARK: - Wire format

    // Unique delimiters, NOT ``` — prompts routinely contain code fences.
    private static let promptStart = "===THROTTLE-PROMPT==="
    private static let promptEnd = "===THROTTLE-ENDPROMPT==="
    private static let whyMark = "===THROTTLE-WHY==="

    static func systemPrompt(mode: RefinerMode, runtime: AgentRuntime, nudge: RefinerNudge?) -> String {
        let agent: String
        let idiom: String
        switch runtime {
        case .claudeCode:
            agent = "Claude Code"
            idiom = """
            - Claude Code reads the repository itself. Point at files and symbols; never paste file contents it can open.
            - Slash commands and `@file` references are idiomatic. Prefer `@path/to/file.swift` over "the file called…".
            """
        case .codex:
            agent = "Codex"
            idiom = """
            - Codex works best from an explicit, ordered task list with the acceptance check stated up front.
            - Spell out the commands to run; do not assume it will infer the toolchain.
            """
        case .local, .terminal:
            agent = "a local shell"
            idiom = "- There is no coding agent on this tab. Keep the instruction plain and self-contained."
        }

        let job: String
        switch mode {
        case .session:
            job = """
            You are rewriting ONE next instruction for a coding agent that is already running in the user's repository, mid-session.
            It already has context. Do not re-explain the project.
            """
        case .mission:
            job = """
            You are rewriting the OBJECTIVE of a long autonomous mission that will be handed to a fresh agent with no conversation history.
            State the goal, the constraints, and the evidence that proves it is done.
            """
        case .loop:
            job = """
            You are rewriting the objective of a REPEATING loop that will run unattended, over and over.
            It MUST contain an explicit termination condition — what makes the loop stop — and it must be safe to run when nothing has changed.
            """
        }

        return """
        \(job)

        Target agent: \(agent).
        \(idiom)

        Rules:
        - Preserve the user's intent exactly. Never invent a requirement they did not ask for.
        - Prefer naming real files, symbols and commands over description.
        - Ask for the evidence that would prove the work is correct.
        - Plain prose or a short list. No preamble, no sign-off.
        \(nudge.map { "- \($0.instruction)" } ?? "")

        Answer in EXACTLY this shape and nothing else:

        \(promptStart)
        <the rewritten prompt>
        \(promptEnd)
        \(whyMark)
        - <what you changed, 4-8 words>
        - <what you changed, 4-8 words>
        """
    }

    static func parse(_ text: String, fallback: String) -> Refinement {
        var proposed = fallback
        if let s = text.range(of: promptStart), let e = text.range(of: promptEnd),
           s.upperBound < e.lowerBound {
            proposed = stripOuterFence(String(text[s.upperBound..<e.lowerBound])
                .trimmingCharacters(in: .newlines))
        }
        var why: [String] = []
        if let w = text.range(of: whyMark) {
            why = text[w.upperBound...].split(separator: "\n").compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("-") || t.hasPrefix("•") || t.hasPrefix("*") else { return nil }
                let body = String(t.drop(while: { "-•* ".contains($0) }))
                return body.isEmpty ? nil : body
            }
        }
        let changed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            != fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return Refinement(proposed: proposed, why: why, changed: changed)
    }

    /// Some models fence the whole answer despite the instruction. Strip only a
    /// leading fence line plus its matching trailing one — fences that belong to
    /// the prompt itself sit in the interior and survive.
    private static func stripOuterFence(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return s }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: - Provider walk

    /// Walk the active provider, then the next available ones, so a flaky
    /// claude.ai session falls through instead of failing the refinement.
    /// Injection seam: given the kinds already attempted, return the next
    /// provider to try. The default walks the registry; tests substitute stubs,
    /// which is the only way to prove the fallback actually falls back.
    typealias ProviderResolver = @Sendable (Set<AIProviderKind>) async -> (any AIProvider)?

    static let registryResolver: ProviderResolver = { tried in
        tried.isEmpty
            ? await AIProviderRegistry.shared.resolveActive()
            : await AIProviderRegistry.shared.firstAvailable(excluding: tried)
    }

    static func refine(
        draft: String,
        mode: RefinerMode,
        runtime: AgentRuntime,
        nudge: RefinerNudge? = nil,
        projectName: String,
        projectPath: String?,
        resolve: ProviderResolver = PromptRefinerService.registryResolver
    ) async throws -> Refinement {
        try validate(draft)

        let user = """
        \(systemPrompt(mode: mode, runtime: runtime, nudge: nudge))

        The user's draft:
        ----- BEGIN -----
        \(draft)
        ----- END -----
        """

        let ctx = ProjectChatContext(
            projectName: projectName, projectPath: projectPath,
            claudeMd: nil, settingsJSON: nil, weeklyTokens: 0,
            modelSplit: [], hookScripts: [:], mcpServers: [], costEUR: 0
        )
        let messages = [ChatMessage(role: .user, content: user)]

        var tried = Set<AIProviderKind>()
        var lastError: Error = RefinerError.noProvider
        for _ in 0..<3 {
            guard let provider = await resolve(tried) else { break }
            tried.insert(provider.kind)
            do {
                var full = ""
                let stream = try await provider.streamChat(messages: messages, context: ctx)
                for try await chunk in stream { full += chunk }
                guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RefinerError.empty
                }
                var r = parse(full, fallback: draft)
                r.provider = provider.displayName
                return r
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the build command, then the approved test command.
Expected: 18 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Throttle/Services/PromptRefinerService.swift ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift
git commit -m "[throttle] feat: one refiner, three targets, and an idiom per runtime"
```

---

### Task 3: PromptRefinerModel — screens, history and settings

**Files:**
- Create: `Throttle/Services/PromptRefinerModel.swift`
- Test: `ThrottleTests/ServiceTests/PromptRefinerModelTests.swift`

**Interfaces:**
- Consumes: `RefinerMode`, `PromptRefinerService.Refinement` (Tasks 1-2).
- Produces: `PromptRefinerModel.shared`, `.screen`, `.mode`, `.draft`, `.proposal`, `.history`, `.peeking`, `.pendingMissionObjective`, `.beginCompose()`, `.accept(_:)`, `.fail(_:)`, `.reset()`, `PromptRefinerModel.Screen`, `PromptRefinerModel.HistoryEntry`, `RefinerOutput`, `RefinerRationale`, `RefinerSettings`.

- [ ] **Step 1: Write the failing tests**

Create `ThrottleTests/ServiceTests/PromptRefinerModelTests.swift`:

```swift
@testable import Throttle
import XCTest

/// The model lives outside the view tree so switching sidebar segments never
/// loses a typed draft. These tests pin that promise and the screen flow.
@MainActor
final class PromptRefinerModelTests: XCTestCase {

    private func freshModel() -> PromptRefinerModel {
        let m = PromptRefinerModel()
        m.reset()
        return m
    }

    func test_beginCompose_movesHomeToComposeAndKeepsTheDraft() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.beginCompose()
        XCTAssertEqual(m.screen, .compose)
        XCTAssertEqual(m.draft, "fix scroll")
    }

    func test_accept_movesToResultAndRecordsHistory() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.screen = .loading
        m.accept(PromptRefinerService.Refinement(
            proposed: "Fix the trackpad scroll in DroppableTerminalView.",
            why: ["named the file"], changed: true, provider: "Apple Intelligence"))
        XCTAssertEqual(m.screen, .result)
        XCTAssertEqual(m.history.count, 1)
        XCTAssertEqual(m.history[0].draft, "fix scroll")
        XCTAssertEqual(m.history[0].proposed, "Fix the trackpad scroll in DroppableTerminalView.")
    }

    func test_appliedScreenKeepsTheResultVisibleInsteadOfDroppingHome() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.accept(PromptRefinerService.Refinement(
            proposed: "Fix the scroll.", why: [], changed: true, provider: "p"))
        m.screen = .applied
        // The proposal survives, so the confirmation sits under the text the
        // user just applied rather than replacing it with the home list.
        XCTAssertEqual(m.proposal?.proposed, "Fix the scroll.")
        XCTAssertEqual(m.screen, .applied)
    }

    func test_fail_keepsTheDraftSoNothingTypedIsLost() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.screen = .loading
        m.fail("No AI provider available.")
        XCTAssertEqual(m.screen, .error("No AI provider available."))
        XCTAssertEqual(m.draft, "fix scroll")
    }

    func test_history_isCappedAndNewestFirst() {
        let m = freshModel()
        for i in 0..<(PromptRefinerModel.historyLimit + 5) {
            m.draft = "draft \(i)"
            m.accept(PromptRefinerService.Refinement(
                proposed: "proposed \(i)", why: [], changed: true, provider: "p"))
        }
        XCTAssertEqual(m.history.count, PromptRefinerModel.historyLimit)
        XCTAssertEqual(m.history.first?.draft, "draft \(PromptRefinerModel.historyLimit + 4)")
    }

    func test_historyTitle_isTheFirstLineTrimmed() {
        let m = freshModel()
        m.draft = "make the scroll work\nand add a test"
        m.accept(PromptRefinerService.Refinement(proposed: "x", why: [], changed: true, provider: "p"))
        XCTAssertEqual(m.history[0].title, "make the scroll work")
    }

    // MARK: - Rationale visibility setting

    func test_rationaleVisibility_missionOnlyIsTheDefaultBehaviour() {
        XCTAssertFalse(RefinerRationale.missionOnly.isVisible(for: .session))
        XCTAssertTrue(RefinerRationale.missionOnly.isVisible(for: .mission))
        XCTAssertTrue(RefinerRationale.missionOnly.isVisible(for: .loop))
    }

    func test_rationaleVisibility_alwaysAndNeverIgnoreTheMode() {
        for mode in RefinerMode.allCases {
            XCTAssertTrue(RefinerRationale.always.isVisible(for: mode))
            XCTAssertFalse(RefinerRationale.never.isVisible(for: mode))
        }
    }

    func test_rationaleVisibility_collapsedStartsHiddenButRemainsReachable() {
        XCTAssertFalse(RefinerRationale.collapsed.isVisible(for: .mission))
        XCTAssertTrue(RefinerRationale.collapsed.isExpandable)
        XCTAssertFalse(RefinerRationale.never.isExpandable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the build command.
Expected: FAIL — "cannot find 'PromptRefinerModel' in scope".

- [ ] **Step 3: Write the implementation**

Create `Throttle/Services/PromptRefinerModel.swift`:

```swift
import Foundation

/// What Insert does with an accepted proposal.
enum RefinerOutput: String, CaseIterable, Identifiable, Sendable {
    case insert, copy, send

    var id: String { rawValue }

    var label: String {
        switch self {
        case .insert: return "Insert without sending"
        case .copy:   return "Copy to clipboard"
        case .send:   return "Send immediately"
        }
    }
}

/// When the "why it changed" bullets are shown.
enum RefinerRationale: String, CaseIterable, Identifiable, Sendable {
    case always, collapsed, missionOnly, never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always:      return "Always show"
        case .collapsed:   return "Collapsed"
        case .missionOnly: return "Only for missions and loops"
        case .never:       return "Never"
        }
    }

    /// Session is the fast path; mission and loop are the paths where the user
    /// is about to commit to a long run and should see the reasoning first.
    func isVisible(for mode: RefinerMode) -> Bool {
        switch self {
        case .always:      return true
        case .never:       return false
        case .collapsed:   return false
        case .missionOnly: return mode != .session
        }
    }

    /// Whether a disclosure control is offered at all.
    var isExpandable: Bool { self != .never }
}

/// Persisted refiner preferences. Model choice and quality deliberately reuse
/// `AIProviderRegistry` rather than duplicating a second set of controls.
enum RefinerSettings {
    private static let outputKey = "throttleRefinerOutput"
    private static let forceLocalKey = "throttleRefinerForceLocal"
    private static let rationaleKey = "throttleRefinerRationale"

    static var output: RefinerOutput {
        get { RefinerOutput(rawValue: UserDefaults.standard.string(forKey: outputKey) ?? "") ?? .insert }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: outputKey) }
    }

    /// Defaults ON: paying frontier tokens to save frontier tokens is the trap
    /// this product refuses elsewhere.
    static var forceLocal: Bool {
        get { UserDefaults.standard.object(forKey: forceLocalKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: forceLocalKey) }
    }

    static var rationale: RefinerRationale {
        get { RefinerRationale(rawValue: UserDefaults.standard.string(forKey: rationaleKey) ?? "") ?? .missionOnly }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: rationaleKey) }
    }
}

/// Refiner state. It lives OUTSIDE the view tree on purpose: the sidebar renders
/// one segment at a time (the Audit segment owns a polling task that must not
/// run off-screen), so a pane can be torn down at any moment. Holding the draft
/// here means switching segments never loses typed text.
@MainActor
@Observable
final class PromptRefinerModel {
    static let shared = PromptRefinerModel()

    static let historyLimit = 20

    enum Screen: Equatable {
        case home
        case compose
        case loading
        case error(String)
        case result
        /// Direction 1c keeps the result on screen after Insert, with a
        /// "you press Return" confirmation, instead of dropping the user home.
        case applied
    }

    struct HistoryEntry: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let mode: RefinerMode
        let draft: String
        let proposed: String
        let at: Date
    }

    var screen: Screen = .home
    var mode: RefinerMode = .session
    var draft = ""
    var proposal: PromptRefinerService.Refinement?
    var history: [HistoryEntry] = []

    /// True only while the result screen's compare control is held down.
    var peeking = false

    /// A refined mission objective waiting to seed the next handoff sheet.
    var pendingMissionObjective: String?

    func beginCompose() {
        screen = .compose
    }

    func accept(_ refinement: PromptRefinerService.Refinement) {
        proposal = refinement
        screen = .result
        let title = draft
            .split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "Untitled draft"
        history.insert(HistoryEntry(title: title, mode: mode, draft: draft,
                                    proposed: refinement.proposed, at: Date()),
                       at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    func fail(_ message: String) {
        screen = .error(message)
    }

    func reopen(_ entry: HistoryEntry) {
        mode = entry.mode
        draft = entry.draft
        proposal = nil
        screen = .compose
    }

    func reset() {
        screen = .home
        draft = ""
        proposal = nil
        peeking = false
        history = []
        pendingMissionObjective = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `xcodegen generate`, the build command, then the approved test command.
Expected: 9 new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Throttle/Services/PromptRefinerModel.swift ThrottleTests/ServiceTests/PromptRefinerModelTests.swift
git commit -m "[throttle] feat: the draft outlives the pane that renders it"
```

---

### Task 4: Insertion path — bracketed paste that never presses Enter

**Files:**
- Modify: `Throttle/UI/Cockpit/DroppableTerminalView.swift` (add a method near the existing `sendProgrammatic(txt:)` at line 198)
- Modify: `Throttle/UI/Cockpit/MultiCockpitModel.swift` (add to `MultiCockpitModel`, near `active`)
- Test: `ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift`

**Interfaces:**
- Consumes: `PromptRefinerService.insertionPayload(_:)`, `.validate(_:)` (Task 1); `DroppableTerminalView.paste(_:trailingSpace:)` (private, same file, line 821).
- Produces: `DroppableTerminalView.insertComposedText(_:)`, `MultiCockpitModel.insertDraft(_:) -> Bool`.

- [ ] **Step 1: Write the failing test**

Append inside `PromptRefinerServiceTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

It will PASS already (both helpers exist from Task 1). That is expected — this
test documents the contract the next step depends on. Confirm it passes, then
implement the callers.

- [ ] **Step 3: Write the implementation**

In `Throttle/UI/Cockpit/DroppableTerminalView.swift`, add directly after
`sendProgrammatic(txt:)` (which ends at line 202):

```swift
    /// Paste a Throttle-composed prompt into the foreground program. Bracketed
    /// paste when the TUI supports it, so a multi-line prompt arrives as ONE
    /// paste instead of N Enter presses. No newline is ever appended — the user
    /// presses Return.
    func insertComposedText(_ text: String) {
        programmaticDepth += 1
        defer { programmaticDepth -= 1 }
        paste(text)
    }
```

In `Throttle/UI/Cockpit/MultiCockpitModel.swift`, add to `MultiCockpitModel`:

```swift
    /// Put a refined prompt in front of the active agent WITHOUT sending it.
    /// Returns false when there is no live terminal or the payload carries a
    /// control sequence — the caller surfaces that instead of failing silently.
    @discardableResult
    func insertDraft(_ text: String) -> Bool {
        guard let term = active?.terminal as? DroppableTerminalView else { return false }
        let payload = PromptRefinerService.insertionPayload(text)
        guard !payload.isEmpty, (try? PromptRefinerService.validate(payload)) != nil else { return false }
        term.insertComposedText(payload)
        return true
    }
```

- [ ] **Step 4: Run the build and the test**

Run the build command, then the approved test command.
Expected: build succeeds, all `PromptRefinerServiceTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Throttle/UI/Cockpit/DroppableTerminalView.swift Throttle/UI/Cockpit/MultiCockpitModel.swift ThrottleTests/ServiceTests/PromptRefinerServiceTests.swift
git commit -m "[throttle] feat: a refined prompt arrives as one paste, never as N returns"
```

---

### Task 5: PromptRefinerPane — the six focus screens

**Files:**
- Create: `Throttle/UI/Cockpit/PromptRefinerPane.swift`

**Interfaces:**
- Consumes: `PromptRefinerModel.shared`, `RefinerMode`, `RefinerNudge`, `RefinerSettings`, `PromptRefinerService.refine(...)`, `.metrics(_:)`, `MultiCockpitModel.shared.insertDraft(_:)`, `MultiCockpitModel.shared.active` (for `runtime`, `projectName`, `cwd`).
- Produces: `PromptRefinerPane` (a `View` taking no arguments).

This task has no unit test — it is presentation. Verify by building and looking
at each state via the model. Direction 1c is the visual contract; re-read §3 of
the spec before writing it.

- [ ] **Step 1: Write the pane**

Create `Throttle/UI/Cockpit/PromptRefinerPane.swift`:

```swift
import AppKit
import SwiftUI

/// Direction 1c "Takeover": the refiner is a stack of full-column focus screens,
/// not panels sharing a 280pt column. One screen owns the column at a time, so a
/// 15-line draft never scrolls and the terminal is never covered.
struct PromptRefinerPane: View {
    @State private var model = PromptRefinerModel.shared
    @State private var cockpit = MultiCockpitModel.shared
    @State private var task: Task<Void, Never>?
    @State private var startedAt = Date()
    @State private var now = Date()
    @State private var copied = false
    @State private var whyExpanded = false

    private let hair = Color.primary.opacity(0.10)
    private let accentText = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 1.0)
    private let accentFill = Color(red: 0.0, green: 0x71 / 255, blue: 0xE3 / 255)
    private let warn = Color(red: 1.0, green: 0x9F / 255, blue: 0x0A / 255)

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.screen {
            case .home:            home
            case .compose:         compose
            case .loading:         loading
            case .error(let msg):  errorScreen(msg)
            case .result, .applied: result
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(tick) { now = $0 }
        .onDisappear { task?.cancel() }
    }

    // MARK: - Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                dl("TARGET")
                Picker("", selection: $model.mode) {
                    ForEach(RefinerMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(model.mode.help)

                Button {
                    model.beginCompose()
                } label: {
                    Text("New draft")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accentText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(accentFill.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(accentText.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                }
                .buttonStyle(.plain)
                .help("Opens a full-column composer — the terminal stays visible")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            Rectangle().fill(hair).frame(height: 1)

            if model.history.isEmpty {
                Text("Nothing refined yet. A draft you refine shows up here, ready to reopen.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                dl("HISTORY").padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { entry in
                            Button { model.reopen(entry) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(entry.mode.label) · \(PromptRefinerService.metrics(entry.proposed).lines) ln")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Reopen this refinement as a new draft")
                            Rectangle().fill(hair).frame(height: 1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Drafting takes the whole column. Your terminal is never covered.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: - Compose

    private var compose: some View {
        VStack(alignment: .leading, spacing: 0) {
            backBar(title: "\(model.mode.label) · DRAFT") { model.screen = .home }
            TextEditor(text: $model.draft)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
                .padding(.horizontal, 14).padding(.top, 12)
                .frame(maxHeight: .infinity)

            HStack {
                Text(metricsLabel(model.draft))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { startRefine(nudge: nil) } label: {
                    Text("Refine ⌘⏎")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(accentFill, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("One call to the refiner model — the cost is shown before you apply")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: - Loading

    private var loading: some View {
        VStack(spacing: 10) {
            Spacer()
            ForEach([0.92, 0.78, 0.85], id: \.self) { w in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 240 * w, height: 9)
            }
            Text("\(model.proposal?.provider ?? "refining") · \(Int(now.timeIntervalSince(startedAt)))s")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Button("Cancel") {
                task?.cancel()
                model.screen = .compose
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(accentText)
            .padding(10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Error

    private func errorScreen(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text("△ \(message)")
                .font(.system(size: 12))
                .foregroundStyle(warn)
                .multilineTextAlignment(.center)
            Text("Your draft is kept. Add a provider, then refine again.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to draft") { model.screen = .compose }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accentText)
                .padding(10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 0) {
            backBar(title: model.proposal?.provider ?? "") { model.screen = .compose }

            ScrollView {
                Text(shownText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.peeking ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
            .padding(.horizontal, 14).padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                peekButton
                deltaStrip
                rationale
                chips
            }
            .padding(.horizontal, 14).padding(.top, 8)

            Rectangle().fill(hair).frame(height: 1).padding(.top, 8)
            footer.padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private var shownText: String {
        model.peeking ? model.draft : (model.proposal?.proposed ?? "")
    }

    private var peekButton: some View {
        Text(model.peeking ? "your original draft" : "hold to compare")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(model.peeking ? Color.primary : accentText)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.peeking = true }
                    .onEnded { _ in model.peeking = false }
            )
            .help("Press and hold to see your original draft in the same spot")
    }

    private var deltaStrip: some View {
        let before = PromptRefinerService.metrics(model.draft)
        let after = PromptRefinerService.metrics(model.proposal?.proposed ?? "")
        return HStack {
            delta("LN", before.lines, after.lines)
            Spacer()
            delta("B", before.bytes, after.bytes)
            Spacer()
            delta("TOK", before.approxTokens, after.approxTokens)
        }
    }

    private func delta(_ label: String, _ before: Int, _ after: Int) -> some View {
        let d = after - before
        return HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(d >= 0 ? "+\(d)" : "\(d)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(label): \(before) before, \(after) after")
    }

    @ViewBuilder
    private var rationale: some View {
        let why = model.proposal?.why ?? []
        if !why.isEmpty {
            let setting = RefinerSettings.rationale
            let shown = setting.isVisible(for: model.mode) || whyExpanded
            VStack(alignment: .leading, spacing: 5) {
                if !setting.isVisible(for: model.mode) && setting.isExpandable {
                    Button {
                        whyExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text(whyExpanded ? "▾" : "▸").font(.system(size: 9)).foregroundStyle(.tertiary)
                            dl("WHY IT'S BETTER")
                            Spacer()
                            Text("\(why.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if shown {
                    ForEach(why, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 7) {
                            Text("·").foregroundStyle(accentText)
                            Text(bullet).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(RefinerNudge.allCases) { nudge in
                Button { startRefine(nudge: nudge) } label: {
                    Text(nudge.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accentText)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
                }
                .buttonStyle(.plain)
                .help(nudge.instruction)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.screen == .applied {
            HStack {
                HStack(spacing: 4) {
                    Text("✓").foregroundStyle(accentText)
                    Text(appliedLabel).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                Spacer()
                Button("Done") { model.screen = .home }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(accentText)
                    .padding(.vertical, 12)
            }
            .frame(minHeight: 44)
        } else {
            applyRow
        }
    }

    private var appliedLabel: String {
        switch RefinerSettings.output {
        case .insert: return "In the terminal — you press ⏎."
        case .copy:   return "Copied to the clipboard."
        case .send:   return "Sent."
        }
    }

    private var applyRow: some View {
        HStack(spacing: 8) {
            Button { apply() } label: {
                Text(applyLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(accentFill, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(applyHelp)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.proposal?.proposed ?? "", forType: .string)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(copied ? accentText : .secondary)
                    .frame(width: 72, height: 44)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(hair) }
            }
            .buttonStyle(.plain)
            .help("Copy the proposal")
        }
    }

    private var applyLabel: String {
        switch RefinerSettings.output {
        case .insert: return "Insert — you fire"
        case .copy:   return "Copy"
        case .send:   return "Send now"
        }
    }

    private var applyHelp: String {
        switch RefinerSettings.output {
        case .insert: return "Pastes into the terminal input. Never presses Enter."
        case .copy:   return "Puts the proposal on the clipboard."
        case .send:   return "Sends immediately — the only mode that spends without a second look."
        }
    }

    // MARK: - Actions

    private func apply() {
        guard let text = model.proposal?.proposed else { return }
        switch RefinerSettings.output {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .insert, .send:
            if model.mode == .mission {
                model.pendingMissionObjective = text
            } else {
                _ = cockpit.insertDraft(text)
                if RefinerSettings.output == .send,
                   let term = cockpit.active?.terminal as? DroppableTerminalView {
                    term.sendProgrammatic(txt: "\r")
                }
            }
        }
        model.screen = .applied
    }

    private func startRefine(nudge: RefinerNudge?) {
        guard let tab = cockpit.active else {
            model.fail("No active session.")
            return
        }
        let source = nudge == nil ? model.draft : (model.proposal?.proposed ?? model.draft)
        startedAt = Date()
        model.screen = .loading
        task?.cancel()
        task = Task {
            do {
                let refinement = try await PromptRefinerService.refine(
                    draft: source, mode: model.mode, runtime: tab.runtime, nudge: nudge,
                    projectName: tab.projectName, projectPath: tab.cwd)
                guard !Task.isCancelled else { return }
                model.accept(refinement)
            } catch {
                guard !Task.isCancelled else { return }
                model.fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Chrome

    private func backBar(title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("‹ Back", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accentText)
            dl(title)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
    }

    private func dl(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private func metricsLabel(_ text: String) -> String {
        let m = PromptRefinerService.metrics(text)
        return "\(m.lines) ln · \(m.bytes) B · ≈\(m.approxTokens) tok"
    }
}
```

- [ ] **Step 2: Build**

Run `xcodegen generate`, then the build command.
Expected: build succeeds with no warnings.

- [ ] **Step 3: Commit**

```bash
git add Throttle/UI/Cockpit/PromptRefinerPane.swift
git commit -m "[throttle] feat: the refiner takes the column, one focus screen at a time"
```

---

### Task 6: CockpitSidebar and cockpit-root wiring

**Files:**
- Create: `Throttle/UI/Cockpit/CockpitSidebar.swift`
- Modify: `Throttle/UI/Cockpit/MultiCockpitRoot.swift` (line 17 state, lines 60-66 body, lines 134-136 toolbar, lines 923-931 handoff)

**Interfaces:**
- Consumes: `CockpitAuditInspector`, `PromptRefinerPane` (Task 5), `PromptRefinerModel.shared`.
- Produces: `CockpitSidebar`, `CockpitSidebar.Tab`.

- [ ] **Step 1: Write the sidebar host**

Create `Throttle/UI/Cockpit/CockpitSidebar.swift`:

```swift
import SwiftUI

/// The cockpit's right sidebar. It renders exactly ONE segment at a time — the
/// same lifecycle that already applies when the inspector is hidden. That is
/// deliberate: the Audit segment's view model owns a polling task, and keeping
/// it mounted off-screen would run that loop for nothing. The refiner survives
/// the teardown because its state lives in `PromptRefinerModel`, not in a view.
struct CockpitSidebar: View {
    enum Tab: String, CaseIterable, Identifiable {
        case audit, refiner
        var id: String { rawValue }
        var label: String {
            switch self {
            case .audit:   return "Audit"
            case .refiner: return "Refiner"
            }
        }
        var help: String {
            switch self {
            case .audit:   return "Read-only usage metrics for this session and your windows"
            case .refiner: return "Turn a rough draft into a prompt worth sending"
            }
        }
    }

    @Binding var tab: Tab

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.label).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(tab.help)
            .padding(.horizontal, 14).padding(.vertical, 12)

            Rectangle().fill(hair).frame(height: 1)

            switch tab {
            case .audit:   CockpitAuditInspector()
            case .refiner: PromptRefinerPane()
            }
        }
        .frame(width: 280)
        .background(.regularMaterial)
    }
}
```

Note: `CockpitAuditInspector` already sets `.frame(width: 280)` and
`.background(.regularMaterial)` on itself. Remove both modifiers from
`CockpitAuditInspector.swift` (its `body`, around line 39-40) so the host owns
the column geometry and the two segments cannot disagree about it.

- [ ] **Step 2: Wire it into the cockpit root**

In `Throttle/UI/Cockpit/MultiCockpitRoot.swift`:

Replace line 17:

```swift
    @State private var showInspector = false
```

with:

```swift
    @State private var showSidebar = false
    @State private var sidebarTab: CockpitSidebar.Tab = .audit
```

Replace the body block at lines 60-66:

```swift
            HStack(spacing: 0) {
                content
                if showInspector {
                    Rectangle().fill(hair).frame(width: 1)
                    CockpitAuditInspector()
                }
            }
```

with:

```swift
            HStack(spacing: 0) {
                content
                if showSidebar {
                    Rectangle().fill(hair).frame(width: 1)
                    CockpitSidebar(tab: $sidebarTab)
                }
            }
```

Replace the toolbar toggle at lines 134-135:

```swift
                ToolbarToggle(icon: "sidebar.trailing", label: String(localized: "Audit"), isOn: showInspector,
                              iconOnly: narrow, help: String(localized: "Audit inspector")) { showInspector.toggle() }
```

with:

```swift
                ToolbarToggle(icon: "sidebar.trailing", label: String(localized: "Panel"), isOn: showSidebar,
                              iconOnly: narrow,
                              help: String(localized: "Audit metrics and the prompt refiner")) {
                    showSidebar.toggle()
                }
```

- [ ] **Step 3: Seed a refined mission objective into the handoff**

At `MultiCockpitRoot.swift:931`, the handoff is built with a hardcoded default
objective. Replace:

```swift
                objective: "Continue the current work at the next unfinished task.",
```

with:

```swift
                objective: PromptRefinerModel.shared.pendingMissionObjective
                    ?? "Continue the current work at the next unfinished task.",
```

`MissionHandoffSheet` seeds its editable field from `handoff.objective`
(line 1698), so a refined objective arrives in the sheet ready to review — and
the user still edits and confirms it there. Nothing is launched by the refiner.

- [ ] **Step 4: Build**

Run `xcodegen generate`, then the build command.
Expected: build succeeds. Grep for stragglers: `grep -rn "showInspector" Throttle` must return nothing.

- [ ] **Step 5: Verify by hand**

Open the cockpit, toggle the panel from the toolbar, and check:
1. The Audit segment still shows its three sections and its metrics.
2. Switching to Refiner and back does not reset a typed draft.
3. `New draft` → type → `⌘⏎` → the loading screen appears, then a result.
4. `Insert` puts the text in the terminal input **without** submitting it.
5. Press-and-hold on the compare control swaps to the original and back.

- [ ] **Step 6: Commit**

```bash
git add Throttle/UI/Cockpit/CockpitSidebar.swift Throttle/UI/Cockpit/MultiCockpitRoot.swift Throttle/UI/Cockpit/CockpitAuditInspector.swift
git commit -m "[throttle] feat: one right panel, two segments, and the shell stays put"
```

---

### Task 7: Settings surface

**Files:**
- Modify: `Throttle/UI/ProjectWindow/ProjectAssistantTab.swift` (near the quality preference binding at line 185)

**Interfaces:**
- Consumes: `RefinerOutput`, `RefinerRationale`, `RefinerSettings` (Task 3).
- Produces: nothing consumed by later tasks.

The refiner deliberately adds no provider or quality controls — it reuses the
ones already on this tab. It adds only the three settings the spec lists.

- [ ] **Step 1: Add the controls**

In `ProjectAssistantTab.swift`, next to the existing quality `Picker`, add:

```swift
            Picker("Refined prompts", selection: Binding(
                get: { RefinerSettings.output },
                set: { RefinerSettings.output = $0 }
            )) {
                ForEach(RefinerOutput.allCases) { Text($0.label).tag($0) }
            }
            .help("What the cockpit refiner's apply button does. Insert never presses Return.")

            Picker("Explain changes", selection: Binding(
                get: { RefinerSettings.rationale },
                set: { RefinerSettings.rationale = $0 }
            )) {
                ForEach(RefinerRationale.allCases) { Text($0.label).tag($0) }
            }
            .help("When the refiner shows why it rewrote your draft.")

            Toggle("Refine with a local model only", isOn: Binding(
                get: { RefinerSettings.forceLocal },
                set: { RefinerSettings.forceLocal = $0 }
            ))
            .help("Keeps refinements on Apple Intelligence or the embedded model, so optimising tokens never costs tokens.")
```

- [ ] **Step 2: Honour `forceLocal` in the service**

In `PromptRefinerService`, replace the body of `registryResolver`:

```swift
    static let registryResolver: ProviderResolver = { tried in
        tried.isEmpty
            ? await AIProviderRegistry.shared.resolveActive()
            : await AIProviderRegistry.shared.firstAvailable(excluding: tried)
    }
```

with:

```swift
    static let registryResolver: ProviderResolver = { tried in
        // forceLocal is a boundary, not a routing hint: when the user asked for
        // local-only, a missing local model is an error, never a silent fallback
        // to a network provider.
        let networked: Set<AIProviderKind> = [.claudeWebSession, .claudeAPIKey]
        let forceLocal = RefinerSettings.forceLocal
        let excluded = forceLocal ? tried.union(networked) : tried
        return (tried.isEmpty && !forceLocal)
            ? await AIProviderRegistry.shared.resolveActive()
            : await AIProviderRegistry.shared.firstAvailable(excluding: excluded)
    }
```

The tests from Task 2 inject their own resolver, so they stay unaffected by this
preference — which is the point of the seam.

- [ ] **Step 3: Add the test**

Append to `PromptRefinerModelTests`:

```swift
    func test_refinerSettings_defaultToInsertLocalAndMissionOnly() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "throttleRefinerOutput")
        defaults.removeObject(forKey: "throttleRefinerForceLocal")
        defaults.removeObject(forKey: "throttleRefinerRationale")
        XCTAssertEqual(RefinerSettings.output, .insert)
        XCTAssertTrue(RefinerSettings.forceLocal)
        XCTAssertEqual(RefinerSettings.rationale, .missionOnly)
    }
```

- [ ] **Step 4: Build and test**

Run `xcodegen generate`, the build command, then the approved test command.
Expected: build succeeds, all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Throttle/UI/ProjectWindow/ProjectAssistantTab.swift Throttle/Services/PromptRefinerService.swift ThrottleTests/ServiceTests/PromptRefinerModelTests.swift
git commit -m "[throttle] feat: local-only refinement is a boundary, not a preference"
```

---

### Task 8: Lint, full test run, and TODO reconciliation

**Files:**
- Modify: `.swiftlint-baseline.json` (only if the new files introduce baseline drift)
- Modify: `docs/TODO.md`

- [ ] **Step 1: Lint**

```bash
swiftlint lint --quiet 2>&1 | tail -20
```

Expected: no new violations. If the pinned baseline shifts, regenerate it for
the new files only — CI fails on lint before it ever reaches the build step.

- [ ] **Step 2: Full macOS test run (ask first)**

Request approval, then:

```bash
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS' -only-testing:ThrottleTests \
  -disableAutomaticPackageResolution -skipPackagePluginValidation \
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: the whole `ThrottleTests` bundle passes, including the pre-existing
suites. Report the actual counts; do not claim a pass that was not observed.

- [ ] **Step 3: Record the state in the work ledger**

Add to `docs/TODO.md`, under "Local gates closed in this remediation":

```markdown
- The cockpit right panel carries two segments, Audit and Refiner. The refiner
  proposes a prompt, shows its line/byte/token cost and its rationale, and
  applies only on an explicit action; insertion is a bracketed paste that never
  appends a newline. The side shell is unchanged and still lives in the
  terminal split. M2 (prompt library, semantic search, expander) is not built.
```

- [ ] **Step 4: Commit**

```bash
git add docs/TODO.md .swiftlint-baseline.json
git commit -m "[throttle] docs: record the refiner in the work ledger"
```

---

## Milestones

**M1 — Tasks 1-8.** Sidebar, refiner, settings. Ships useful on its own; stop
here for a reviewable first landing.

**M2 — Tasks 9-14.** The prompt library, semantic search and the `;;trigger`
expander. Unblocked by the second Design pass.

---

# M2 — Prompt library

Unblocked 2026-08-26 by the second Claude Design pass ("Turn 2 — Prompt Library
inside locked 1c", same project `fb232897-bbe6-4b35-8410-79ae90ca1aef`).

**Navigation answer from the design, and it is binding:** Library and History are
two sections of the **Home scroll**. `All N ›` drills into a Library focus screen
where search lives. There are no tabs inside tabs. Saving is a *verb* on the
Result screen, never a filled button competing with Insert.

**Copy locked by the design** (use verbatim):
- Home footnote: `History is automatic and ephemeral. The library is what you chose to keep.`
- Home, library empty: `Nothing saved yet — Save from a result.`
- Search placeholder: `Search by meaning — not just words`
- Semantic footnote: `Matched by meaning — your words don't appear in these prompts.`
- No results: `No match above 40%.`
- Composer placeholder: `Rough is fine — ⌘⏎ refines. Type ;; to expand a saved prompt.`
- Expander footer: `⏎ expand · esc dismiss · ↑↓ choose`
- Post-expansion flash: `✓ <name> — ⌘Z undoes`
- Save verb: `Save to library…`

---

### Task 9: SavedPrompt and the library store

**Files:**
- Create: `Throttle/Services/PromptLibraryStore.swift`
- Test: `ThrottleTests/ServiceTests/PromptLibraryStoreTests.swift`

**Interfaces:**
- Consumes: `RefinerMode` (Task 1); `SemanticIndex`, `NLEmbeddingProvider`, `EmbeddingProvider` (existing).
- Produces: `SavedPrompt`, `PromptLibraryStore` (`load(from:)`, `save(to:)`, `add(_:)`, `remove(id:)`, `rename(id:to:)`, `markUsed(id:)`, `prompt(forTrigger:)`, `triggerMatches(prefix:)`, `all`), `PromptLibraryStore.normalizedTrigger(_:)`, `PromptLibraryStore.defaultDirectory`.

- [ ] **Step 1: Write the failing tests**

Create `ThrottleTests/ServiceTests/PromptLibraryStoreTests.swift`:

```swift
@testable import Throttle
import XCTest

/// The library is what the user chose to keep, so its failure modes are
/// different from history's: a lost entry is a real loss, a duplicate trigger is
/// an ambiguous expansion, and a rename must not orphan the search index.
final class PromptLibraryStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prompt-library-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makePrompt(_ name: String, trigger: String, text: String,
                            mode: RefinerMode = .session) -> SavedPrompt {
        SavedPrompt(name: name, trigger: trigger, text: text, mode: mode)
    }

    func test_addAndRoundTripThroughDisk() throws {
        var store = PromptLibraryStore()
        store.add(makePrompt("Scroll repro", trigger: ";;scroll",
                             text: "Reproduce the trackpad scroll regression."))
        try store.save(to: dir)

        let reloaded = PromptLibraryStore.load(from: dir)
        XCTAssertEqual(reloaded.all.count, 1)
        XCTAssertEqual(reloaded.all[0].name, "Scroll repro")
        XCTAssertEqual(reloaded.all[0].text, "Reproduce the trackpad scroll regression.")
    }

    func test_loadFromAnEmptyDirectoryIsAnEmptyLibraryNotACrash() {
        XCTAssertEqual(PromptLibraryStore.load(from: dir).all.count, 0)
    }

    func test_normalizedTrigger_alwaysCarriesTheDoubleSemicolonAndNoSpaces() {
        XCTAssertEqual(PromptLibraryStore.normalizedTrigger("bug"), ";;bug")
        XCTAssertEqual(PromptLibraryStore.normalizedTrigger(";;bug"), ";;bug")
        XCTAssertEqual(PromptLibraryStore.normalizedTrigger("  Bug Report "), ";;bugreport")
        XCTAssertEqual(PromptLibraryStore.normalizedTrigger(""), "")
    }

    func test_addWithADuplicateTriggerSuffixesInsteadOfShadowing() {
        var store = PromptLibraryStore()
        store.add(makePrompt("First", trigger: ";;bug", text: "one"))
        store.add(makePrompt("Second", trigger: ";;bug", text: "two"))
        let triggers = store.all.map(\.trigger).sorted()
        XCTAssertEqual(triggers, [";;bug", ";;bug2"])
    }

    func test_promptForTrigger_isExactAndCaseInsensitive() {
        var store = PromptLibraryStore()
        store.add(makePrompt("Bug", trigger: ";;bug", text: "the bug prompt"))
        XCTAssertEqual(store.prompt(forTrigger: ";;bug")?.text, "the bug prompt")
        XCTAssertEqual(store.prompt(forTrigger: ";;BUG")?.text, "the bug prompt")
        XCTAssertNil(store.prompt(forTrigger: ";;bu"))
    }

    func test_triggerMatches_completesAPartiallyTypedTrigger() {
        var store = PromptLibraryStore()
        store.add(makePrompt("Bug", trigger: ";;bug", text: "b"))
        store.add(makePrompt("Build", trigger: ";;build", text: "c"))
        store.add(makePrompt("Scroll", trigger: ";;scroll", text: "d"))
        XCTAssertEqual(store.triggerMatches(prefix: "bu").map(\.name).sorted(), ["Bug", "Build"])
        XCTAssertEqual(store.triggerMatches(prefix: "").count, 3)
        XCTAssertTrue(store.triggerMatches(prefix: "zzz").isEmpty)
    }

    func test_renameKeepsTheIdAndTheText() {
        var store = PromptLibraryStore()
        store.add(makePrompt("Old name", trigger: ";;x", text: "body"))
        let id = store.all[0].id
        store.rename(id: id, to: "New name")
        XCTAssertEqual(store.all[0].id, id)
        XCTAssertEqual(store.all[0].name, "New name")
        XCTAssertEqual(store.all[0].text, "body")
    }

    func test_removeDropsItFromDiskToo() throws {
        var store = PromptLibraryStore()
        store.add(makePrompt("Doomed", trigger: ";;d", text: "body"))
        let id = store.all[0].id
        store.remove(id: id)
        try store.save(to: dir)
        XCTAssertEqual(PromptLibraryStore.load(from: dir).all.count, 0)
    }

    func test_markUsedIncrementsTheCounterShownInTheLibraryRow() {
        var store = PromptLibraryStore()
        store.add(makePrompt("Counted", trigger: ";;c", text: "body"))
        let id = store.all[0].id
        store.markUsed(id: id)
        store.markUsed(id: id)
        XCTAssertEqual(store.all[0].uses, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the build command.
Expected: FAIL — "cannot find 'PromptLibraryStore' in scope".

- [ ] **Step 3: Write the implementation**

Create `Throttle/Services/PromptLibraryStore.swift`:

```swift
import Foundation

/// A prompt the user deliberately kept. History is automatic and ephemeral; this
/// is not — so it carries a name the user chose and a trigger they can type.
struct SavedPrompt: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var trigger: String        // stored WITH the ";;" prefix, lowercased
    var text: String
    var mode: RefinerMode
    var uses: Int
    let createdAt: Date

    init(id: UUID = UUID(), name: String, trigger: String, text: String,
         mode: RefinerMode, uses: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.trigger = PromptLibraryStore.normalizedTrigger(trigger)
        self.text = text
        self.mode = mode
        self.uses = uses
        self.createdAt = createdAt
    }
}

/// Persistence for saved prompts. Deliberately a plain value type over a JSON
/// file: the library is small, human-diffable storage is a feature when someone
/// wants to see what the app kept, and the semantic index is rebuilt beside it
/// rather than being the source of truth.
struct PromptLibraryStore: Equatable {

    private(set) var all: [SavedPrompt] = []

    init(all: [SavedPrompt] = []) { self.all = all }

    // MARK: - Locations

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("com.lorislab.throttle", isDirectory: true)
            .appendingPathComponent("prompt-library", isDirectory: true)
    }

    private static func promptsURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("prompts.json")
    }

    // MARK: - Triggers

    /// A trigger is always `;;` plus lowercase alphanumerics. Spaces and stray
    /// punctuation are stripped rather than rejected: the user typed a name, not
    /// an identifier, and a silent fix beats a validation error here.
    static func normalizedTrigger(_ raw: String) -> String {
        let body = raw
            .lowercased()
            .replacingOccurrences(of: ";", with: "")
            .filter { $0.isLetter || $0.isNumber }
        return body.isEmpty ? "" : ";;" + String(body)
    }

    // MARK: - Mutation

    mutating func add(_ prompt: SavedPrompt) {
        var p = prompt
        p.trigger = uniqueTrigger(p.trigger, excluding: p.id)
        all.append(p)
    }

    /// Two prompts must never answer to one trigger — the expansion would be
    /// ambiguous and the user would never know which one they got.
    private func uniqueTrigger(_ trigger: String, excluding id: UUID) -> String {
        guard !trigger.isEmpty else { return trigger }
        let taken = Set(all.filter { $0.id != id }.map(\.trigger))
        guard taken.contains(trigger) else { return trigger }
        var n = 2
        while taken.contains("\(trigger)\(n)") { n += 1 }
        return "\(trigger)\(n)"
    }

    mutating func remove(id: UUID) {
        all.removeAll { $0.id == id }
    }

    mutating func rename(id: UUID, to name: String) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].name = name
    }

    mutating func retrigger(id: UUID, to raw: String) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].trigger = uniqueTrigger(Self.normalizedTrigger(raw), excluding: id)
    }

    mutating func markUsed(id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].uses += 1
    }

    // MARK: - Lookup

    func prompt(forTrigger raw: String) -> SavedPrompt? {
        let t = Self.normalizedTrigger(raw)
        guard !t.isEmpty else { return nil }
        return all.first { $0.trigger == t }
    }

    /// Everything whose trigger body starts with what the user has typed after
    /// the `;;`. An empty prefix lists the whole library — that is the state
    /// right after typing `;;`.
    func triggerMatches(prefix: String) -> [SavedPrompt] {
        let body = Self.normalizedTrigger(prefix).dropFirst(2)
        guard !body.isEmpty else { return all }
        return all.filter { $0.trigger.dropFirst(2).hasPrefix(body) }
    }

    // MARK: - Persistence

    static func load(from dir: URL = PromptLibraryStore.defaultDirectory) -> PromptLibraryStore {
        guard let data = try? Data(contentsOf: promptsURL(dir)),
              let prompts = try? JSONDecoder().decode([SavedPrompt].self, from: data) else {
            return PromptLibraryStore()
        }
        return PromptLibraryStore(all: prompts)
    }

    func save(to dir: URL = PromptLibraryStore.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: Self.promptsURL(dir), options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `xcodegen generate`, the build command, then the approved test command.
Expected: 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Throttle/Services/PromptLibraryStore.swift ThrottleTests/ServiceTests/PromptLibraryStoreTests.swift
git commit -m "[throttle] feat: two prompts never answer to one trigger"
```

---

### Task 10: Semantic search over the library

**Files:**
- Modify: `Throttle/Services/PromptLibraryStore.swift`
- Test: `ThrottleTests/ServiceTests/PromptLibraryStoreTests.swift`

**Interfaces:**
- Consumes: `SavedPrompt`, `PromptLibraryStore` (Task 9); `SemanticIndex.index(docId:text:metadata:)`, `.search(_:k:)`, `.searchHybrid(_:k:keywordWeight:)`, `SemanticIndex.terms(_:)`, `.keywordOverlap(_:in:)`, `NLEmbeddingProvider`.
- Produces: `PromptLibraryStore.SearchHit`, `.rebuildIndex()`, `.search(_:limit:)`, `PromptLibraryStore.matchThreshold`.

- [ ] **Step 1: Write the failing tests**

Append to `PromptLibraryStoreTests`:

```swift
    // MARK: - Search

    func test_search_findsAPromptWhoseWordsTheQueryDoesNotShare() throws {
        var store = PromptLibraryStore()
        store.add(makePrompt("Scroll regression repro",
                             trigger: ";;scroll",
                             text: "Reproduce the trackpad scrolling failure in the embedded terminal and add a regression test."))
        store.add(makePrompt("Release checklist",
                             trigger: ";;release",
                             text: "Bump the marketing version and the build number, notarize, staple, publish the appcast."))
        store.rebuildIndex()

        let hits = store.search("the terminal will not move when I swipe", limit: 3)
        try XCTSkipIf(hits.isEmpty, "NLEmbedding sentence model unavailable on this host")
        XCTAssertEqual(hits.first?.prompt.name, "Scroll regression repro")
    }

    func test_search_flagsAHitAsSemanticWhenTheQuerySharesNoWords() throws {
        var store = PromptLibraryStore()
        store.add(makePrompt("Scroll regression repro", trigger: ";;scroll",
                             text: "Reproduce the trackpad scrolling failure and add a regression test."))
        store.rebuildIndex()

        let hits = store.search("nothing moves when I swipe", limit: 3)
        try XCTSkipIf(hits.isEmpty, "NLEmbedding sentence model unavailable on this host")
        // The UI shows "Matched by meaning — your words don't appear in these
        // prompts." only when this is true, so it must not be true for a plain
        // keyword hit.
        XCTAssertTrue(hits[0].isSemantic)
    }

    func test_search_doesNotFlagAKeywordHitAsSemantic() throws {
        var store = PromptLibraryStore()
        store.add(makePrompt("Scroll regression repro", trigger: ";;scroll",
                             text: "Reproduce the trackpad scrolling failure and add a regression test."))
        store.rebuildIndex()

        let hits = store.search("regression test trackpad", limit: 3)
        try XCTSkipIf(hits.isEmpty, "NLEmbedding sentence model unavailable on this host")
        XCTAssertFalse(hits[0].isSemantic)
    }

    func test_search_onAnEmptyQueryReturnsTheWholeLibraryUnranked() {
        var store = PromptLibraryStore()
        store.add(makePrompt("A", trigger: ";;a", text: "alpha"))
        store.add(makePrompt("B", trigger: ";;b", text: "beta"))
        store.rebuildIndex()
        XCTAssertEqual(store.search("", limit: 10).count, 2)
    }

    func test_search_onAnEmptyLibraryReturnsNothing() {
        var store = PromptLibraryStore()
        store.rebuildIndex()
        XCTAssertTrue(store.search("anything at all", limit: 5).isEmpty)
    }

    func test_matchThreshold_isTheFortyPercentTheEmptyStateAdvertises() {
        // The no-results screen says "No match above 40%." — the number in the
        // copy and the number in the code must be the same one.
        XCTAssertEqual(PromptLibraryStore.matchThreshold, 0.40, accuracy: 0.0001)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the build command.
Expected: FAIL — "value of type 'PromptLibraryStore' has no member 'rebuildIndex'".

- [ ] **Step 3: Write the implementation**

Append inside `struct PromptLibraryStore` in `Throttle/Services/PromptLibraryStore.swift`:

```swift
    // MARK: - Search

    /// The floor the no-results copy advertises. Below it, the honest answer is
    /// "nothing matched" rather than a weak hit the user has to second-guess.
    static let matchThreshold: Float = 0.40

    struct SearchHit: Identifiable, Equatable {
        let prompt: SavedPrompt
        let score: Float
        /// True when the query and the prompt share no meaningful words, i.e.
        /// the embedding did the work. The UI footnotes exactly this case.
        let isSemantic: Bool
        var id: UUID { prompt.id }
    }

    /// Rebuilt from `all` rather than mutated in step with it: the library is
    /// small, and a rebuild cannot drift from the source of truth the way an
    /// incrementally-patched index can.
    mutating func rebuildIndex(embedder: EmbeddingProvider = NLEmbeddingProvider()) {
        var index = SemanticIndex(embedder: embedder)
        for p in all {
            index.index(docId: p.id.uuidString, text: "\(p.name)\n\(p.text)")
        }
        self.index = index
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return all.map { SearchHit(prompt: $0, score: 1, isSemantic: false) }
        }
        guard let index else { return [] }

        let queryTerms = SemanticIndex.terms(q)
        var best: [UUID: SearchHit] = [:]
        for hit in index.searchHybrid(q, k: max(limit * 2, 10)) {
            guard hit.score >= Self.matchThreshold,
                  let docId = hit.metadata["doc"], let uuid = UUID(uuidString: docId),
                  let prompt = all.first(where: { $0.id == uuid }) else { continue }
            let overlap = SemanticIndex.keywordOverlap(queryTerms, in: "\(prompt.name)\n\(prompt.text)")
            let candidate = SearchHit(prompt: prompt, score: hit.score, isSemantic: overlap == 0)
            if let existing = best[uuid], existing.score >= hit.score { continue }
            best[uuid] = candidate
        }
        return best.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
```

Add the stored property next to `all` at the top of the struct:

```swift
    /// Not persisted and not part of equality — it is derived from `all`.
    private var index: SemanticIndex?
```

and make `Equatable` ignore it by adding, inside the struct:

```swift
    static func == (lhs: PromptLibraryStore, rhs: PromptLibraryStore) -> Bool {
        lhs.all == rhs.all
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the build command, then the approved test command.
Expected: 15 tests PASS in this file. The three embedding-dependent tests skip
(not fail) on a host without the `NLEmbedding` sentence model — a skip is
reported honestly, never counted as a pass.

- [ ] **Step 5: Commit**

```bash
git add Throttle/Services/PromptLibraryStore.swift ThrottleTests/ServiceTests/PromptLibraryStoreTests.swift
git commit -m "[throttle] feat: find the prompt by what you meant, and say so when it did"
```

---

### Task 11: Save-to-library from the result screen

**Files:**
- Modify: `Throttle/Services/PromptRefinerModel.swift`
- Modify: `Throttle/UI/Cockpit/PromptRefinerPane.swift`
- Test: `ThrottleTests/ServiceTests/PromptRefinerModelTests.swift`

**Interfaces:**
- Consumes: `PromptLibraryStore`, `SavedPrompt` (Tasks 9-10).
- Produces: `PromptRefinerModel.library`, `.saveState`, `.saveName`, `.saveTrigger`, `.beginSave()`, `.commitSave()`, `.cancelSave()`, `.suggestedName(for:)`, `PromptRefinerModel.SaveState`.

- [ ] **Step 1: Write the failing tests**

Append to `PromptRefinerModelTests`:

```swift
    // MARK: - Saving

    func test_suggestedName_isTheFirstLineCappedForTheRow() {
        let long = String(repeating: "word ", count: 40)
        XCTAssertEqual(PromptRefinerModel.suggestedName(for: "Fix the scroll\nand test it"),
                       "Fix the scroll")
        XCTAssertLessThanOrEqual(PromptRefinerModel.suggestedName(for: long).count, 60)
    }

    func test_beginSave_prefillsTheNameAndTriggerFromTheProposal() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.accept(PromptRefinerService.Refinement(
            proposed: "Reproduce the scroll regression.", why: [], changed: true, provider: "p"))
        m.beginSave()
        XCTAssertEqual(m.saveState, .naming)
        XCTAssertEqual(m.saveName, "Reproduce the scroll regression.")
        XCTAssertFalse(m.saveTrigger.isEmpty)
        XCTAssertTrue(m.saveTrigger.hasPrefix(";;"))
    }

    func test_commitSave_putsItInTheLibraryAndReportsSaved() {
        let m = freshModel()
        m.accept(PromptRefinerService.Refinement(
            proposed: "Reproduce the scroll regression.", why: [], changed: true, provider: "p"))
        m.beginSave()
        m.saveName = "Scroll repro"
        m.saveTrigger = ";;scroll"
        m.commitSave()
        XCTAssertEqual(m.saveState, .saved)
        XCTAssertEqual(m.library.all.count, 1)
        XCTAssertEqual(m.library.all[0].name, "Scroll repro")
        XCTAssertEqual(m.library.all[0].trigger, ";;scroll")
        XCTAssertEqual(m.library.all[0].text, "Reproduce the scroll regression.")
    }

    func test_commitSave_withABlankNameKeepsTheSuggestionRatherThanSavingUntitled() {
        let m = freshModel()
        m.accept(PromptRefinerService.Refinement(
            proposed: "Reproduce the scroll regression.", why: [], changed: true, provider: "p"))
        m.beginSave()
        m.saveName = "   "
        m.commitSave()
        XCTAssertEqual(m.library.all[0].name, "Reproduce the scroll regression.")
    }

    func test_cancelSave_returnsToIdleAndSavesNothing() {
        let m = freshModel()
        m.accept(PromptRefinerService.Refinement(
            proposed: "x", why: [], changed: true, provider: "p"))
        m.beginSave()
        m.cancelSave()
        XCTAssertEqual(m.saveState, .idle)
        XCTAssertTrue(m.library.all.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the build command.
Expected: FAIL — "value of type 'PromptRefinerModel' has no member 'beginSave'".

- [ ] **Step 3: Extend the model**

Add to `PromptRefinerModel` in `Throttle/Services/PromptRefinerModel.swift`:

```swift
    enum SaveState: Equatable { case idle, naming, saved }

    var library = PromptLibraryStore()
    var saveState: SaveState = .idle
    var saveName = ""
    var saveTrigger = ""

    /// Library search state, owned here so leaving the Library screen and coming
    /// back does not silently drop the query the user typed.
    var query = ""

    /// A row's inline actions are open one at a time; nil means all collapsed.
    var expandedPromptID: UUID?

    static func suggestedName(for text: String) -> String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "Untitled prompt"
        return firstLine.count <= 60 ? firstLine : String(firstLine.prefix(59)) + "…"
    }

    func loadLibrary() {
        library = PromptLibraryStore.load()
        library.rebuildIndex()
    }

    private func persistLibrary() {
        library.rebuildIndex()
        do { try library.save() } catch {
            // A failed write must not look like a successful save.
            saveState = .idle
        }
    }

    func beginSave() {
        guard let proposed = proposal?.proposed else { return }
        saveName = Self.suggestedName(for: proposed)
        saveTrigger = PromptLibraryStore.normalizedTrigger(saveName)
        saveState = .naming
    }

    func commitSave() {
        guard let proposed = proposal?.proposed else { return }
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.suggestedName(for: proposed)
            : saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        library.add(SavedPrompt(name: name, trigger: saveTrigger, text: proposed, mode: mode))
        saveState = .saved
        persistLibrary()
    }

    func cancelSave() {
        saveState = .idle
    }

    func deletePrompt(id: UUID) {
        library.remove(id: id)
        expandedPromptID = nil
        persistLibrary()
    }

    func renamePrompt(id: UUID, to name: String) {
        library.rename(id: id, to: name)
        persistLibrary()
    }

    func usePrompt(id: UUID) {
        library.markUsed(id: id)
        persistLibrary()
    }
```

Also extend `reset()` so tests start clean — replace its body with:

```swift
    func reset() {
        screen = .home
        draft = ""
        proposal = nil
        peeking = false
        history = []
        pendingMissionObjective = nil
        library = PromptLibraryStore()
        saveState = .idle
        saveName = ""
        saveTrigger = ""
        query = ""
        expandedPromptID = nil
    }
```

Note: `reset()` does not touch what is already on disk. Tests exercise the
in-memory store; Task 9's tests cover the disk round trip against a temporary
directory.

- [ ] **Step 4: Add the save block to the result screen**

In `PromptRefinerPane.swift`, insert between `rationale` and `chips` in the
`result` view's `VStack`:

```swift
                saveBlock
```

and add the view:

```swift
    @ViewBuilder
    private var saveBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(hair)
            switch model.saveState {
            case .idle:
                Button("Save to library…") { model.beginSave() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(accentText)
                    .frame(minHeight: 32)
                    .help("Keeps this proposal as a named, searchable prompt with a ;;trigger")

            case .naming:
                TextField("Name", text: $model.saveName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(accentText.opacity(0.45)) }
                    .help("How it appears in the library — pre-filled from the proposal")

                TextField(";;trigger", text: $model.saveTrigger)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
                    .help("Type this in the composer to expand the prompt")

                HStack(spacing: 2) {
                    Button("Save ⏎") { model.commitSave() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accentText)
                        .keyboardShortcut(.return, modifiers: [])
                    Button("Cancel") { model.cancelSave() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                .padding(.vertical, 8)

            case .saved:
                HStack {
                    Text("✓ In library · \(model.library.all.last?.trigger ?? "")")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Rename") { model.beginSave() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accentText)
                }
                .frame(minHeight: 32)
            }
        }
    }
```

- [ ] **Step 5: Run tests and build**

Run `xcodegen generate`, the build command, then the approved test command.
Expected: 5 new model tests PASS, build clean.

- [ ] **Step 6: Commit**

```bash
git add Throttle/Services/PromptRefinerModel.swift Throttle/UI/Cockpit/PromptRefinerPane.swift ThrottleTests/ServiceTests/PromptRefinerModelTests.swift
git commit -m "[throttle] feat: saving is a verb, not a button competing with Insert"
```

---

### Task 12: The Library focus screen and the Home sections

**Files:**
- Modify: `Throttle/UI/Cockpit/PromptRefinerPane.swift`
- Modify: `Throttle/Services/PromptRefinerModel.swift` (add `.library` to `Screen`)

**Interfaces:**
- Consumes: everything from Tasks 9-11.
- Produces: no new API — screens only.

- [ ] **Step 1: Add the screen case**

In `PromptRefinerModel.Screen`, add:

```swift
        /// The library's own focus screen. Reached from Home's "All N ›" — NOT a
        /// second tab bar. The design is explicit that tabs inside tabs are the
        /// failure mode to avoid.
        case library
```

and handle it in the pane's `switch`:

```swift
            case .library:         libraryScreen
```

- [ ] **Step 2: Rewrite Home with both sections**

Replace the `home` view's list region (everything after the TARGET block) with:

```swift
            Rectangle().fill(hair).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        dl("LIBRARY")
                        Spacer()
                        Button("All \(model.library.all.count) ›") {
                            model.screen = .library
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accentText)
                        .help("All saved prompts, with semantic search")
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)

                    if model.library.all.isEmpty {
                        Text("Nothing saved yet — Save from a result.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.bottom, 10)
                        Rectangle().fill(hair).frame(height: 1)
                    } else {
                        ForEach(model.library.all.sorted { $0.uses > $1.uses }.prefix(3)) { p in
                            row(title: p.name,
                                meta: "\(p.trigger) · \(p.mode.label) · \(p.uses) uses",
                                help: "Open in the library") {
                                model.screen = .library
                                model.expandedPromptID = p.id
                            }
                        }
                    }

                    dl("HISTORY").padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                    ForEach(model.history) { entry in
                        row(title: entry.title,
                            meta: "\(entry.mode.label) · \(PromptRefinerService.metrics(entry.proposed).lines) ln",
                            help: "Reopen this refinement") {
                            model.reopen(entry)
                        }
                    }

                    Text("History is automatic and ephemeral. The library is what you chose to keep.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
```

and add the shared row builder:

```swift
    private func row(title: String, meta: String, help: String,
                     action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11)).foregroundStyle(.primary).lineLimit(1)
                    Text(meta).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            Rectangle().fill(hair).frame(height: 1)
        }
    }
```

- [ ] **Step 3: Add the library screen**

```swift
    private var libraryScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button("‹ Home") { model.screen = .home }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(accentText)
                dl("LIBRARY")
                Spacer()
                Text("\(model.library.all.count) saved")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }

            TextField("Search by meaning — not just words", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10).frame(height: 36)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(hair) }
                .padding(.horizontal, 14).padding(.top, 12)
                .help("Semantic search: describe the problem, it finds the prompt")

            let hits = model.library.search(model.query)

            if hits.contains(where: \.isSemantic) {
                Text("Matched by meaning — your words don't appear in these prompts.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 8)
            }

            if model.library.all.isEmpty {
                emptyLibrary
            } else if hits.isEmpty {
                noResults
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(hits) { libraryRow($0) } }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func libraryRow(_ hit: PromptLibraryStore.SearchHit) -> some View {
        let p = hit.prompt
        let isOpen = model.expandedPromptID == p.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                model.expandedPromptID = isOpen ? nil : p.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.name).font(.system(size: 11)).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(model.query.isEmpty ? "\(p.uses) uses" : "\(Int(hit.score * 100))%")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help(model.query.isEmpty
                                  ? "How many times you inserted this prompt"
                                  : "Similarity to your query")
                    }
                    Text(p.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("\(p.trigger) · \(p.mode.label)")
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                HStack(spacing: 2) {
                    Button("Insert") {
                        model.usePrompt(id: p.id)
                        _ = cockpit.insertDraft(p.text)
                    }
                    .help("Pastes into the terminal input — never presses Enter")

                    Button("Re-refine") {
                        model.mode = p.mode
                        model.draft = p.text
                        model.proposal = nil
                        model.screen = .compose
                    }
                    .help("Opens as a new draft in the composer")

                    Spacer()
                    Button("Delete") { model.deletePrompt(id: p.id) }
                        .foregroundStyle(warn)
                        .help("Removes it from the library — history keeps the refinement")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accentText)
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            Rectangle().fill(hair).frame(height: 1)
        }
    }

    private var noResults: some View {
        VStack(spacing: 6) {
            Text("No match above 40%.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\"\(model.query)\"")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            Button("New draft from this") {
                model.draft = model.query
                model.query = ""
                model.screen = .compose
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(accentText)
            .padding(10)
            .help("Your query becomes the draft — nothing is lost")

            Button("Clear") { model.query = "" }
                .buttonStyle(.plain)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 28)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 6) {
            Text("Nothing saved yet.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Refine something, then use \"Save to library…\" on the result. Saved prompts get a ;;trigger you can type in the composer.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("New draft") { model.beginCompose() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accentText)
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.vertical, 48)
    }
```

- [ ] **Step 4: Load the library when the pane appears**

Add to the pane's root `.onAppear`:

```swift
        .onAppear { if model.library.all.isEmpty { model.loadLibrary() } }
```

- [ ] **Step 5: Build and check by hand**

Run `xcodegen generate`, then the build command. Then verify:
1. Home shows LIBRARY (empty copy) then HISTORY then the footnote.
2. `All 0 ›` opens the library screen with the empty state.
3. After saving one prompt, Home lists it and `All 1 ›` shows it.
4. A query with no hits shows `No match above 40%.` and "New draft from this"
   carries the query into the composer.

- [ ] **Step 6: Commit**

```bash
git add Throttle/UI/Cockpit/PromptRefinerPane.swift Throttle/Services/PromptRefinerModel.swift
git commit -m "[throttle] feat: the library and history are two sections, not two tabs"
```

---

### Task 13: The ;; expander

**Files:**
- Create: `Throttle/UI/Cockpit/RefinerComposerView.swift`
- Modify: `Throttle/UI/Cockpit/PromptRefinerPane.swift`
- Test: `ThrottleTests/ServiceTests/PromptLibraryStoreTests.swift`

**Interfaces:**
- Consumes: `PromptLibraryStore.triggerMatches(prefix:)`, `SavedPrompt`.
- Produces: `RefinerComposerView`, `TriggerScanner.pendingTrigger(in:caret:)`, `TriggerScanner.expand(text:caret:with:)`.

**Why a new view:** the expansion happens *at the caret*, and SwiftUI's
`TextEditor` exposes neither the caret offset nor a key-handling hook precise
enough for `↑↓ ⏎ esc` over a popup. `RefinerComposerView` wraps `NSTextView`
so the caret is knowable. This is a real cost the design implies; it is not
optional if the expander is to behave as drawn.

- [ ] **Step 1: Write the failing tests**

Append to `PromptLibraryStoreTests`:

```swift
    // MARK: - Trigger scanning at the caret

    func test_pendingTrigger_isTheTokenImmediatelyBeforeTheCaret() {
        XCTAssertEqual(TriggerScanner.pendingTrigger(in: "fix this ;;bu", caret: 13), "bu")
        XCTAssertEqual(TriggerScanner.pendingTrigger(in: "fix this ;;", caret: 11), "")
    }

    func test_pendingTrigger_isNilWhenThereIsNoOpenTrigger() {
        XCTAssertNil(TriggerScanner.pendingTrigger(in: "fix this bug", caret: 12))
        XCTAssertNil(TriggerScanner.pendingTrigger(in: "a single ; here", caret: 15))
    }

    func test_pendingTrigger_closesOnWhitespaceSoAFinishedWordStopsSuggesting() {
        XCTAssertNil(TriggerScanner.pendingTrigger(in: ";;bug and then more", caret: 19))
    }

    func test_pendingTrigger_ignoresTextAfterTheCaret() {
        XCTAssertEqual(TriggerScanner.pendingTrigger(in: ";;bu trailing", caret: 4), "b")
    }

    func test_expand_replacesTheTriggerTokenAndReportsTheNewCaret() {
        let r = TriggerScanner.expand(text: "fix this ;;bu", caret: 13, with: "REPRO STEPS")
        XCTAssertEqual(r.text, "fix this REPRO STEPS")
        XCTAssertEqual(r.caret, 20)
    }

    func test_expand_keepsWhatFollowsTheCaretIntact() {
        let r = TriggerScanner.expand(text: ";;bu tail", caret: 4, with: "BODY")
        XCTAssertEqual(r.text, "BODY tail")
        XCTAssertEqual(r.caret, 4)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the build command.
Expected: FAIL — "cannot find 'TriggerScanner' in scope".

- [ ] **Step 3: Write the scanner and the composer**

Create `Throttle/UI/Cockpit/RefinerComposerView.swift`:

```swift
import AppKit
import SwiftUI

/// Finds and replaces a `;;trigger` token at the caret. Pure string work, kept
/// out of the view so it can be tested without an NSTextView.
enum TriggerScanner {

    /// The trigger body being typed immediately before `caret`, or nil when the
    /// caret is not inside an open `;;token`. Whitespace closes a trigger, so a
    /// finished word stops suggesting.
    static func pendingTrigger(in text: String, caret: Int) -> String? {
        let chars = Array(text)
        let end = max(0, min(caret, chars.count))
        var i = end - 1
        var body: [Character] = []
        while i >= 0 {
            let c = chars[i]
            if c == ";" {
                guard i - 1 >= 0, chars[i - 1] == ";" else { return nil }
                return String(body.reversed())
            }
            if c.isWhitespace || c.isNewline { return nil }
            body.append(c)
            i -= 1
        }
        return nil
    }

    /// Replace the open trigger token with `replacement`, returning the new text
    /// and where the caret lands after it.
    static func expand(text: String, caret: Int, with replacement: String) -> (text: String, caret: Int) {
        guard let body = pendingTrigger(in: text, caret: caret) else { return (text, caret) }
        let chars = Array(text)
        let end = max(0, min(caret, chars.count))
        let start = end - body.count - 2      // the two semicolons
        guard start >= 0 else { return (text, caret) }
        let newText = String(chars[0..<start]) + replacement + String(chars[end...])
        return (newText, start + replacement.count)
    }
}

/// An `NSTextView`-backed composer. `TextEditor` cannot report the caret, and
/// the expander has to insert exactly there — so the composer owns an NSTextView
/// and reports both the text and the caret offset upward.
struct RefinerComposerView: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int
    var onCommandReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = false
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            let selected = tv.selectedRange()
            tv.string = text
            let clamped = min(caret, (text as NSString).length)
            tv.setSelectedRange(NSRange(location: clamped, length: 0))
            _ = selected
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: RefinerComposerView
        init(_ parent: RefinerComposerView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.caret = tv.selectedRange().location
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.caret = tv.selectedRange().location
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)),
               NSEvent.modifierFlags.contains(.command) {
                parent.onCommandReturn()
                return true
            }
            return false
        }
    }
}
```

- [ ] **Step 4: Wire the popup into the compose screen**

In `PromptRefinerPane.swift`, add state:

```swift
    @State private var caret = 0
    @State private var expanderSelection = 0
    @State private var flash: String?
```

Replace the `TextEditor` in `compose` with:

```swift
            RefinerComposerView(text: $model.draft, caret: $caret) { startRefine(nudge: nil) }
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
                .padding(.horizontal, 14).padding(.top, 12)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) { expanderPopup }
                .help("Rough is fine — ⌘⏎ refines. Type ;; to expand a saved prompt.")
```

and add the popup:

```swift
    @ViewBuilder
    private var expanderPopup: some View {
        if let pending = TriggerScanner.pendingTrigger(in: model.draft, caret: caret) {
            let matches = model.library.triggerMatches(prefix: pending)
            VStack(alignment: .leading, spacing: 0) {
                if matches.isEmpty {
                    Text("No saved prompt matches \";;\(pending)\"")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                } else {
                    ForEach(Array(matches.prefix(5).enumerated()), id: \.element.id) { idx, p in
                        Button { expand(with: p) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(p.trigger)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(accentText)
                                Text(p.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(PromptRefinerService.metrics(p.text).lines) ln")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(idx == expanderSelection ? accentFill.opacity(0.22) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider().overlay(hair)
                Text("⏎ expand · esc dismiss · ↑↓ choose")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.98),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.14)) }
            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
            .padding(.horizontal, 14).padding(.bottom, 6)
            .onKeyPress(.upArrow) { expanderSelection = max(0, expanderSelection - 1); return .handled }
            .onKeyPress(.downArrow) {
                expanderSelection = min(matches.count - 1, expanderSelection + 1)
                return .handled
            }
            .onKeyPress(.return) {
                guard matches.indices.contains(expanderSelection) else { return .ignored }
                expand(with: matches[expanderSelection])
                return .handled
            }
            .onKeyPress(.escape) {
                // Close by breaking the open trigger, which is what the user
                // typing a space would do anyway.
                model.draft += " "
                caret = (model.draft as NSString).length
                return .handled
            }
        }
    }

    private func expand(with prompt: SavedPrompt) {
        let result = TriggerScanner.expand(text: model.draft, caret: caret, with: prompt.text)
        model.draft = result.text
        caret = result.caret
        expanderSelection = 0
        model.usePrompt(id: prompt.id)
        flash = prompt.name
    }
```

and show the flash under the composer, above the metrics row:

```swift
            if let flash {
                HStack(spacing: 4) {
                    Text("✓").foregroundStyle(accentText)
                    Text("\(flash) — ⌘Z undoes").foregroundStyle(.tertiary)
                }
                .font(.system(size: 10))
                .padding(.horizontal, 14).padding(.top, 6)
            }
```

- [ ] **Step 5: Run tests and build**

Run `xcodegen generate`, the build command, then the approved test command.
Expected: 6 new scanner tests PASS.

- [ ] **Step 6: Check by hand**

1. Save a prompt with trigger `;;bug`.
2. In the composer type `;;` — the popup lists the library.
3. Type `bu` — it narrows. `↑↓` moves, `⏎` expands at the caret.
4. `⌘Z` undoes the expansion in one step.
5. Type `;;zzz` — the "No saved prompt matches" line shows instead of a list.

- [ ] **Step 7: Commit**

```bash
git add Throttle/UI/Cockpit/RefinerComposerView.swift Throttle/UI/Cockpit/PromptRefinerPane.swift ThrottleTests/ServiceTests/PromptLibraryStoreTests.swift
git commit -m "[throttle] feat: ;;trigger expands where the caret actually is"
```

---

### Task 14: Close out M2

- [ ] **Step 1: Lint**

```bash
swiftlint lint --quiet 2>&1 | tail -20
```

- [ ] **Step 2: Full test run (ask first)**

Same command as Task 8, over the whole `ThrottleTests` bundle. Report the real
counts, including any skips from the embedding-dependent tests.

- [ ] **Step 3: Update the spec's status**

In `docs/superpowers/specs/2026-08-26-cockpit-prompt-refiner-design.md`, replace
the §6 line "Visuals pending the second Design pass." with a pointer to the
turn-2 boards, and mark M2 unblocked in §8 and §10.

- [ ] **Step 4: Update `docs/TODO.md`**

Extend the M1 entry to state that the library, semantic search and the
`;;trigger` expander shipped, and that search is exact brute-force cosine over
`NLEmbedding` with a 40% floor — no ANN backend, which stays deferred.

- [ ] **Step 5: Commit**

```bash
git add docs/TODO.md docs/superpowers/specs/2026-08-26-cockpit-prompt-refiner-design.md .swiftlint-baseline.json
git commit -m "[throttle] docs: the refiner and its library, recorded"
```
