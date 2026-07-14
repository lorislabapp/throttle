import Foundation

/// Streaming filter that strips terminal MOUSE REPORTS from a remote keystroke
/// stream before it is injected into a PTY.
///
/// Why: when a TUI (claude) leaves any-event mouse tracking (`ESC[?1003h`) armed,
/// a peer terminal that still forwards mouse events (an old iOS build, a stray
/// browser on ttyd) floods the PTY with SGR motion reports on every touch/scroll —
/// echoed into claude's input line as `35;150;30M…` garbage on EVERY attached
/// surface. Client-side fixes (`allowMouseReporting = false`) only help clients
/// that have them; this filter is the Mac-side belt-and-braces: a human typing on
/// a remote keyboard can never legitimately produce a mouse report, so dropping
/// them all is lossless for real input.
///
/// What is dropped:
///  • SGR mouse:    `ESC [ <  params  M|m`
///  • X10 mouse:    `ESC [ M` + 3 raw bytes
///  • URXVT mouse:  `ESC [ params M` (keyboards never emit a CSI with final `M`)
/// Everything else — arrows `ESC[A`, F-keys `ESC[15~`, modifiers `ESC[1;5C`,
/// bracketed paste `ESC[200~…` — passes through byte-for-byte.
///
/// Stateful across chunks (a report can split over two WebSocket/peer frames):
/// keep ONE instance per remote client stream. A *lone* trailing ESC is emitted
/// immediately so a human Esc keypress is never delayed; only an `ESC [` prefix
/// is held, and never more than `maxHold` bytes.
public struct MouseReportFilter: Sendable {

    public init() {}

    /// Bytes of a potential CSI sequence seen so far (starts with ESC '[').
    private var held: [UInt8] = []
    /// >0 → we are inside an X10 report, this many raw payload bytes remain to drop.
    private var x10Remaining = 0

    private static let esc: UInt8 = 0x1B
    private static let maxHold = 24   // longest legit CSI from a keyboard is ~8 bytes

    /// Filter one incoming chunk; returns the bytes safe to inject into the PTY.
    public mutating func filter(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)

        for b in input {
            if x10Remaining > 0 { x10Remaining -= 1; continue }

            if held.isEmpty {
                if b == Self.esc { held = [b] } else { out.append(b) }
                continue
            }

            // held starts with ESC
            if held.count == 1 {
                if b == UInt8(ascii: "[") { held.append(b) }
                else { out.append(contentsOf: held); held = []; out.append(b) } // ESC + other: Alt-key etc.
                continue
            }

            // Inside CSI (held = ESC [ …). X10 detection: ESC [ M
            if held.count == 2 && b == UInt8(ascii: "M") && held[1] == UInt8(ascii: "[") {
                held = []; x10Remaining = 3
                continue
            }

            held.append(b)
            // CSI final byte range 0x40–0x7E ends the sequence. (`<` of SGR is
            // 0x3C — a parameter byte — so it simply accumulates until M/m.)
            if (0x40...0x7E).contains(b) {
                defer { held = [] }
                if b == UInt8(ascii: "M") || b == UInt8(ascii: "m") {
                    continue   // mouse report (SGR `ESC[<…M/m` or URXVT `ESC[…M`) → drop
                }
                out.append(contentsOf: held)
            } else if held.count > Self.maxHold {
                // Not a mouse report we recognise and too long to keep holding —
                // release verbatim rather than stall real input.
                out.append(contentsOf: held); held = []
            }
        }
        return out
    }

    /// Flush any held prefix (call when the stream ends/detaches, so a trailing
    /// partial sequence isn't silently swallowed forever).
    public mutating func flush() -> [UInt8] {
        defer { held = []; x10Remaining = 0 }
        return held
    }
}
