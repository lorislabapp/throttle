import Foundation

/// Helpers for the remote-terminal frames (`termResize` payload codec + typed
/// constructors). The heavy lifting (tapping the Mac PTY, feeding SwiftTerm on the
/// phone) lives in the app layers; this keeps the wire format in one place.
public enum PeerTerminal {

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
