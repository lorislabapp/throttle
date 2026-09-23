import Foundation
import ThrottleMirrorContract

public typealias WindowMirror = ThrottleMirrorContract.WindowMirror
public typealias SessionStateMirror = ThrottleMirrorContract.SessionStateMirror
public typealias TabMirror = ThrottleMirrorContract.TabMirror
public typealias MirrorReadSnapshot = ThrottleMirrorContract.MirrorReadSnapshot

/// Product envelope: public read data plus private-product provisioning.
/// Codable deliberately preserves the existing flat JSON for installed peers.
public struct ThrottleMirrorSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = MirrorReadSnapshot.currentSchemaVersion
    public let readSnapshot: MirrorReadSnapshot
    public let provisioning: MirrorProvisioning

    public var schemaVersion: Int { readSnapshot.schemaVersion }
    public var publishedAt: Date { readSnapshot.publishedAt }
    public var deviceName: String { readSnapshot.deviceName }
    public var fiveHour: WindowMirror { readSnapshot.fiveHour }
    public var sevenDay: WindowMirror { readSnapshot.sevenDay }
    public var sevenDaySonnet: WindowMirror { readSnapshot.sevenDaySonnet }
    public var weeklyTokens: Int { readSnapshot.weeklyTokens }
    public var weeklyCostEUR: Double { readSnapshot.weeklyCostEUR }
    public var savedTokensThisWeek: Int { readSnapshot.savedTokensThisWeek }
    public var sessionCount: Int { readSnapshot.sessionCount }
    public var tabs: [TabMirror] { readSnapshot.tabs }
    public var peerPairingSecret: String? { provisioning.peerPairingSecret }
    public var peerFallbackHost: String? { provisioning.peerFallbackHost }
    public var edgeHost: String? { provisioning.edgeHost }
    public var edgePort: Int? { provisioning.edgePort }
    public var edgeToken: String? { provisioning.edgeToken }

    public var bindingWindow: WindowMirror { readSnapshot.bindingWindow }

    /// Disk-safe legacy projection: removes both credential fields, retaining
    /// endpoint metadata for compatibility. Use readSnapshot to exclude all provisioning.
    public var withoutSecrets: Self {
        Self(readSnapshot: readSnapshot, provisioning: provisioning.withoutSecrets)
    }

    public init(readSnapshot: MirrorReadSnapshot, provisioning: MirrorProvisioning = .init()) {
        self.readSnapshot = readSnapshot
        self.provisioning = provisioning
    }

    public init(publishedAt: Date, deviceName: String,
                fiveHour: WindowMirror, sevenDay: WindowMirror, sevenDaySonnet: WindowMirror,
                weeklyTokens: Int, weeklyCostEUR: Double, savedTokensThisWeek: Int,
                sessionCount: Int, tabs: [TabMirror],
                peerPairingSecret: String? = nil,
                peerFallbackHost: String? = nil,
                edgeHost: String? = nil, edgePort: Int? = nil, edgeToken: String? = nil,
                schemaVersion: Int = ThrottleMirrorSnapshot.currentSchemaVersion) {
        self.readSnapshot = MirrorReadSnapshot(
            publishedAt: publishedAt, deviceName: deviceName,
            fiveHour: fiveHour, sevenDay: sevenDay, sevenDaySonnet: sevenDaySonnet,
            weeklyTokens: weeklyTokens, weeklyCostEUR: weeklyCostEUR,
            savedTokensThisWeek: savedTokensThisWeek, sessionCount: sessionCount,
            tabs: tabs, schemaVersion: schemaVersion
        )
        self.provisioning = MirrorProvisioning(
            peerPairingSecret: peerPairingSecret, peerFallbackHost: peerFallbackHost,
            edgeHost: edgeHost, edgePort: edgePort, edgeToken: edgeToken
        )
    }

    public init(from decoder: any Decoder) throws {
        readSnapshot = try MirrorReadSnapshot(from: decoder)
        provisioning = try MirrorProvisioning(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try readSnapshot.encode(to: encoder)
        try provisioning.encode(to: encoder)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }
}
