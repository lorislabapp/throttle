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
        You are optimising the file `\(fileLabel)` for a Claude Code project. Goals, in priority order:
        1. Cut token cost — remove redundancy, dead instructions, and verbosity that is re-sent every session.
        2. Tighten security — flag/parametrise secrets, narrow over-broad permissions.
        3. Improve clarity and structure.
        HARD RULE: never drop a real instruction or change the developer's intent. If the file is already tight, return it UNCHANGED and say so.

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
                return parse(full, fallback: content)
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
            proposed = String(text[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .newlines)
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
}
