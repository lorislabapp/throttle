import Foundation

/// "Commit-mode" optimizer: asks the active AI provider to PROPOSE an optimized
/// version of a config file (CLAUDE.md / settings.json) plus a plain-language
/// "why this is better" rationale — so the Optimizer tab shows a real diff
/// (current ↔ proposed) and the reasoning, like a PR. Never writes; the caller
/// applies via FileEditor (backup + atomic).
enum AIOptimizerService {

    struct Proposal: Sendable {
        let proposed: String
        let why: [String]
        let changed: Bool
        var provider: String = ""   // which model produced it (transparency)
    }

    enum OptimizerError: LocalizedError {
        case noProvider
        case empty
        var errorDescription: String? {
            switch self {
            case .noProvider: return "No AI provider available — sign in to claude.ai or add an API key in the Assistant tab."
            case .empty:      return "The model returned nothing usable."
            }
        }
    }

    // Unique delimiters (NOT ``` — config files contain code fences).
    private static let fileStart = "===THROTTLE-FILE==="
    private static let fileEnd = "===THROTTLE-ENDFILE==="
    private static let whyMark = "===THROTTLE-WHY==="

    static func optimize(fileLabel: String, content: String,
                         projectName: String, projectPath: String?) async throws -> Proposal {
        let prompt = """
        You are optimising the file `\(fileLabel)` for a Claude Code project. Apply these RESEARCHED best practices (Anthropic Claude Code docs + power-user consensus, 2026):

        For a CLAUDE.md file:
        - TARGET under ~200 lines. It reloads EVERY session — bloat makes Claude IGNORE the real instructions, so smaller is genuinely better.
        - KEEP: non-guessable build/test/lint commands, non-default code style, test runners, repo & commit/PR etiquette, architecture pointers, environment quirks, and gotchas.
        - REMOVE: anything inferable from the code itself, standard/obvious conventions, content that just restates linkable API docs, dumped file trees, tutorials and long prose, and duplicated or stale instructions.
        - Things that belong ELSEWHERE (note in WHY, don't silently delete): situational detail → a skill; path-specific rules → a subdirectory CLAUDE.md; automation → a hook. Real context savings come from skills/path-scoped rules/hooks, NOT from imports.

        For a settings.json / settings.local.json file (HIGH-LEVERAGE cost wins — apply the ones that fit, MERGE into existing keys, never clobber the user's values):
        - permissions precedence is deny > ask > allow (deny ALWAYS wins); prefer tight allow-lists over broad ones.
        - `permissions.deny` is the ONLY real read-firewall. Strongly consider adding: `Read(./.env)`, `Read(./.env.*)`, `Read(./node_modules/**)`, `Read(./dist/**)`, `Read(./build/**)` — blind reads of secrets/deps/generated files silently drain the token budget (a single node_modules scan can be 10k+ tokens). Also deny destructive shell: `Bash(git push *)`, `Bash(rm -rf *)`.
        - `.claudeignore` is a MYTH — native Read/Glob/Grep do NOT honor it. If the project relies on it for exclusions, MIGRATE those globs into `permissions.deny` and call this out in WHY.
        - `model`: if unset, suggest `"claude-sonnet-4-6"` — handles ~90% of coding at ~1/5 the cost of Opus (skip if the work is Opus-only orchestration).
        - `alwaysThinkingEnabled`: prefer `false` — extended-thinking tokens bill as (expensive) output and can be up to ~40% of a session's cost; leave depth to per-task `/effort`.
        - NEVER place secrets/API keys here (or in CLAUDE.md). Secrets belong only in gitignored settings.local.json.
        - Each WHY line should cite the concrete effect (e.g. "deny node_modules reads → stops 10k+-token blind scans", "model→sonnet ≈ 5× cheaper for ~90% of tasks").

        HARD RULE: never drop a real instruction or change the developer's intent; preserve project-specific facts verbatim. If the file is already tight, return it UNCHANGED and say so.
        IF THE CURRENT FILE IS EMPTY: instead CREATE a concise, sensible STARTER — a few sections (stack, build/test commands, conventions, "don't" rules). Keep it minimal; do NOT invent project specifics you cannot know. In WHY, say it's a new starter.

        Return EXACTLY this, and nothing else (no preamble, no code fences):
        \(fileStart)
        <the full optimised file content, verbatim ready to write>
        \(fileEnd)
        \(whyMark)
        - <one concrete improvement, with a measurable effect, e.g. "merged 3 duplicate sections → ~90 tokens/session saved">
        - <another>
        - <optional third>

        Current `\(fileLabel)`:
        ----- BEGIN -----
        \(content)
        ----- END -----
        """

        let ctx = ProjectChatContext(
            projectName: projectName, projectPath: projectPath,
            claudeMd: nil, settingsJSON: nil, weeklyTokens: 0,
            modelSplit: [], hookScripts: [:], mcpServers: [], costEUR: 0
        )
        let messages = [ChatMessage(role: .user, content: prompt)]

        // Walk the provider chain (active → next available) so a flaky Claude-web
        // session falls through to the API key / Apple Intelligence instead of
        // failing the whole optimisation.
        var tried = Set<AIProviderKind>()
        var lastError: Error = OptimizerError.noProvider
        for _ in 0..<3 {
            let provider = tried.isEmpty
                ? await AIProviderRegistry.shared.resolveActive()
                : await AIProviderRegistry.shared.firstAvailable(excluding: tried)
            guard let provider else { break }
            tried.insert(provider.kind)
            do {
                var full = ""
                let stream = try await provider.streamChat(messages: messages, context: ctx)
                for try await chunk in stream { full += chunk }
                guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OptimizerError.empty }
                var p = parse(full, fallback: content)
                p.provider = provider.displayName
                return p
            } catch {
                lastError = error
                continue   // try the next provider
            }
        }
        throw lastError
    }

    private static func parse(_ text: String, fallback: String) -> Proposal {
        var proposed = fallback
        if let s = text.range(of: fileStart), let e = text.range(of: fileEnd),
           s.upperBound < e.lowerBound {
            proposed = stripOuterFence(String(text[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .newlines))
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
        return Proposal(proposed: proposed, why: why, changed: changed)
    }

    /// Defensive: some models wrap the whole file in ``` fences despite the
    /// instruction. Strip a leading ```lang line + matching trailing ``` line.
    private static func stripOuterFence(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return s }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
