import Foundation
import ThrottleShared

/// Per-session store of the assistant's most recent batch of tool_use
/// blocks. Keyed by the same `ClaudeWebSessionScope.sessionId` TaskLocal
/// the Web Session provider uses, so the Assistant tab's `send()` →
/// `runAssistantTurn(...)` chain naturally scopes the cache to one
/// user-typed turn. Cleared after recursion ends.
actor APIKeyToolStateStore {
    static let shared = APIKeyToolStateStore()
    private var cache: [UUID: [ClaudeAPIKeyProtocol.ToolUseBlock]] = [:]
    func uses(for id: UUID) -> [ClaudeAPIKeyProtocol.ToolUseBlock] {
        cache[id] ?? []
    }
    func set(_ uses: [ClaudeAPIKeyProtocol.ToolUseBlock], for id: UUID) {
        cache[id] = uses
    }
    func clear(_ id: UUID) {
        cache.removeValue(forKey: id)
    }
}

/// AI provider that talks to Anthropic's official `/v1/messages` API
/// with a user-supplied key. The key is stored in the macOS Keychain
/// (service `com.lorislab.throttle.anthropic`, account `key`).
///
/// Uses Anthropic's native `tool_use` / `tool_result` content blocks
/// (defined in `ClaudeAPIKeyProtocol`) for the read_file / list_files
/// tool flow — provides typed blocks and proper multi-turn
/// linkage. Internally translates the native tool_use blocks back to
/// fenced ```tool blocks in the streamed text so the recursion layer
/// in `ProjectAssistantTab` continues to drive the loop with one
/// parser. Apple Intelligence and the Safari Bridge can't emit native
/// tool_use, so the fenced format is still the lowest-common-denominator
/// for them.
///
/// All cost lands on the user's Anthropic account, not LorisLabs —
/// the provider is BYO key.
struct ClaudeAPIKeyProvider: AIProvider {
    let displayName = "Claude API (your key)"
    let kind: AIProviderKind = .claudeAPIKey

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")
    private let anthropicVersion = "2023-06-01"

    /// The model used per chat is decided by the user's quality
    /// preference. Default is Opus to maximize audit accuracy; users
    /// who care more about latency or per-call cost can opt down.
    @MainActor
    private var modelForCurrentPreference: String {
        switch AIProviderRegistry.shared.qualityPreference {
        case .maxAccuracy: return "claude-opus-4-7"
        case .balanced:    return "claude-sonnet-4-6"
        case .speed:       return "claude-haiku-4-5"
        }
    }

    var isAvailable: Bool {
        get async { ClaudeAPIKeyStore.read() != nil }
    }

    private func makeRequest(body: [String: Any], key: String) throws -> URLRequest {
        guard let endpoint else { throw URLError(.badURL) }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        return req
    }

    func streamChat(
        messages: [ChatMessage],
        context: ProjectChatContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let key = ClaudeAPIKeyStore.read() else {
            throw AIProviderError.noAPIKey
        }
        let model = await modelForCurrentPreference

        // Pull the prior batch of tool_use blocks from the per-session
        // cache so we can rebuild the assistant→user pair as native
        // tool_use + tool_result content blocks. Empty on the first
        // turn (which is the no-tool path).
        let sessionId = ClaudeWebSessionScope.sessionId
        let priorToolUses: [ClaudeAPIKeyProtocol.ToolUseBlock]
        if let id = sessionId {
            priorToolUses = await APIKeyToolStateStore.shared.uses(for: id)
        } else {
            priorToolUses = []
        }

        let body = ClaudeAPIKeyProtocol.buildRequestBody(
            messages: messages,
            system: context.asSystemPrompt(),
            model: model,
            priorToolUses: priorToolUses
        )

        let request = try makeRequest(body: body, key: key)
        try Task.checkCancellation()
        return AsyncThrowingStream { continuation in
            let producer = Task { @Sendable in
                do {
                    let parsed = try await consumeResponse(request, continuation: continuation)
                    try await publishCompleted(parsed, sessionId: sessionId, continuation: continuation)
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    if let id = sessionId { await APIKeyToolStateStore.shared.clear(id) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func consumeResponse(
        _ request: URLRequest, continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> ClaudeAPIKeyProtocol.ParseResult {
        try Task.checkCancellation()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.http(status: -1, body: "non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw AIProviderError.http(status: http.statusCode, body: try await errorBody(bytes))
        }
        var buffer = ClaudeAPIKeyProtocol.EventBuffer()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let payload = try buffer.append(byte) else { continue }
            // Text is provisional. Tools wait for complete stream validation.
            if let text = textDelta(payload) { continuation.yield(text) }
        }
        try Task.checkCancellation()
        return try buffer.finish()
    }

    private func errorBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var collected: [UInt8] = []
        for try await byte in bytes {
            try Task.checkCancellation()
            collected.append(byte)
            if collected.count >= 2048 { break }
        }
        return String(bytes: collected, encoding: .utf8) ?? "Non-UTF-8 HTTP error response"
    }

    private func textDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "content_block_delta",
              let delta = object["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta" else { return nil }
        return delta["text"] as? String
    }

    private func publishCompleted(
        _ parsed: ClaudeAPIKeyProtocol.ParseResult, sessionId: UUID?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        if !parsed.toolUses.isEmpty {
            for use in parsed.toolUses {
                try Task.checkCancellation()
                continuation.yield(ClaudeAPIKeyProtocol.renderAsFencedBlock(use))
            }
            if let id = sessionId { await APIKeyToolStateStore.shared.set(parsed.toolUses, for: id) }
        } else if let id = sessionId {
            await APIKeyToolStateStore.shared.clear(id)
        }
    }

}

/// Keychain helper for the Anthropic API key. Stored as a generic
/// password under service `com.lorislab.throttle.anthropic`.
enum ClaudeAPIKeyStore {
    private static let service = "com.lorislab.throttle.anthropic"
    private static let account = "key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str.isEmpty ? nil : str
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        KeychainStore.set(value, account: account, service: service)
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
