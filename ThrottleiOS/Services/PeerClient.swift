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
    private var currentFallbackHost: String?

    /// Feed each freshly-synced snapshot here; picks up (or rotates to) the pairing
    /// secret and (re)starts the LAN link. Also keeps the off-LAN fallback host
    /// current on the existing connector — a host entered/changed in Mac Settings
    /// shouldn't require a fresh pairing secret to take effect.
    func syncPairing(from snapshot: ThrottleMirrorSnapshot) {
        if snapshot.peerFallbackHost != currentFallbackHost {
            currentFallbackHost = snapshot.peerFallbackHost
            connector?.setFallbackHost(currentFallbackHost)
        }
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

    /// True once a LAN peer link exists (pairing secret learned + connector up).
    var hasLink: Bool { connector != nil }

    // MARK: - Remote terminal passthrough

    /// Attach to a Mac session's live terminal. `onOutput`/`onResize` fire on the
    /// connector queue (hop to the main actor before touching UIKit). No-op if the
    /// LAN link isn't up yet (the phone must have paired via a snapshot first).
    func attachTerminal(tabID: String,
                        onOutput: @escaping @Sendable ([UInt8]) -> Void,
                        onResize: @escaping @Sendable (Int, Int) -> Void) {
        guard let c = connector else { return }
        c.onTermOut = onOutput
        c.onTermResize = onResize
        c.attachTerminal(sessionId: tabID)
    }

    func sendTerminalInput(_ bytes: [UInt8]) { connector?.sendInput(bytes) }
    func sendTerminalResize(cols: Int, rows: Int) { connector?.sendResize(cols: cols, rows: rows) }

    func detachTerminal() {
        connector?.detachTerminal()
        connector?.onTermOut = nil
        connector?.onTermResize = nil
    }

    private func restart(with secret: PeerPairingSecret) {
        connector?.stop()
        let c = PeerConnector(secret: secret)
        c.setFallbackHost(currentFallbackHost)
        c.onSnapshot = { data in
            // Fires on the connector's queue; decode off-main then ingest on main.
            guard let snap = try? ThrottleMirrorSnapshot.decoded(from: data) else { return }
            Task { @MainActor in MirrorStore.shared.ingest(snap) }
        }
        c.start()
        connector = c
    }
}
