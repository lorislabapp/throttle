import Foundation
import ThrottleShared

/// Fans the live mirror snapshot out to every registered `MirrorTransport`.
///
/// This is the single seam that replaces the old hardcoded
/// `CloudKitPublisher.shared.publish(...)` call in `AppState.refresh`. Today only
/// the CloudKit publisher is registered (identical behaviour to before); the LAN
/// peer transport registers here too once it lands, so the state layer never learns
/// how many ways a snapshot reaches the phone.
///
/// Transports are held weakly-by-identity-dedup but strongly retained — they are
/// long-lived main-actor singletons, so a plain array is correct and cheap.
@MainActor
final class MirrorFanout {
    static let shared = MirrorFanout()
    private init() {}

    private var transports: [MirrorTransport] = []

    /// Idempotent: registering the same transport twice is a no-op.
    func register(_ transport: MirrorTransport) {
        guard !transports.contains(where: { $0 === transport }) else { return }
        transports.append(transport)
    }

    /// Deliver the freshest snapshot to every transport. Each debounces internally,
    /// so this stays safe to call on every `AppState.refresh`.
    func publish(_ snapshot: ThrottleMirrorSnapshot) {
        for transport in transports { transport.publish(snapshot) }
    }
}
