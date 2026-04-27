import Foundation

struct UsageSnapshot: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        let kind: WindowKind
        let usedTokens: Int
        let capTokens: Int?            // nil if not yet calibrated
        let resetInSeconds: Int64

        var percentUsed: Double? {
            guard let cap = capTokens, cap > 0 else { return nil }
            return min(1.0, Double(usedTokens) / Double(cap))
        }
    }

    let session5h: Window
    let weeklyAll: Window
    let weeklySonnet: Window
    let computedAt: Date

    /// True when there are zero usage events at all — drives the empty state.
    let hasAnyData: Bool

    static let empty = UsageSnapshot(
        session5h: Window(kind: .session5h, usedTokens: 0, capTokens: nil, resetInSeconds: 0),
        weeklyAll: Window(kind: .weeklyAll, usedTokens: 0, capTokens: nil, resetInSeconds: 0),
        weeklySonnet: Window(kind: .weeklySonnet, usedTokens: 0, capTokens: nil, resetInSeconds: 0),
        computedAt: .distantPast,
        hasAnyData: false
    )
}
