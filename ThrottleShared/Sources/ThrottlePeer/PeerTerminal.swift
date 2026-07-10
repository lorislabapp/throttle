import Foundation

/// Opaque, `Sendable` handle for one connected peer, so the app layer can address
/// `termOut` back to the exact connection an `attach` came from without touching
/// `NWConnection` (which isn't `Sendable`).
public struct PeerClientID: Hashable, Sendable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

/// A decoded control message from a peer, ready for the app-layer bridge to act on.
/// Deliberately app-type-free (String/bytes/ints) so `ThrottlePeer` stays UI-agnostic.
public enum PeerTerminalControl: Sendable, Equatable {
    /// Attach this peer to the session with the given id (its cockpit-tab UUID string).
    case attach(sessionId: String)
    /// Inject these keystroke bytes into the attached session's PTY.
    case input([UInt8])
    /// The peer's terminal geometry changed (advisory — the Mac stays authoritative).
    case resize(cols: Int, rows: Int)
    /// Detach from the current session.
    case detach
}

/// Helpers for the remote-terminal frames (`termResize` payload codec + typed
/// constructors). The heavy lifting (tapping the Mac PTY, feeding SwiftTerm on the
/// phone) lives in the app layers; this keeps the wire format in one place.
public enum PeerTerminal {

    /// Map an inbound frame to a control event, or nil if it isn't a control frame
    /// (hello/heartbeat/snapshot) or is malformed. Pure — the single source of truth
    /// for the frame→control decoding, unit-tested without a socket.
    public static func control(from msg: PeerMessage) -> PeerTerminalControl? {
        switch msg.kind {
        case .termAttach: return .attach(sessionId: String(decoding: msg.payload, as: UTF8.self))
        case .termIn:     return .input([UInt8](msg.payload))
        case .termResize: return decodeResize(msg.payload).map { .resize(cols: $0.cols, rows: $0.rows) }
        case .termDetach: return .detach
        default:          return nil
        }
    }

    /// Encode a resize as cols(UInt16 BE) ++ rows(UInt16 BE).
    public static func resizePayload(cols: Int, rows: Int) -> Data {
        var d = Data(capacity: 4)
        let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
        d.append(UInt8(c >> 8)); d.append(UInt8(c & 0xFF))
        d.append(UInt8(r >> 8)); d.append(UInt8(r & 0xFF))
        return d
    }

    /// Decode a `termResize` payload back to (cols, rows), or nil if malformed.
    public static func decodeResize(_ payload: Data) -> (cols: Int, rows: Int)? {
        guard payload.count == 4 else { return nil }
        let b = [UInt8](payload)
        let cols = Int(b[0]) << 8 | Int(b[1])
        let rows = Int(b[2]) << 8 | Int(b[3])
        return (cols, rows)
    }
}
