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
    private let secret: PeerPairingSecret?
    private var secretIsPersisted = false
    var pairingPersistenceError: String? {
        guard !secretIsPersisted else { return nil }
        return String(localized: "Pairing could not be saved in Keychain. LAN mirroring has not started.")
    }
    private var advertiser: PeerAdvertiser?
    private var started = false
    private let controlAdmission = PeerControlAdmission()
    private static let controlConsentKey = "throttlePeerTerminalControlEnabled"

    /// Separate from mirror consent. Existing installations default to read-only.
    var terminalControlEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.controlConsentKey) }
        set {
            guard newValue != terminalControlEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: Self.controlConsentKey)
            controlAdmission.setControlEnabled(newValue)
            // Revoke existing terminal taps without racing listener cancellation.
            PeerTerminalBridge.shared.reset()
        }
    }

    var permitsTerminalControl: Bool {
        controlAdmission.permitsCurrentConnection && terminalControlEnabled
    }

    /// Base64 secret stamped into every mirror snapshot so the phone can pair.
    var pairingSecretBase64: String? { secretIsPersisted ? secret?.base64 : nil }

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

    private convenience init() {
        self.init(
            credential: KeychainStore.read(account: Self.secretAccount),
            legacy: { UserDefaults.standard.string(forKey: Self.secretKey) },
            persist: { KeychainStore.set($0, account: Self.secretAccount) },
            removeLegacy: { UserDefaults.standard.removeObject(forKey: Self.secretKey) },
            generate: { PeerPairingSecret.generate() }
        )
    }

    /// Explicit dependencies let native tests qualify degraded startup without
    /// reading real credentials, generating randomness or opening a listener.
    init(credential: KeychainStore.ReadResult, legacy: () -> String?,
         persist: (String) -> Bool, removeLegacy: () -> Void,
         generate: () -> PeerPairingSecret) {
        // Keychain, not UserDefaults. This secret authorises a device to receive
        // the mirror of every session, and it lived in a plist any process
        // running as this user could read — while the edge-agent bearer token,
        // twenty lines away in another file, was already in the Keychain with
        // the comment "Bearer token controls a remote session → Keychain, not
        // UserDefaults". The same sentence applies here and was not followed.
        switch credential {
        case .found(let base64):
            secret = PeerPairingSecret(base64: base64)
            secretIsPersisted = secret != nil
        case .unavailable:
            // Never replace an unreadable credential with a newly generated one.
            secret = nil
        case .missing:
            if let legacy = legacy(),
               let existing = PeerPairingSecret(base64: legacy) {
                if persist(legacy) {
                    secretIsPersisted = true
                    removeLegacy()
                }
                secret = existing
            } else {
                let fresh = generate()
                if persist(fresh.base64) {
                    secretIsPersisted = true
                    removeLegacy()
                }
                secret = fresh
            }
        }
    }

    /// Do not advertise an ephemeral pairing identity after a persistence failure.
    func start() {
        guard !started, secretIsPersisted, let secret else { return }
        // Pin the fixed port always (not just when a fallback host is set): Bonjour
        // resolves whatever port we bind on the LAN either way, and pinning it means
        // flipping on a tailnet host later never requires restarting the listener.
        let adv = PeerAdvertiser(secret: secret, serviceName: Host.current().localizedName ?? "Mac",
                                  fixedPort: PeerPairing.fallbackPort)
        // Route peer terminal control frames to the cockpit bridge (main actor).
        let generation = controlAdmission.start(controlEnabled: terminalControlEnabled)
        let admission = controlAdmission
        adv.onTerminalControl = { [weak self] control, client in
            guard let ticket = admission.ticket(for: generation) else { return }
            Task { @MainActor in
                guard let self else { return }
                Self.deliverControl((control, client), ticket: ticket, admission: admission,
                                    controlEnabled: self.terminalControlEnabled) { control, client in
                    PeerTerminalBridge.shared.handle(control, from: client)
                }
            }
        }
        adv.start()
        advertiser = adv
        started = true
    }

    /// Called only after the network callback has hopped onto MainActor.
    /// Keeping the final gate here lets tests exercise the delivered frame path.
    static func deliverControl(
        _ frame: (control: PeerTerminalControl, client: PeerClientID),
        ticket: PeerControlAdmission.Ticket, admission: PeerControlAdmission,
        controlEnabled: Bool, handle: (PeerTerminalControl, PeerClientID) -> Void
    ) {
        guard admission.permits(ticket), controlEnabled else { return }
        handle(frame.control, frame.client)
    }

    func stop() {
        controlAdmission.stop()
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
