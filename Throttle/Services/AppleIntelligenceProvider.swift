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
        let session = LanguageModelSession(instructions: context.asSystemPrompt())
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
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func composeUserPrompt(from messages: [ChatMessage]) -> String {
        // FoundationModels' single-prompt API takes one user string —
        // collapse the chat history into a single transcript so the
        // model has the conversation arc.
        guard !messages.isEmpty else { return "" }
        if messages.count == 1, let only = messages.first { return only.content }
        var lines: [String] = []
        for msg in messages {
            switch msg.role {
            case .user:      lines.append("User: \(msg.content)")
            case .assistant: lines.append("Assistant: \(msg.content)")
            case .system:    continue
            }
        }
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }
    #endif
}

enum AIProviderError: LocalizedError {
    case unavailable(reason: String)
    case noAPIKey
    case http(status: Int, body: String)
    case decode(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .noAPIKey: return String(localized: "No Anthropic API key configured. Add one in Settings → AI provider.")
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(200))"
        case .decode(let what): return "Decoding failed: \(what)"
        case .timeout: return String(localized: "Request timed out.")
        }
    }
}
