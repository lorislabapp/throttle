import Foundation
import ThrottleShared
import ThrottlePeer

/// Mac-side LAN mirror transport: wraps `PeerAdvertiser` and conforms to
/// `MirrorTransport` so `MirrorFanout` treats it like any other sink. Opt-in and
/// PRO-gated exactly like the CloudKit publisher; when off it's a registered no-op.
///
/// The pairing secret is generated once per Mac and persisted (base64) so it stays
/// stable across launches — the phone learns it from the CloudKit-synced snapshot
/// (`ThrottleMirrorSnapshot.peerPairingSecret`) and derives the identical TLS-PSK.
@MainActor
final class PeerTransport: MirrorTransport {
    static let shared = PeerTransport()

    private static let secretKey = "throttlePeerPairingSecretV1"
    private let secret: PeerPairingSecret
    private var advertiser: PeerAdvertiser?
    private var started = false

    /// Base64 secret stamped into every mirror snapshot so the phone can pair.
    var pairingSecretBase64: String { secret.base64 }

    private init() {
        if let b64 = UserDefaults.standard.string(forKey: Self.secretKey),
           let existing = PeerPairingSecret(base64: b64) {
            secret = existing
        } else {
            let fresh = PeerPairingSecret.generate()
            UserDefaults.standard.set(fresh.base64, forKey: Self.secretKey)
            secret = fresh
        }
    }

    /// Begin advertising on the LAN. Fail-open (PeerAdvertiser never throws).
    func start() {
        guard !started else { return }
        let adv = PeerAdvertiser(secret: secret, serviceName: Host.current().localizedName ?? "Mac")
        adv.start()
        advertiser = adv
        started = true
    }

    func stop() {
        advertiser?.stop()
        advertiser = nil
        started = false
    }

    // MARK: MirrorTransport

    func publish(_ snapshot: ThrottleMirrorSnapshot) {
        guard started, let advertiser, let data = try? snapshot.encoded() else { return }
        advertiser.publish(data)
    }
}
