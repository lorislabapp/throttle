import Foundation

/// Picks the active AI provider for the Project window's Assistant tab.
/// Persists the user's exact choice in UserDefaults. Availability never grants
/// consent to switch to a cloud provider or a separately billed API account.
@MainActor
final class AIProviderRegistry {
    static let shared = AIProviderRegistry()

    private let defaultsKey = "aiProviderKind"
    private let qualityKey  = "aiQualityPreference"

    private let appleIntel = AppleIntelligenceProvider()
    private let embedded   = EmbeddedModelProvider()
    private let selfHosted = EmbeddedModelProvider(destination: .selfHosted)
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
        case .embeddedModel:     return embedded
        case .selfHostedModel:   return selfHosted
        case .claudeAPIKey:      return claudeKey
        case .claudeWebSession:  return claudeWeb
        }
    }

    /// An unavailable explicit choice stays unavailable. With no preference,
    /// only the existing local kinds are probed; configured cloud keys/sessions
    /// never silently become the default.
    func resolveActive() async -> (any AIProvider)? {
        let candidates = AIProviderRoutingPolicy.initialCandidates(preferred: preferredKind)
        for kind in candidates {
            let candidate = provider(for: kind)
            if await candidate.isAvailable { return candidate }
        }
        return nil
    }

    /// Filter before availability probes; configuration editing never contacts a server.
    /// An explicit network preference stays unchanged and returns unavailable here.
    func resolveOnDevice() async -> (any AIProvider)? {
        let candidates = AIProviderRoutingPolicy.initialCandidates(preferred: preferredKind)
        for kind in candidates where kind.runsOnDevice {
            let candidate = provider(for: kind)
            if await candidate.isAvailable { return candidate }
        }
        return nil
    }

    /// Shared by Assistant and PromptRefiner. Failed local requests
    /// cannot escalate to cloud, and a failed subscription cannot spend an API
    /// key merely because one is configured. Capture candidates before awaiting.
    func firstAvailable(excluding: Set<AIProviderKind>) async -> (any AIProvider)? {
        let candidates = AIProviderRoutingPolicy.fallbackCandidates(
            preferred: preferredKind,
            excluding: excluding
        )
        for kind in candidates {
            let candidate = provider(for: kind)
            if await candidate.isAvailable { return candidate }
        }
        return nil
    }

    func availabilityMap() async -> [AIProviderKind: Bool] {
        var map: [AIProviderKind: Bool] = [:]
        map[.appleIntelligence] = await appleIntel.isAvailable
        map[.embeddedModel]     = await embedded.isAvailable
        map[.selfHostedModel]   = await selfHosted.isAvailable
        map[.claudeWebSession]  = await claudeWeb.isAvailable
        map[.claudeAPIKey]      = await claudeKey.isAvailable
        return map
    }
}
