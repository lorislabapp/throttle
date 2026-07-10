import Foundation
import Network

/// Builds the `NWParameters` for the peer link: TCP + TLS 1.2 with an **external
/// pre-shared key** derived from the CloudKit-shared pairing secret. Validated at
/// runtime (loopback handshake + framed round-trip) before wiring the transport.
///
/// External PSK on Network.framework requires: `add_pre_shared_key(key, identity)`,
/// an explicitly appended TLS 1.2 PSK ciphersuite, and pinning min == max == TLS 1.2
/// (TLS 1.3 external-PSK selection differs and isn't needed for one small stream).
enum PeerTLS {
    static func parameters(secret: PeerPairingSecret) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        let psk = PeerPairing.preSharedKeyData(from: secret)
        let keyDD = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let hintDD = Data(PeerPairing.pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyDD as __DispatchData, hintDD as __DispatchData)
        // TLS_PSK_WITH_AES_128_GCM_SHA256 is an SSLCipherSuite (UInt32); the enum
        // raw value is UInt16 — narrow explicitly (value 0x00A8 fits).
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true   // allow AWDL/peer-to-peer Wi-Fi paths
        return params
    }

    /// Milliseconds since epoch — stamped on every frame for latency/debug.
    static func nowMillis() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}
