import Foundation
import CryptoKit

/// The 32-byte pairing secret both devices read from the shared CloudKit **private**
/// DB (a record only the iCloud account owner can read). Because both ends already
/// share the user's iCloud account, CloudKit is the trust root — no QR/PIN. The
/// secret never travels over the LAN; each end derives the identical TLS pre-shared
/// key from it locally.
public struct PeerPairingSecret: Sendable, Equatable {
    /// Raw 32 bytes. Kept out of logs/description on purpose.
    public let raw: Data

    public init?(raw: Data) {
        guard raw.count == 32 else { return nil }
        self.raw = raw
    }

    public init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(raw: data)
    }

    public var base64: String { raw.base64EncodedString() }

    /// Fresh cryptographically-random secret (call once on the Mac, store in CloudKit).
    public static func generate() -> PeerPairingSecret {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PeerPairingSecret(raw: Data(bytes))!
    }
}

/// Derives the TLS-PSK (and the shared service parameters) from the pairing secret
/// via HKDF-SHA256, so advertiser and browser compute a byte-identical key without
/// exchanging it. Bumping `info` rotates the key domain across protocol versions.
public enum PeerPairing {
    /// Bonjour service type advertised by the Mac for the iOS mirror.
    public static let serviceType = "_throttle._tcp"

    /// Non-secret PSK identity hint so both ends select the same key slot.
    public static let pskIdentity = "throttle-peer-v1"

    private static let info = Data("throttle-peer-psk-v1".utf8)

    /// The 32-byte pre-shared key both ends feed to `NWProtocolTLS`.
    public static func preSharedKey(from secret: PeerPairingSecret) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret.raw),
            info: info,
            outputByteCount: 32)
    }

    /// The PSK as raw `Data` (for the `sec_protocol_options_add_pre_shared_key` call
    /// site, which wants a `dispatch_data_t`/bytes rather than a `SymmetricKey`).
    public static func preSharedKeyData(from secret: PeerPairingSecret) -> Data {
        preSharedKey(from: secret).withUnsafeBytes { Data($0) }
    }
}
