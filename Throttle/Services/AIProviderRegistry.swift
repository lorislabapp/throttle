import Foundation

/// The outcome of resolving the user's provider choice. Throttle never picks
/// a provider on the user's behalf: switching silently could send project
/// context to a cloud service the user did not choose (OptionalAI rule,
/// 2026-10-21 AI inventory finding).
enum AIProviderSelection: Equatable, Sendable {
    /// The provider the user chose, and it is available.
    case ready(AIProviderKind)
    /// The user has not chosen a provider yet; show the picker.
    case notChosen
    /// The chosen provider is unavailable; say so instead of switching.
    case chosenUnavailable(AIProviderKind)
    /// Local-only was requested but the chosen provider is a network one.
    case chosenNotLocal(AIProviderKind)

    /// Providers whose requests stay on this Mac.
    static let localKinds: Set<AIProviderKind> = [.appleIntelligence, .embeddedModel]

    static func resolve(
        preferred: AIProviderKind?,
        preferredIsAvailable: Bool,
        localOnly: Bool = false
    ) -> AIProviderSelection {
        guard let preferred else { return .notChosen }
        if localOnly && !localKinds.contains(preferred) { return .chosenNotLocal(preferred) }
        return preferredIsAvailable ? .ready(preferred) : .chosenUnavailable(preferred)
    }

    /// User-facing explanation for every state but `.ready`.
    var message: String? {
        switch self {
        case .ready:
            return nil
        case .notChosen:
            return "Choose an AI provider in the Assistant tab first. Throttle never picks one for you."
        case .chosenUnavailable(let kind):
            return "\(kind.displayLabel) is not available right now. "
                + "Throttle won't switch to another provider on its own — "
                + "fix it or choose another provider in the Assistant tab."
        case .chosenNotLocal(let kind):
            return "Local-only refinement is on, but your chosen provider (\(kind.displayLabel)) "
                + "sends text off this Mac. Choose Apple Intelligence or the local model, "
                + "or turn off local-only."
        }
    }
}

extension AIProviderKind {
    var displayLabel: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .embeddedModel:     return "The local model"
        case .claudeWebSession:  return "Claude (claude.ai)"
        case .claudeAPIKey:      return "Claude API"
        }
    }
}

/// Picks the active AI provider for the Project window's Assistant tab.
/// Persists the user's choice in UserDefaults and only ever returns that
/// provider: when nothing is chosen or the choice is unavailable, callers get
/// nil (and `selection()` says why) so the UI can ask instead of switching.
@MainActor
final class AIProviderRegistry {
    static let shared = AIProviderRegistry()

    private let defaultsKey = "aiProviderKind"
    private let qualityKey  = "aiQualityPreference"

    private let appleIntel = AppleIntelligenceProvider()
    private let embedded   = EmbeddedModelProvider()
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
        case .claudeAPIKey:      return claudeKey
        case .claudeWebSession:  return claudeWeb
        }
    }

    /// Resolve the user's explicit choice. Never falls back to another
    /// provider; see `AIProviderSelection`.
    func selection(localOnly: Bool = false) async -> AIProviderSelection {
        guard let preferred = preferredKind else { return .notChosen }
        let available = await provider(for: preferred).isAvailable
        return AIProviderSelection.resolve(
            preferred: preferred, preferredIsAvailable: available, localOnly: localOnly
        )
    }

    /// The chosen provider when it is ready, otherwise nil.
    func resolveActive(localOnly: Bool = false) async -> (any AIProvider)? {
        guard case .ready(let kind) = await selection(localOnly: localOnly) else { return nil }
        return provider(for: kind)
    }

    func availabilityMap() async -> [AIProviderKind: Bool] {
        var map: [AIProviderKind: Bool] = [:]
        map[.appleIntelligence] = await appleIntel.isAvailable
        map[.embeddedModel]     = await embedded.isAvailable
        map[.claudeWebSession]  = await claudeWeb.isAvailable
        map[.claudeAPIKey]      = await claudeKey.isAvailable
        return map
    }
}
