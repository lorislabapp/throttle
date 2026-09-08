import Foundation
import ThrottlePeer
import ThrottleShared

@MainActor
protocol MirrorPeerConnecting: AnyObject {
    var onSnapshot: (@Sendable (Data) -> Void)? { get set }
    var onConnected: (@Sendable (Bool) -> Void)? { get set }
    var onTermOut: (@Sendable ([UInt8]) -> Void)? { get set }
    var onTermResize: (@Sendable (Int, Int) -> Void)? { get set }
    func start()
    func stop()
    func attachTerminal(sessionId: String)
    func sendInput(_ bytes: [UInt8])
    func sendResize(cols: Int, rows: Int)
    func detachTerminal()
}

extension PeerConnector: MirrorPeerConnecting {}

/// iOS side of the LAN mirror fast path. Learns the pairing secret from the first
/// CloudKit-synced snapshot (`peerPairingSecret`), then browses for the Mac and
/// streams snapshots over TLS-PSK — sub-second when both are on the same Wi-Fi.
///
/// Opportunistic and additive: every received snapshot goes through the SAME
/// `MirrorStore.ingest` path as CloudKit, which dedups by `publishedAt`, so the two
/// transports never fight — whichever delivers a newer snapshot wins, and CloudKit
/// remains the off-network fallback.
@MainActor
@Observable
final class PeerClient {
    static let shared = PeerClient(allowsConnections: !CompanionRuntime.isTesting)
    private let makeConnector: (PeerPairingSecret) -> any MirrorPeerConnecting
    private let ingest: (ThrottleMirrorSnapshot) -> Void
    private let allowsConnections: Bool
    private var generation: UInt64 = 0
    private var terminalGeneration: UInt64 = 0
    private var terminalAttached = false
    private var invalidateTerminal: (@MainActor @Sendable () -> Void)?

    init(makeConnector: @escaping (PeerPairingSecret) -> any MirrorPeerConnecting = { PeerConnector(secret: $0) },
         ingest: @escaping (ThrottleMirrorSnapshot) -> Void = { MirrorStore.shared.ingest($0) },
         allowsConnections: Bool = true) {
        self.makeConnector = makeConnector
        self.ingest = ingest
        self.allowsConnections = allowsConnections
    }

    private var connector: (any MirrorPeerConnecting)?
    private var currentSecretB64: String?

    /// True only while a peer connection is actually established (driven by the
    /// connector's `onConnected`), NOT merely because a connector object exists —
    /// so the "LAN · live" badge and the terminal's read-only state tell the truth.
    private(set) var connected = false

    /// Feed each freshly-synced snapshot here; picks up (or rotates to) the pairing
    /// secret and (re)starts the LAN link. The App Store client deliberately does
    /// not consume `peerFallbackHost`: remote input is constrained to the local
    /// Bonjour/LAN path under App Review guideline 4.2.7.
    func syncPairing(from snapshot: ThrottleMirrorSnapshot) {
        guard allowsConnections else { return }
        guard let b64 = snapshot.peerPairingSecret,
              let secret = PeerPairingSecret(base64: b64) else { stop(); return }
        guard b64 != currentSecretB64 else { return }
        stop()
        currentSecretB64 = b64
        restart(with: secret)
    }

    func stop() {
        generation &+= 1
        detachTerminal()
        connector?.onSnapshot = nil
        connector?.onConnected = nil
        connector?.stop()
        connector = nil
        currentSecretB64 = nil
        connected = false
    }

    /// True only while the LAN peer link is actually connected (not just configured).
    var hasLink: Bool { connected }
    var connectionGeneration: UInt64 { generation }

    // MARK: - Remote terminal passthrough

    /// Callbacks run on the main actor after validating their attachment generation.
    /// Consumers must deliver directly to UIKit without another asynchronous hop.
    /// Attach to a Mac session's live terminal. No-op if the
    /// LAN link isn't up yet (the phone must have paired via a snapshot first).
    @discardableResult
    func attachTerminal(tabID: String,
                        onOutput: @escaping @MainActor @Sendable ([UInt8]) -> Void,
                        onResize: @escaping @MainActor @Sendable (Int, Int) -> Void,
                        onInvalidated: @escaping @MainActor @Sendable () -> Void = {}) -> UInt64? {
        detachTerminal()
        guard connected, let current = connector else { return nil }
        let token = generation
        let terminalToken = terminalGeneration
        terminalAttached = true
        invalidateTerminal = onInvalidated
        current.onTermOut = { [weak self] bytes in
            Task { @MainActor in
                guard let self, self.acceptsTerminal(token, terminalToken) else { return }
                onOutput(bytes)
            }
        }
        current.onTermResize = { [weak self] cols, rows in
            Task { @MainActor in
                guard let self, self.acceptsTerminal(token, terminalToken) else { return }
                onResize(cols, rows)
            }
        }
        current.attachTerminal(sessionId: tabID)
        return terminalToken
    }

    private func acceptsTerminal(_ connection: UInt64, _ terminal: UInt64) -> Bool {
        connected && terminalAttached && generation == connection && terminalGeneration == terminal
    }

    func sendTerminalInput(_ bytes: [UInt8]) {
        guard connected, terminalAttached else { return }
        connector?.sendInput(bytes)
    }
    func sendTerminalResize(cols: Int, rows: Int) {
        guard connected, terminalAttached else { return }
        connector?.sendResize(cols: cols, rows: rows)
    }

    func detachTerminal(attachment: UInt64? = nil) {
        if let attachment, attachment != terminalGeneration { return }
        terminalGeneration &+= 1
        if terminalAttached { connector?.detachTerminal() }
        terminalAttached = false
        connector?.onTermOut = nil
        connector?.onTermResize = nil
        let invalidate = invalidateTerminal
        invalidateTerminal = nil
        invalidate?()
    }

    private func restart(with secret: PeerPairingSecret) {
        let token = generation
        let current = makeConnector(secret)
        current.onSnapshot = { [weak self] data in
            // Fires on the connector's queue; decode off-main then ingest on main.
            guard let snap = try? ThrottleMirrorSnapshot.decoded(from: data) else { return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.ingest(snap)
            }
        }
        current.onConnected = { [weak self] connected in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.connected = connected
                if !connected { self.detachTerminal() }
            }
        }
        connector = current
        current.start()
    }
}
