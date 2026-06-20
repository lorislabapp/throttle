import Foundation

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
/// tool flow — gives free retry-on-malformed and proper multi-turn
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

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
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

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let request = req
        return AsyncThrowingStream { continuation in
            Task { @Sendable in
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.http(status: -1, body: "non-HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var collected = ""
                        for try await line in bytes.lines {
                            collected += line + "\n"
                            if collected.count > 2048 { break }
                        }
                        throw AIProviderError.http(status: http.statusCode, body: collected)
                    }

                    // Stream text deltas LIVE so the chat bubble feels
                    // responsive. Buffer the full event stream too,
                    // then parse it once at the end to extract any
                    // tool_use blocks (which we render as fenced text
                    // and yield AFTER the live text deltas — the
                    // recursion layer parses the full accumulated
                    // bubble, so timing within a single turn is fine).
                    var collectedEvents: [String] = []
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" || payload.isEmpty { continue }
                        collectedEvents.append(payload)
                        // Live text-delta yield for snappy streaming.
                        if let data = payload.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           obj["type"] as? String == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }
                    }

                    // After the stream completes, extract tool_use
                    // blocks and re-emit them as fenced ```tool blocks
                    // so the existing ProjectAssistantTab recursion
                    // picks them up. Persist for the next turn so we
                    // can rebuild a proper tool_use ↔ tool_result chain.
                    let parsed = ClaudeAPIKeyProtocol.parseSSEEvents(collectedEvents)
                    if !parsed.toolUses.isEmpty {
                        for use in parsed.toolUses {
                            continuation.yield(ClaudeAPIKeyProtocol.renderAsFencedBlock(use))
                        }
                        if let id = sessionId {
                            await APIKeyToolStateStore.shared.set(parsed.toolUses, for: id)
                        }
                    } else if let id = sessionId {
                        // No tool_use this turn: clear the cache so a
                        // future turn doesn't accidentally rebuild a
                        // stale tool_use chain.
                        await APIKeyToolStateStore.shared.clear(id)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Keychain helper for the Anthropic API key. Stored as a generic
/// password under service `com.lorislab.throttle.anthropic`.
enum ClaudeAPIKeyStore {
    private static let service = "com.lorislab.throttle.anthropic"
    private static let account = "key"

    static func read() -> String? {
        var query: [String: Any] = [
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
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // M17: keep the Anthropic API key on THIS device — never sync it to iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(attrs as CFDictionary)
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
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
