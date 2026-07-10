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

/// The full payload the Mac publishes to the user's CloudKit private DB and the
/// iPhone mirrors. Small (a few KB even with 16 tabs) — stored as one JSON blob
/// in an encrypted CKRecord field so adding fields never forces a CloudKit
/// schema redeploy (only a `schemaVersion` bump the phone tolerates).
public struct ThrottleMirrorSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let publishedAt: Date
    public let deviceName: String

    public let fiveHour: WindowMirror
    public let sevenDay: WindowMirror
    public let sevenDaySonnet: WindowMirror

    public let weeklyTokens: Int
    public let weeklyCostEUR: Double
    public let savedTokensThisWeek: Int
    public let sessionCount: Int
    public let tabs: [TabMirror]

    /// Base64 of the 32-byte LAN peer pairing secret. Rides inside this encrypted
    /// blob so the phone can bootstrap the P2P fast path from the first CloudKit
    /// sync — no separate CloudKit record, no schema redeploy. Optional/nil when the
    /// peer mirror is off or the publisher is an older build.
    public let peerPairingSecret: String?

    public init(publishedAt: Date, deviceName: String,
                fiveHour: WindowMirror, sevenDay: WindowMirror, sevenDaySonnet: WindowMirror,
                weeklyTokens: Int, weeklyCostEUR: Double, savedTokensThisWeek: Int,
                sessionCount: Int, tabs: [TabMirror],
                peerPairingSecret: String? = nil,
                schemaVersion: Int = ThrottleMirrorSnapshot.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.deviceName = deviceName
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.weeklyTokens = weeklyTokens
        self.weeklyCostEUR = weeklyCostEUR
        self.savedTokensThisWeek = savedTokensThisWeek
        self.sessionCount = sessionCount
        self.tabs = tabs
        self.peerPairingSecret = peerPairingSecret
    }

    // MARK: Binding window (the "worst" of 5h/7d) — mirrors the Mac's rule.

    /// The window closest to its cap; that's the number the meter binds to.
    public var bindingWindow: WindowMirror {
        [fiveHour, sevenDay, sevenDaySonnet].max { $0.utilization < $1.utilization } ?? fiveHour
    }

    // MARK: JSON blob (the CloudKit payload + local history record)

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decoded(from data: Data) throws -> ThrottleMirrorSnapshot {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(ThrottleMirrorSnapshot.self, from: data)
    }
}
