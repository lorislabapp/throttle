import Foundation

/// AI provider that reuses the user's logged-in claude.ai Safari session
/// to call Claude under their existing Pro/Max subscription. No API key,
/// no extra cost — the request is counted against their plan.
///
/// **Status: stub.** Reverse-engineering the claude.ai chat endpoint is
/// non-trivial (CSRF tokens, conversation creation, SSE framing differ
/// from the official API), so v2.1 ships with this provider returning
/// "coming soon" while we use Apple Intelligence + BYO key. We'll wire
/// the real flow once we've validated the protocol against a recent
/// Safari session in v2.1.x.
struct ClaudeWebSessionProvider: AIProvider {
    let displayName = "Claude (via your subscription)"

    var isAvailable: Bool {
        get async { false }
    }

    func streamChat(
        messages: [ChatMessage],
        context: ProjectChatContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw AIProviderError.unavailable(
            reason: String(localized: "Claude web session is coming in 2.1.x. For now use Apple Intelligence (if your Mac supports it) or paste an Anthropic API key in Settings → AI provider.")
        )
    }
}
