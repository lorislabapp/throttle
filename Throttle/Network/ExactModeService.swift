import Foundation
import OSLog

enum ExactModeError: Error, Sendable, Equatable {
    case notSignedIn
    case httpError(Int)
    case invalidResponse
    case session(String)
    case timeout
}

/// Polls Anthropic's OAuth usage endpoint first, then falls back to Throttle's
/// own embedded claude.ai session. No Safari automation or Apple Events are used.
@MainActor
final class ExactModeService {
    static let shared = ExactModeService()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "ExactMode")
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0   // drives exponential backoff (H10)

    private(set) var lastSnapshot: ExactSnapshot?
    private(set) var lastError: ExactModeError?

    /// Fired on the main actor every time a fresh snapshot lands.
    var onSnapshot: ((ExactSnapshot) -> Void)?
    /// Fired on the main actor every time a poll fails.
    var onError: ((ExactModeError) -> Void)?

    init() {}

    // MARK: - Sign-in state

    /// True when the most recent poll succeeded with a fresh snapshot.
    /// Different from "is signed in": the primary OAuth token and embedded
    /// session can each expire independently, so freshness requires a fetch.
    var hasFreshSnapshot: Bool {
        lastSnapshot?.isFresh() == true
    }

    // MARK: - Polling lifecycle

    /// Begin periodic polling. Idempotent.
    ///
    /// Adaptive cadence: 5 min by default, drops to 60 s once any window
    /// crosses 80% utilization. This makes the meter live near the cap
    /// (where accuracy actually matters) without polling Anthropic excessively
    /// during normal sub-80% usage where weekly numbers barely move.
    func start() {
        guard pollTask == nil else { return }
        logger.info("ExactMode polling started (OAuth + embedded session)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                if let self {
                    if self.lastError == nil, self.hasFreshSnapshot { self.consecutiveFailures = 0 } else { self.consecutiveFailures = min(self.consecutiveFailures + 1, 6) }
                }
                let interval = self?.nextPollInterval() ?? .seconds(5 * 60)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 60 s when any window is hot (>=80%), 5 min otherwise. On consecutive
    /// failures, exponential backoff with jitter so a dead endpoint / captive
    /// portal isn't hammered every 60 s (H10).
    private func nextPollInterval() -> Duration {
        let base = Self.pollPolicy(now: Date(), snapshot: lastSnapshot, consecutiveFailures: consecutiveFailures)
        // Jitter only the failure-backoff branch (±20%) so a dead claude.ai /
        // captive portal isn't hammered in lockstep.
        guard consecutiveFailures > 0 else { return base }
        return .seconds(Int(Double(base.components.seconds) * Double.random(in: 0.8...1.2)))
    }

    /// Pure poll-cadence policy (testable). Priority:
    /// 1. consecutive failures → exponential backoff (caller adds the jitter);
    /// 2. a window fully CAPPED (100%) with a known reset → wait until the soonest
    ///    such reset (+5 s), capped at 15 min — honors the window's `resets_at` the
    ///    way a Retry-After would (no point polling claude.ai into the wall every
    ///    60 s while capped), while still refreshing the meter at least every 15 min;
    /// 3. ≥80% util → 60 s; otherwise 5 min (also 5 min when no fresh snapshot).
    nonisolated static func pollPolicy(now: Date, snapshot: ExactSnapshot?, consecutiveFailures: Int) -> Duration {
        if consecutiveFailures > 0 {
            // While a fresh snapshot is still on the meter, a transient failure must
            // NOT trigger a long backoff: the freshness window (10 min) would expire
            // before the next attempt and the number would visibly blank then reappear
            // (the "live metrics keep disconnecting randomly" flap). Keep retrying
            // quickly to refresh it before it goes stale. Only once the snapshot is
            // already stale/absent — nothing left to preserve, claude.ai likely down —
            // do we back off exponentially so we don't hammer a dead endpoint.
            if let snap = snapshot, snap.isFresh(now: now) { return .seconds(60) }
            return .seconds(min(30 * (1 << min(consecutiveFailures - 1, 5)), 15 * 60))   // 30,60,…,cap 15min
        }
        guard let snap = snapshot, snap.isFresh(now: now) else { return .seconds(5 * 60) }
        let windows = [snap.fiveHour, snap.sevenDay, snap.sevenDaySonnet]
        let cappedResets = windows.compactMap { $0.utilization >= 100 ? $0.resetsAt : nil }.filter { $0 > now }
        if let soonest = cappedResets.min() {
            let wait = Int(soonest.timeIntervalSince(now)) + 5
            return .seconds(min(max(wait, 60), 15 * 60))
        }
        let highest = windows.map(\.utilization).max() ?? 0
        return highest >= 80 ? .seconds(60) : .seconds(5 * 60)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        logger.info("ExactMode polling stopped")
    }

    /// Manual one-shot. Powers the "Test connection" button.
    @discardableResult
    func refresh() async -> Result<ExactSnapshot, ExactModeError> {
        await pollOnceImpl()
    }

    func signOut() {
        // We don't store any cookies — sign-out is just a cosmetic clear.
        lastSnapshot = nil
        lastError = .notSignedIn
        stop()
    }

    // MARK: - Internal

    private func pollOnce() async {
        let result = await pollOnceImpl()
        switch result {
        case .success(let snap):
            lastSnapshot = snap
            lastError = nil
            onSnapshot?(snap)
            logger.info("ExactMode snapshot: 5h=\(snap.fiveHour.utilization)%, 7d=\(snap.sevenDay.utilization)%, sonnet=\(snap.sevenDaySonnet.utilization)%")
        case .failure(let err):
            lastError = err
            onError?(err)
            logger.error("ExactMode poll failed: \(String(describing: err))")
        }
    }

    private func pollOnceImpl() async -> Result<ExactSnapshot, ExactModeError> {
        // 0) OAuth endpoint first (3.2.65): server-truth across ALL machines,
        // headless, no Safari/WKWebView — the token Claude Code already keeps
        // in the keychain. Any failure quietly falls through to the scrapes.
        if let snap = try? await OAuthUsageProvider.fetch() {
            return .success(snap)
        }
        logger.info("OAuth usage path unavailable — falling back to embedded session")

        // Always try the embedded session first. The embedded path's
        // own JS reports `_throttle_status: 401` when the cookie store
        // doesn't have a usable session, which we map to .notSignedIn —
        // strictly more accurate than the cookie-name-based isSignedIn
        // heuristic, which could miss a freshly-rotated cookie before
        // the store has fully loaded from disk.
        do {
            let data = try await EmbeddedClaudeSession.shared.fetchUsageJSON()
            let snap = try ExactSnapshot.decode(from: data)
            return .success(snap)
        } catch let err as EmbeddedSessionError {
            logger.error("embedded session error: \(err.localizedDescription, privacy: .public)")
            return .failure(mapEmbedded(err))
        } catch let decodeErr as DecodingError {
            logger.error("ExactSnapshot decode failed: \(String(describing: decodeErr), privacy: .public)")
            return .failure(.invalidResponse)
        } catch {
            logger.error("exact mode embedded unknown error: \(error.localizedDescription, privacy: .public)")
            return .failure(.session(error.localizedDescription))
        }
    }

    private func mapEmbedded(_ err: EmbeddedSessionError) -> ExactModeError {
        switch err {
        case .notSignedIn:        return .notSignedIn
        case .httpError(let c):   return .httpError(c)
        case .invalidResponse:    return .invalidResponse
        case .scriptError(let s): return .session(s)
        case .decode(let s):      return .session(s)
        }
    }
}
