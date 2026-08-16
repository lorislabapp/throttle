import Foundation

/// Usage emitted by Codex itself in local rollout `token_count` events.
///
/// Rate windows are intentionally provider-native: Throttle does not rename an
/// unknown window to "5h" or "weekly", and it never combines Codex with Claude.
struct CodexUsageSnapshot: Sendable, Equatable {
    struct Tokens: Sendable, Equatable {
        let input: Int
        let cachedInput: Int
        let output: Int
        let reasoning: Int
        let total: Int
    }

    struct RateWindow: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable {
            case primary
            case secondary
        }

        let kind: Kind
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Date?

        var id: Kind { kind }
        var normalizedUsed: Double { min(1, max(0, usedPercent / 100)) }
    }

    let sessionID: String?
    let tokens: Tokens?
    let contextWindow: Int?
    let primary: RateWindow?
    let secondary: RateWindow?
    let planType: String?
    let observedAt: Date

    var windows: [RateWindow] { [primary, secondary].compactMap { $0 } }
    var highestPressure: Double? { windows.map(\.normalizedUsed).max() }

    /// A local event is authoritative for the instant it was emitted, but can
    /// miss usage from another device. Never headline an old observation.
    func isFresh(now: Date = Date(), tolerance: TimeInterval = 10 * 60) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= -60 && age < tolerance
    }
}
