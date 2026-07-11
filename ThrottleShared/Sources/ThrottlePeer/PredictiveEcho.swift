import Foundation

/// The calibratable brain of mosh-style predictive local echo, kept pure so it can
/// be unit-tested without a terminal or a device. It answers one question — *should
/// the phone speculatively echo this keystroke locally before the Mac confirms it?*
/// — from a smoothed RTT estimate gated by hysteresis.
///
/// What lives here (verified now): the SRTT/RTTVAR estimator (TCP RFC 6298 style)
/// and the engage/disengage hysteresis gate whose thresholds a device test tunes.
///
/// What does NOT live here (device-gated, deliberately excluded): the SwiftTerm
/// overlay that renders unconfirmed cells underlined, and mosh's framebuffer-
/// comparison reconciliation (`get_validity` → Correct/Pending/IncorrectOrExpired).
/// A naive local echo without that reconciliation double-prints every key, so it is
/// intentionally not shipped until it can be validated against a real PTY stream.

/// Smoothed round-trip-time estimator (RFC 6298: SRTT + RTTVAR EWMA).
public struct SRTTEstimator: Sendable {
    public private(set) var srtt: Double?      // ms, nil until first sample
    public private(set) var rttvar: Double = 0 // ms
    private let alpha = 0.125                   // 1/8
    private let beta = 0.25                     // 1/4

    public init() {}

    public mutating func sample(_ rttMs: Double) {
        guard rttMs >= 0 else { return }
        if let s = srtt {
            rttvar = (1 - beta) * rttvar + beta * abs(s - rttMs)
            srtt = (1 - alpha) * s + alpha * rttMs
        } else {
            srtt = rttMs
            rttvar = rttMs / 2
        }
    }
}

/// Decides whether predictive echo is engaged, using two thresholds so the state
/// doesn't flap around a single RTT boundary (mosh's SRTT-trigger idea).
public final class PredictiveEcho: @unchecked Sendable {
    /// Engage speculation once smoothed RTT rises above this (ms). On a fast LAN the
    /// RTT stays below and prediction never turns on — no speculation, no artifacts.
    public let engageAboveMs: Double
    /// Disengage once smoothed RTT falls back below this (ms). Lower than the engage
    /// trigger → hysteresis band, no oscillation.
    public let disengageBelowMs: Double

    public private(set) var estimator = SRTTEstimator()
    public private(set) var engaged = false

    public init(engageAboveMs: Double = 30, disengageBelowMs: Double = 20) {
        precondition(disengageBelowMs <= engageAboveMs)
        self.engageAboveMs = engageAboveMs
        self.disengageBelowMs = disengageBelowMs
    }

    /// Feed a fresh RTT measurement (e.g. keystroke→echo, or a heartbeat round trip).
    /// Updates the smoothed estimate and flips the hysteresis gate.
    public func observeRTT(_ rttMs: Double) {
        estimator.sample(rttMs)
        guard let s = estimator.srtt else { return }
        if !engaged, s > engageAboveMs { engaged = true }
        else if engaged, s < disengageBelowMs { engaged = false }
    }

    /// Whether to speculatively echo this outgoing keystroke locally. Only printable
    /// bytes are candidates — control/escape sequences (arrows, ctrl-keys, CSI) are
    /// never predicted, exactly as mosh restricts speculation to plain text.
    public func shouldPredict(_ byte: UInt8) -> Bool {
        engaged && isPrintable(byte)
    }

    /// Printable ASCII (0x20–0x7e). Bytes ≥0x80 (UTF-8 lead/continuation) are left to
    /// the server to avoid mispredicting multi-byte graphemes.
    public func isPrintable(_ byte: UInt8) -> Bool { byte >= 0x20 && byte <= 0x7e }
}
