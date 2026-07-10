import Foundation

/// A sink for the live usage/cockpit mirror. The Mac fans a `ThrottleMirrorSnapshot`
/// out to every enabled transport — CloudKit today, a LAN peer link next — each of
/// which delivers it to the iOS companion by its own path (private iCloud DB, or a
/// direct Bonjour+TLS connection on the same network).
///
/// Measure-only by construction: a transport only *ships* the read-only snapshot; it
/// carries no control channel back to the Mac. Keeping this a protocol lets the
/// publish site (`AppState.refresh`) stay transport-agnostic and lets transports be
/// added/removed without touching the state layer.
///
/// `@MainActor` because the mirror is produced inside `AppState.refresh`'s
/// `MainActor.run` block and every transport (CloudKit publisher, peer link) is a
/// main-actor singleton fed from there.
@MainActor
public protocol MirrorTransport: AnyObject {
    /// Queue the latest snapshot for delivery. Must be cheap and non-blocking —
    /// called on every `AppState.refresh`; transports coalesce/debounce internally.
    func publish(_ snapshot: ThrottleMirrorSnapshot)
}
