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

    // MARK: - Wire format

    // Unique delimiters, NOT ``` — prompts routinely contain code fences.
    private static let promptStart = "===THROTTLE-PROMPT==="
    private static let promptEnd = "===THROTTLE-ENDPROMPT==="
    private static let whyMark = "===THROTTLE-WHY==="

    static func systemPrompt(mode: RefinerMode, runtime: AgentRuntime, nudge: RefinerNudge?) -> String {
        let (agent, idiom) = runtimeInstructions(runtime)
        let job = jobInstructions(mode)

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

    private static func runtimeInstructions(_ runtime: AgentRuntime) -> (String, String) {
        switch runtime {
        case .claudeCode:
            return ("Claude Code", [
                "- Claude Code reads the repository itself. Point at files and symbols;",
                "  never paste file contents it can open.",
                "- Slash commands and `@file` references are idiomatic.",
                "  Prefer `@path/to/file.swift` over \"the file called…\"."
            ].joined(separator: "\n"))
        case .codex:
            return ("Codex", """
            - Codex works best from an explicit, ordered task list with the acceptance check stated up front.
            - Spell out the commands to run; do not assume it will infer the toolchain.
            """)
        case .local, .terminal:
            return (
                "a local shell",
                "- There is no coding agent on this tab. Keep the instruction plain and self-contained."
            )
        }
    }

    private static func jobInstructions(_ mode: RefinerMode) -> String {
        switch mode {
        case .session:
            return """
            You are rewriting ONE next instruction for a coding agent already running
            in the user's repository, mid-session.
            It already has context. Do not re-explain the project.
            """
        case .mission:
            return """
            You are rewriting the OBJECTIVE of a long autonomous mission handed to
            a fresh agent with no conversation history.
            State the goal, the constraints, and the evidence that proves it is done.
            """
        case .loop:
            return """
            You are rewriting the objective of a REPEATING loop that will run unattended, over and over.
            It MUST contain an explicit termination condition — what makes the loop
            stop — and it must be safe to run when nothing has changed.
            """
        }
    }

    static func parse(_ text: String, fallback: String) -> Refinement {
        var proposed = fallback
        if let start = text.range(of: promptStart), let end = text.range(of: promptEnd),
           start.upperBound < end.lowerBound {
            proposed = stripOuterFence(String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .newlines))
        }
        var why: [String] = []
        if let whyRange = text.range(of: whyMark) {
            why = text[whyRange.upperBound...].split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") else {
                    return nil
                }
                let body = String(trimmed.drop(while: { "-•* ".contains($0) }))
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
    private static func stripOuterFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return text }
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

    static func excludedProviderKinds(
        tried: Set<AIProviderKind>,
        forceLocal: Bool
    ) -> Set<AIProviderKind> {
        guard forceLocal else { return tried }
        return tried.union([.claudeWebSession, .claudeAPIKey])
    }

    static let registryResolver: ProviderResolver = { tried in
        // Local-only is a privacy boundary, not a routing hint. A missing
        // local model must fail closed instead of spending network tokens.
        let forceLocal = RefinerSettings.forceLocal
        let excluded = excludedProviderKinds(tried: tried, forceLocal: forceLocal)
        return (tried.isEmpty && !forceLocal)
            ? await AIProviderRegistry.shared.resolveActive()
            : await AIProviderRegistry.shared.firstAvailable(excluding: excluded)
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
                var refinement = parse(full, fallback: draft)
                try validate(refinement.proposed)
                refinement.provider = provider.displayName
                return refinement
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }
}
