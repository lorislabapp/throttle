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
