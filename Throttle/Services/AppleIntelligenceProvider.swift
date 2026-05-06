import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI provider backed by Apple Intelligence's `FoundationModels` framework
/// on macOS 26+. Local, private, free.
///
/// The framework is conditionally imported — older SDKs don't ship it, so
/// the build succeeds without it but `isAvailable` returns false. On
/// macOS 26+ we runtime-check `SystemLanguageModel.default.availability`
/// to handle the case where the user's Mac supports the framework but
/// hasn't downloaded the model assets yet.
struct AppleIntelligenceProvider: AIProvider {
    let displayName = "Apple Intelligence (local)"
    let kind: AIProviderKind = .appleIntelligence

    var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let model = SystemLanguageModel.default
                switch model.availability {
                case .available: return true
                default: return false
                }
            }
            return false
            #else
            return false
            #endif
        }
    }

    func streamChat(
        messages: [ChatMessage],
        context: ProjectChatContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await streamViaFoundationModels(messages: messages, context: context)
        }
        #endif
        throw AIProviderError.unavailable(reason: "Apple Intelligence requires macOS 26 or later.")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func streamViaFoundationModels(
        messages: [ChatMessage],
        context: ProjectChatContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        // Native tool calling: pass `read_file` + `list_files` directly to
        // the on-device model. FoundationModels handles the tool_use →
        // tool_result loop internally — the model gets bytes back without
        // Throttle having to parse fenced ```tool blocks. We still emit
        // the fenced-format instructions in the system prompt so the
        // Safari Bridge (claude.ai web strips tool_use content blocks
        // server-side) keeps working through the same code path.
        let session = LanguageModelSession(
            tools: [ReadFileTool(), ListFilesTool(), BashTool()],
            instructions: context.asSystemPrompt()
        )
        let userPrompt = composeUserPrompt(from: messages)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream = session.streamResponse(to: userPrompt)
                    var lastEmitted = ""
                    for try await partial in stream {
                        // FoundationModels emits cumulative strings; we
                        // surface only the new delta so the UI can
                        // append (matching the contract of the other
                        // providers' streams).
                        let text = partial.content
                        if text.hasPrefix(lastEmitted) {
                            let delta = String(text.dropFirst(lastEmitted.count))
                            if !delta.isEmpty { continuation.yield(delta) }
                        } else {
                            continuation.yield(text)
                        }
                        lastEmitted = text
                    }
                    continuation.finish()
                } catch {
                    // FoundationModels throws framework-typed errors (e.g.
                    // `LanguageModelSession.GenerationError.exceededContextWindowSize`)
                    // which the runAssistantTurn fallback chain can't see as
                    // recoverable. Wrap them so when the on-device 4K-token
                    // window can't fit a tool-result follow-up, the chain
                    // continues to the BYO API key (which has 200K).
                    let raw = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    continuation.finish(throwing: AIProviderError.unavailable(
                        reason: "Apple Intelligence: \(raw)",
                        recoverable: true
                    ))
                }
            }
        }
    }

    private func composeUserPrompt(from messages: [ChatMessage]) -> String {
        // FoundationModels' on-device model has a ~4 K-token context
        // window total. The system instructions already eat ~1 K, leaving
        // ~3 K for the user prompt and the model's response combined.
        // Cap the prompt at 10 KB chars (~2.5 K tokens, conservatively).
        // This matters most on tool-result follow-up turns where the
        // synthetic user message contains 3+ file bodies. Apple Intel is
        // the no-API-key user's only fallback when claude.ai drops, so
        // we'd rather truncate aggressively and produce a usable answer
        // than overflow and surface "Exceeded model context window size".
        guard !messages.isEmpty else { return "" }
        let maxPromptChars = 10_000

        // Always include the last user message in full (or as-truncated).
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else {
            return ""
        }
        let lastUser = messages[lastUserIdx]

        if lastUser.content.count > maxPromptChars {
            // Single huge message — likely a tool_result with large file
            // bodies. Truncate from the end of each `[tool_result …]`
            // section so we keep the headers (which tell the model WHICH
            // files were read) and lose only the deepest body content.
            return truncateForLocalModel(lastUser.content, cap: maxPromptChars)
        }

        // Build backwards from the latest message, including history
        // until we run out of budget. The most recent assistant turn is
        // valuable context, older ones less so.
        var lines: [String] = ["User: \(lastUser.content)"]
        var charsUsed = lastUser.content.count + "User: ".count

        for msg in messages[..<lastUserIdx].reversed() where msg.role != .system {
            let prefix = msg.role == .user ? "User: " : "Assistant: "
            let line = prefix + msg.content
            if charsUsed + line.count + 1 > maxPromptChars { break }
            lines.insert(line, at: 0)
            charsUsed += line.count + 1
        }
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }

    /// Truncate a single oversized user message (typically a synthetic
    /// `[tool_result for read_file (path)]\n…bytes…` block) so it fits
    /// the on-device context window. We keep `cap - 200` chars from the
    /// start (preserves headers + early file content) and append a clear
    /// "truncated for the on-device model" tag so the response can call
    /// out the limitation in its answer.
    private func truncateForLocalModel(_ content: String, cap: Int) -> String {
        let head = String(content.prefix(cap - 200))
        return head + "\n\n[…content truncated to fit Apple Intelligence's on-device context window. For full file content, configure a Claude API key in Settings → AI provider.]"
    }
    #endif
}

enum AIProviderError: LocalizedError {
    /// `recoverable: true` means a different provider (Apple Intelligence,
    /// API key) might succeed where this one didn't — used by the
    /// Assistant tab to auto-fallback transparently. `false` means the
    /// failure is a hard one (auth, parse, network) where retrying with
    /// another provider would just hit the same wall.
    case unavailable(reason: String, recoverable: Bool = false)
    case noAPIKey
    case http(status: Int, body: String)
    case decode(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason, _): return reason
        case .noAPIKey: return String(localized: "No Anthropic API key configured. Add one in Settings → AI provider.")
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(200))"
        case .decode(let what): return "Decoding failed: \(what)"
        case .timeout: return String(localized: "Request timed out.")
        }
    }

    /// True when retrying with a different provider may succeed.
    var isRecoverable: Bool {
        if case .unavailable(_, let r) = self { return r }
        return false
    }
}
