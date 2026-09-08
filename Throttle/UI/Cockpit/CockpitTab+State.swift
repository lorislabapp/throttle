import AppKit
import SwiftTerm
import SwiftUI

extension CockpitTab {

    /// A question claude printed and is (best-effort) waiting on.
    struct Question: Identifiable { let id = UUID(); let text: String; let askedAt = Date() }
    /// The latest question text, for inline display.
    var latestQuestion: String? { questions.last?.text }
    var isRateLimited: Bool { (rateLimitedUntil.map { $0 > Date() }) ?? false }
    /// Frozen via SIGSTOP (reversible) to stop token burn without killing state.
    var isPaused: Bool { pauseReason != nil }

    enum PauseReason: Equatable {
        /// The user hit Pause. Explicit intent — never undone by focus or pressure.
        case user
        /// Crowding tier of auto-reclaim: too many tabs spawned, RAM still fine.
        case crowding
        /// The pacing banner's "pause idle sessions" one-tap.
        case pacing
        /// The ≥95% circuit breaker fired. Resuming is the user's call — waking this
        /// on focus would defeat the breaker the moment you looked at the tab.
        case capBreaker
        /// A user-configured rule fired (per-session Opus/Fable token cap). Same as
        /// the breaker: the point is to make you look before it burns more.
        case rule(String)

        /// Focusing the tab unfreezes it (SIGCONT, zero tokens, no `--resume`).
        /// True only where the freeze was a resource guess we made FOR the user:
        /// focusing is them telling us the guess was wrong.
        var resumesOnFocus: Bool {
            switch self {
            case .crowding, .pacing: return true
            case .user, .capBreaker, .rule: return false
            }
        }
        /// Real memory pressure may escalate this freeze to a hibernate (kills the
        /// subtree, wakes via `--resume`). Only for freezes we applied ourselves for
        /// resource reasons — never a user pause, never a breaker pause.
        var escalatesToHibernate: Bool { resumesOnFocus }

        var title: String {
            switch self {
            case .user:       return "Session frozen"
            case .crowding:   return "Frozen to free memory"
            case .pacing:     return "Frozen to slow the burn"
            case .capBreaker: return "Frozen at the cap"
            case .rule:       return "Frozen by a rule"
            }
        }
        var detail: String {
            switch self {
            case .user:
                return """
                You paused it. The process is stopped — no tokens, no output, keystrokes are \
                dropped. State is intact.
                """
            case .crowding:
                return "Too many sessions were live at once. Nothing is lost — resuming costs no tokens and no reload."
            case .pacing:
                return """
                Paused as an idle session to leave headroom in the window. Resuming costs no tokens \
                and no reload.
                """
            case .capBreaker:
                return "The binding window hit 95%. Resuming restarts token burn against a nearly-full cap."
            case .rule(let what):
                return "\(what) Resume once you've checked what it was doing."
            }
        }
    }

    enum SessionState { case dormant, hibernated, rateLimited, paused, working, waiting, idle }
    var state: SessionState {
        if terminal == nil { return isHibernated ? .hibernated : .dormant }
        if isPaused { return .paused }
        if isRateLimited { return .rateLimited }
        if needsInput { return .waiting }
        if Date().timeIntervalSince(lastActivityAt) < 6 { return .working }
        return .idle
    }

    /// Pure so the rule is testable without a PTY.
    nonisolated static func isActive(needsInput: Bool, rateLimited: Bool, lastActivityAt: Date, now: Date) -> Bool {
        needsInput || rateLimited || now.timeIntervalSince(lastActivityAt) < activeWindow
    }

    func isActive(now: Date = Date()) -> Bool {
        isSpawned && Self.isActive(needsInput: needsInput, rateLimited: isRateLimited,
                                   lastActivityAt: lastActivityAt, now: now)
    }
}
