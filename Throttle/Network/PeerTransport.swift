import Foundation
import ThrottlePeer
import ThrottleShared

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

    /// Legacy UserDefaults key, read once for migration then deleted.
    private static let secretKey = "throttlePeerPairingSecretV1"
    private static let secretAccount = "peerPairingSecret"
    private static let fallbackHostKey = "throttlePeerFallbackHostV1"
    private let secret: PeerPairingSecret
    private var advertiser: PeerAdvertiser?
    private var started = false

    /// Base64 secret stamped into every mirror snapshot so the phone can pair.
    var pairingSecretBase64: String { secret.base64 }

    /// User-entered tailnet host (IP or MagicDNS name) this Mac is reachable at on
    /// `PeerPairing.fallbackPort`, for the off-LAN path. Persisted + stamped into
    /// every mirror snapshot so the phone learns it without a separate pairing step.
    var fallbackHost: String? {
        get { UserDefaults.standard.string(forKey: Self.fallbackHostKey) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set((trimmed?.isEmpty == false) ? trimmed : nil, forKey: Self.fallbackHostKey)
        }
    }

    private init() {
        // Keychain, not UserDefaults. This secret authorises a device to receive
        // the mirror of every session, and it lived in a plist any process
        // running as this user could read — while the edge-agent bearer token,
        // twenty lines away in another file, was already in the Keychain with
        // the comment "Bearer token controls a remote session → Keychain, not
        // UserDefaults". The same sentence applies here and was not followed.
        if let b64 = KeychainStore.get(account: Self.secretAccount),
           let existing = PeerPairingSecret(base64: b64) {
            secret = existing
        } else if let legacy = UserDefaults.standard.string(forKey: Self.secretKey),
                  let existing = PeerPairingSecret(base64: legacy) {
            // Migrate in place, then remove the plaintext copy. Keeping the pair
            // would leave the weaker of the two as the real security boundary.
            _ = KeychainStore.set(legacy, account: Self.secretAccount)
            UserDefaults.standard.removeObject(forKey: Self.secretKey)
            secret = existing
        } else {
            let fresh = PeerPairingSecret.generate()
            _ = KeychainStore.set(fresh.base64, account: Self.secretAccount)
            UserDefaults.standard.removeObject(forKey: Self.secretKey)
            secret = fresh
        }
    }

    /// Begin advertising on the LAN. Fail-open (PeerAdvertiser never throws).
    func start() {
        guard !started else { return }
        // Pin the fixed port always (not just when a fallback host is set): Bonjour
        // resolves whatever port we bind on the LAN either way, and pinning it means
        // flipping on a tailnet host later never requires restarting the listener.
        let adv = PeerAdvertiser(secret: secret, serviceName: Host.current().localizedName ?? "Mac",
                                  fixedPort: PeerPairing.fallbackPort)
        // Route peer terminal control frames to the cockpit bridge (main actor).
        adv.onTerminalControl = { control, client in
            Task { @MainActor in PeerTerminalBridge.shared.handle(control, from: client) }
        }
        adv.start()
        advertiser = adv
        started = true
    }

    func stop() {
        advertiser?.stop()
        advertiser = nil
        started = false
        PeerTerminalBridge.shared.reset()
    }

    // MARK: Remote terminal (bridge → peer)

    /// Forward raw PTY output to a specific attached peer.
    func sendTerminalOutput(_ bytes: [UInt8], to client: PeerClientID) {
        advertiser?.sendTerminalOutput(bytes, to: client)
    }

    /// Tell a peer the Mac terminal's authoritative geometry.
    func sendTerminalResize(cols: Int, rows: Int, to client: PeerClientID) {
        advertiser?.sendTerminalResize(cols: cols, rows: rows, to: client)
    }

    // MARK: MirrorTransport

    func publish(_ snapshot: ThrottleMirrorSnapshot) {
        guard started, let advertiser, let data = try? snapshot.encoded() else { return }
        advertiser.publish(data)
    }
}
