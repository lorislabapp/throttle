import Foundation
import ThrottleShared
import ThrottlePeer

/// iOS side of the LAN mirror fast path. Learns the pairing secret from the first
/// CloudKit-synced snapshot (`peerPairingSecret`), then browses for the Mac and
/// streams snapshots over TLS-PSK — sub-second when both are on the same Wi-Fi.
///
/// Opportunistic and additive: every received snapshot goes through the SAME
/// `MirrorStore.ingest` path as CloudKit, which dedups by `publishedAt`, so the two
/// transports never fight — whichever delivers a newer snapshot wins, and CloudKit
/// remains the off-network fallback.
@MainActor
final class PeerClient {
    static let shared = PeerClient()
    private init() {}

    private var connector: PeerConnector?
    private var currentSecretB64: String?

    /// Feed each freshly-synced snapshot here; picks up (or rotates to) the pairing
    /// secret and (re)starts the LAN link. No-op if the secret is unchanged/absent.
    func syncPairing(from snapshot: ThrottleMirrorSnapshot) {
        guard let b64 = snapshot.peerPairingSecret,
              b64 != currentSecretB64,
              let secret = PeerPairingSecret(base64: b64) else { return }
        currentSecretB64 = b64
        restart(with: secret)
    }

    func stop() {
        connector?.stop()
        connector = nil
        currentSecretB64 = nil
    }

    private func restart(with secret: PeerPairingSecret) {
        connector?.stop()
        let c = PeerConnector(secret: secret)
        c.onSnapshot = { data in
            // Fires on the connector's queue; decode off-main then ingest on main.
            guard let snap = try? ThrottleMirrorSnapshot.decoded(from: data) else { return }
            Task { @MainActor in MirrorStore.shared.ingest(snap) }
        }
        c.start()
        connector = c
    }
}
