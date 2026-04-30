import Foundation

/// AI provider that talks to Anthropic's official `/v1/messages` API
/// with a user-supplied key. The key is stored in the macOS Keychain
/// (service `com.lorislab.throttle.anthropic`, account `key`).
///
/// Streams via SSE; emits text deltas as the server produces them.
/// All cost lands on the user's Anthropic account, not LorisLabs —
/// the provider is BYO key.
struct ClaudeAPIKeyProvider: AIProvider {
    let displayName = "Claude API (your key)"

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

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(key, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": context.asSystemPrompt(),
            "messages": messages
                .filter { $0.role != .system }
                .map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
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

                    for try await line in bytes.lines {
                        // SSE frames: "data: {json}". The Anthropic
                        // streaming protocol emits content_block_delta
                        // events with a {"delta":{"type":"text_delta","text":"…"}}
                        // payload — yield only those deltas.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" || payload.isEmpty { continue }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let type = obj["type"] as? String,
                           type == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }
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
            kSecValueData as String: data
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
