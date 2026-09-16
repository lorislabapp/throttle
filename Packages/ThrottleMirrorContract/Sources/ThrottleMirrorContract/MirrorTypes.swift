import Foundation

/// One rolling-usage window, mirrored Mac → iPhone. A pure twin of the Mac
/// app's `ExactSnapshot.Window` (integer utilization 0–100 + absolute reset
/// wall-clock). Kept separate from the Mac type so this module never imports
/// the app; the Mac side adapts across with `init(from:)` at publish time.
public struct WindowMirror: Codable, Sendable, Equatable {
    public let utilization: Int          // 0…100
    public let resetsAt: Date?           // absolute UTC moment the window expires

    public init(utilization: Int, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// Canonical session-state labels, shared so the Mac projection and the iOS
/// renderer can never disagree on the string. Mirrors `CockpitTab.SessionState`.
public enum SessionStateMirror: String, Codable, Sendable, CaseIterable {
    case dormant, hibernated, rateLimited, paused, working, waiting, idle
}

/// A read-only projection of one Cockpit session/tab, safe to ship to iOS.
/// `CockpitTab` itself is `@MainActor` + SwiftTerm-coupled and cannot leave the
/// Mac; this is the flat, Codable slice the phone renders.
public struct TabMirror: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectName: String
    public let state: String             // SessionState raw label (dormant/working/waiting/…)
    public let model: String?
    public let eur: Double?
    public let tokens: Int?
    public let isLive: Bool
    public let needsInput: Bool
    public let rateLimitedUntil: Date?

    /// Typed view of `state` (nil if an unknown/newer label arrives).
    public var stateKind: SessionStateMirror? { SessionStateMirror(rawValue: state) }

    public init(id: String, projectName: String, state: String, model: String?,
                eur: Double?, tokens: Int?, isLive: Bool, needsInput: Bool,
                rateLimitedUntil: Date?) {
        self.id = id
        self.projectName = projectName
        self.state = state
        self.model = model
        self.eur = eur
        self.tokens = tokens
        self.isLive = isLive
        self.needsInput = needsInput
        self.rateLimitedUntil = rateLimitedUntil
    }
}
