import Foundation

/// Connection configuration stays in the product module, outside the read contract.
/// Credentials grant access to live terminals or Edge sessions. Keep them in the
/// existing encrypted provisioning channel and Keychain, never in widget/history storage.
public struct MirrorProvisioning: Codable, Sendable, Equatable {
    public let peerPairingSecret: String?
    public let peerFallbackHost: String?
    public let edgeHost: String?
    public let edgePort: Int?
    public let edgeToken: String?

    public init(peerPairingSecret: String? = nil, peerFallbackHost: String? = nil,
                edgeHost: String? = nil, edgePort: Int? = nil, edgeToken: String? = nil) {
        self.peerPairingSecret = peerPairingSecret
        self.peerFallbackHost = peerFallbackHost
        self.edgeHost = edgeHost
        self.edgePort = edgePort
        self.edgeToken = edgeToken
    }

    public var withoutSecrets: Self {
        Self(peerFallbackHost: peerFallbackHost, edgeHost: edgeHost, edgePort: edgePort)
    }
}
