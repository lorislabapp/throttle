import Foundation
import OSLog

enum ExactModeError: Error, Sendable, Equatable {
    case notSignedIn
    case noClaudeTab
    case safariNotRunning
    case automationDenied
    case httpError(Int)
    case invalidResponse
    case appleScript(String)
    case timeout
    /// Safari discarded the claude.ai tab and the force-navigate
    /// guard was throttled (already navigated within the last 30 min).
    /// User-visible: "Safari has the tab discarded — reload manually".
    case tabZombieRateLimited
}

/// Polls claude.ai's `/api/organizations/{org}/usage` endpoint by driving
/// the user's running Safari via AppleScript. See `SafariBridge` for the
/// rationale and full security model.
///
/// The previous implementation used a hidden WKWebView; that crashed on
/// macOS 26.5 deep inside WebKit's font enumeration. Safari, running in
/// its own process, has none of those issues — and we don't need to
/// touch cookies ourselves.
@MainActor
final class ExactModeService {
    static let shared = ExactModeService()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "ExactMode")
    private var pollTask: Task<Void, Never>?

    private(set) var lastSnapshot: ExactSnapshot?
    private(set) var lastError: ExactModeError?

    /// Fired on the main actor every time a fresh snapshot lands.
    var onSnapshot: ((ExactSnapshot) -> Void)?
    /// Fired on the main actor every time a poll fails.
    var onError: ((ExactModeError) -> Void)?

    init() {}

    // MARK: - Sign-in state

    /// True when the most recent poll succeeded with a fresh snapshot.
    /// Different from "is signed in": signed-in state lives in Safari's
    /// cookie store, which we can only check by attempting a fetch.
    var hasFreshSnapshot: Bool {
        lastSnapshot?.isFresh() == true
    }

    /// Open Safari to claude.ai/settings/usage so the user can sign in
    /// (or just confirm they're signed in).
    func openSignInPage() {
        SafariBridge.openClaudeUsagePage()
    }

    // MARK: - Polling lifecycle

    /// Begin periodic polling. Idempotent.
    ///
    /// Adaptive cadence: 5 min by default, drops to 60 s once any window
    /// crosses 80% utilization. This makes the meter live near the cap
    /// (where accuracy actually matters) without spamming Safari/AppleScript
    /// during normal sub-80% usage where weekly numbers barely move.
    func start() {
        guard pollTask == nil else { return }
        logger.info("ExactMode polling started (Safari bridge)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let interval = self?.nextPollInterval() ?? .seconds(5 * 60)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 60 s when any window is hot (>=80%), 5 min otherwise.
    private func nextPollInterval() -> Duration {
        guard let snap = lastSnapshot, snap.isFresh() else {
            return .seconds(5 * 60)
        }
        let highest = max(
            snap.fiveHour.utilization,
            snap.sevenDay.utilization,
            snap.sevenDaySonnet.utilization
        )
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
        let bridgeResult = await SafariBridge.fetchUsageJSON()
        switch bridgeResult {
        case .success(let data):
            do {
                let snap = try ExactSnapshot.decode(from: data)
                return .success(snap)
            } catch {
                return .failure(.invalidResponse)
            }
        case .failure(let err):
            return .failure(map(err))
        }
    }

    private func map(_ err: SafariBridge.BridgeError) -> ExactModeError {
        switch err {
        case .safariNotRunning:    return .safariNotRunning
        case .noClaudeTab:         return .noClaudeTab
        case .automationDenied:    return .automationDenied
        case .notSignedIn:         return .notSignedIn
        case .httpError(let c):    return .httpError(c)
        case .invalidResponse:     return .invalidResponse
        case .appleScript(let s):  return .appleScript(s)
        case .scriptError(let s):  return .appleScript(s)  // map to existing variant
        case .tabZombieRateLimited: return .tabZombieRateLimited
        }
    }
}
