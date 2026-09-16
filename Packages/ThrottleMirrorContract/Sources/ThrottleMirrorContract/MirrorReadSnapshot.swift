import Foundation

/// Read-only mirror data. Connection settings and provisioning credentials are
/// deliberately absent. Free-form strings still require the sender's outbound policy.
public struct MirrorReadSnapshot: Codable, Sendable, Equatable {
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

    public init(publishedAt: Date, deviceName: String,
                fiveHour: WindowMirror, sevenDay: WindowMirror, sevenDaySonnet: WindowMirror,
                weeklyTokens: Int, weeklyCostEUR: Double, savedTokensThisWeek: Int,
                sessionCount: Int, tabs: [TabMirror],
                schemaVersion: Int = MirrorReadSnapshot.currentSchemaVersion) {
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

    public static func decoded(from data: Data) throws -> MirrorReadSnapshot {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(MirrorReadSnapshot.self, from: data)
    }
}
