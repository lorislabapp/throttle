import Foundation

/// Picks the active AI provider for the Project window's Assistant tab.
/// Persists the user's choice in UserDefaults; falls back to a sensible
/// default when nothing is set or the previously-chosen provider has
/// become unavailable (e.g. user removed their API key).
@MainActor
final class AIProviderRegistry {
    static let shared = AIProviderRegistry()

    private let defaultsKey = "aiProviderKind"
    private let qualityKey  = "aiQualityPreference"

    private let appleIntel = AppleIntelligenceProvider()
    private let claudeKey  = ClaudeAPIKeyProvider()
    private let claudeWeb  = ClaudeWebSessionProvider()

    private init() {}

    /// User's accuracy/speed preference. Default = .maxAccuracy: the
    /// assistant is an audit tool, wrong recommendations are worse than
    /// slow ones. Users can opt down to .balanced or .speed if they care
    /// about latency or per-call cost more than accuracy.
    var qualityPreference: AIQualityPreference {
        get {
            guard let raw = UserDefaults.standard.string(forKey: qualityKey),
                  let q = AIQualityPreference(rawValue: raw) else {
                return .maxAccuracy
            }
            return q
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: qualityKey)
        }
    }

    /// User's persisted preference, or nil if untouched.
    var preferredKind: AIProviderKind? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let kind = AIProviderKind(rawValue: raw) else { return nil }
            return kind
        }
        set {
            if let new = newValue {
                UserDefaults.standard.set(new.rawValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    func provider(for kind: AIProviderKind) -> any AIProvider {
        switch kind {
        case .appleIntelligence: return appleIntel
        case .claudeAPIKey:      return claudeKey
        case .claudeWebSession:  return claudeWeb
        }
    }

    /// Resolve the provider to use right now. If the user has a preference
    /// and that provider is available, use it. Otherwise walk the default
    /// order: Apple Intelligence → ClaudeWebSession → ClaudeAPIKey, and
    /// pick the first one that's available. Returns nil if nothing works
    /// (no API key, no Apple Intel, no Safari session).
    func resolveActive() async -> (any AIProvider)? {
        if let preferred = preferredKind {
            let p = provider(for: preferred)
            if await p.isAvailable { return p }
        }
        for kind in [AIProviderKind.appleIntelligence,
                     .claudeWebSession,
                     .claudeAPIKey] {
            let p = provider(for: kind)
            if await p.isAvailable { return p }
        }
        return nil
    }

    /// Walk the default order (Apple Intelligence → ClaudeWebSession →
    /// ClaudeAPIKey) and return the first provider that is currently
    /// available AND whose kind is not in `excluding`. Used by the
    /// Assistant tab to transparently fall back when the active provider
    /// returns a recoverable error (claude.ai dropped the response,
    /// Safari tab zombie, etc.) so the user gets a working answer
    /// instead of having to manually switch providers.
    func firstAvailable(excluding: Set<AIProviderKind>) async -> (any AIProvider)? {
        for kind in [AIProviderKind.appleIntelligence,
                     .claudeWebSession,
                     .claudeAPIKey] where !excluding.contains(kind) {
            let p = provider(for: kind)
            if await p.isAvailable { return p }
        }
        return nil
    }

    func availabilityMap() async -> [AIProviderKind: Bool] {
        var map: [AIProviderKind: Bool] = [:]
        map[.appleIntelligence] = await appleIntel.isAvailable
        map[.claudeWebSession]  = await claudeWeb.isAvailable
        map[.claudeAPIKey]      = await claudeKey.isAvailable
        return map
    }
}
