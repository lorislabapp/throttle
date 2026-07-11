import Foundation

/// Eternal-Terminal-style resumable-stream core: a bounded ring of recent terminal
/// output keyed by a monotonic per-session sequence number, so a phone that drops
/// (LAN blip, Wi-Fi↔cellular, Bonjour→Tailscale) can reconnect, send its last acked
/// seq, and get exactly the missed bytes backfilled — the PTY stays alive on the Mac
/// throughout. Pure + unit-tested; the reconnect handshake that exchanges the acked
/// seq and the Tailscale fallback endpoint are the transport-integration layer.
public final class CatchupBuffer: @unchecked Sendable {

    public struct Frame: Sendable, Equatable {
        public let seq: UInt64
        public let bytes: [UInt8]
    }

    private var frames: [Frame] = []
    private var bytesHeld = 0
    private let maxBytes: Int

    /// Highest sequence number assigned so far (0 = nothing sent yet).
    public private(set) var lastSeq: UInt64 = 0

    public init(maxBytes: Int = 256 * 1024) { self.maxBytes = maxBytes }

    /// Record freshly-produced output, assign it the next seq, and evict the oldest
    /// frames past the byte budget. Returns the assigned seq (goes on the wire).
    @discardableResult
    public func append(_ bytes: [UInt8]) -> UInt64 {
        lastSeq &+= 1
        frames.append(Frame(seq: lastSeq, bytes: bytes))
        bytesHeld += bytes.count
        while bytesHeld > maxBytes, frames.count > 1 {
            bytesHeld -= frames.removeFirst().bytes.count
        }
        return lastSeq
    }

    /// The oldest seq still retained (nil if empty). Anything ≤ this-1 has been evicted.
    public var earliestSeq: UInt64? { frames.first?.seq }

    /// Frames the peer is missing, given the last seq it acked. Empty if up to date.
    public func framesSince(_ ackedSeq: UInt64) -> [Frame] {
        frames.filter { $0.seq > ackedSeq }
    }

    /// Whether the gap after `ackedSeq` is still fully buffered. If the peer was gone
    /// long enough that its next-needed frame was evicted, the caller must resync with
    /// a full repaint instead of a partial backfill (mosh's "can't catch up" case).
    public func canBackfill(from ackedSeq: UInt64) -> Bool {
        guard let earliest = earliestSeq else { return ackedSeq == lastSeq }  // empty: only ok if caller is current
        return ackedSeq + 1 >= earliest
    }
}
