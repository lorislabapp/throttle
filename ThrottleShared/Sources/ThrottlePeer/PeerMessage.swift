import Foundation

/// One framed message on the peer link. Length-prefixed binary header + payload,
/// modelled on Weave's `MRPMessage` shape but rewritten to decode safely from a
/// byte stream (the reference version assumed one datagram == one message).
///
/// Header (17 bytes, big-endian / network order):
///   kind   UInt8   — message type
///   seq    UInt32  — monotonically increasing per sender, for ordering/debug
///   ts     UInt64  — sender's publishedAt in ms since epoch (debug/latency only)
///   len    UInt32  — payload byte count
/// followed by `len` payload bytes.
public struct PeerMessage: Equatable, Sendable {

    public enum Kind: UInt8, Sendable {
        /// Handshake: sender announces itself (payload = device name UTF-8).
        case hello = 1
        /// A `ThrottleMirrorSnapshot.encoded()` JSON blob.
        case snapshot = 2
        /// Presence keepalive (empty payload).
        case heartbeat = 3
    }

    public var kind: Kind
    public var seq: UInt32
    public var timestampMillis: UInt64
    public var payload: Data

    public init(kind: Kind, seq: UInt32, timestampMillis: UInt64, payload: Data = Data()) {
        self.kind = kind
        self.seq = seq
        self.timestampMillis = timestampMillis
        self.payload = payload
    }

    public static let headerSize = 1 + 4 + 8 + 4   // 17

    /// Guard against a hostile/corrupt length field on an unauthenticated read.
    public static let maxPayload = 4 * 1024 * 1024  // 4 MiB — a snapshot is a few KB

    public enum FramingError: Error, Equatable {
        case unknownKind(UInt8)
        case payloadTooLarge(Int)
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(kind.rawValue)
        out.appendBigEndian(seq)
        out.appendBigEndian(timestampMillis)
        out.appendBigEndian(UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// Decode exactly one frame from the front of `buffer`.
    /// - Returns: the message and how many bytes it consumed, or `nil` if `buffer`
    ///   doesn't yet contain a whole frame (caller should read more and retry).
    /// - Throws: `FramingError` on an unknown kind or an implausible length.
    public static func decode(from buffer: Data) throws -> (message: PeerMessage, consumed: Int)? {
        guard buffer.count >= headerSize else { return nil }
        // buffer may be a slice with a non-zero startIndex — index relative to base.
        let base = buffer.startIndex
        let rawKind = buffer[base]
        let seq = buffer.readBigEndian(UInt32.self, at: base + 1)
        let ts = buffer.readBigEndian(UInt64.self, at: base + 5)
        let len = Int(buffer.readBigEndian(UInt32.self, at: base + 13))
        guard len <= maxPayload else { throw FramingError.payloadTooLarge(len) }
        let total = headerSize + len
        guard buffer.count >= total else { return nil }   // wait for the rest
        guard let kind = Kind(rawValue: rawKind) else { throw FramingError.unknownKind(rawKind) }
        let payloadStart = base + headerSize
        let payload = Data(buffer[payloadStart ..< payloadStart + len])
        return (PeerMessage(kind: kind, seq: seq, timestampMillis: ts, payload: payload), total)
    }
}

// MARK: - Big-endian byte helpers

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    /// Read a big-endian integer at an absolute index (works on slices).
    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at index: Int) -> T {
        var value: T = 0
        for offset in 0 ..< MemoryLayout<T>.size {
            value = (value << 8) | T(self[index + offset])
        }
        return value
    }
}
