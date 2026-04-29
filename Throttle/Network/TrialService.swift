import Foundation
import OSLog
import Security

/// Manages the 7-day Pro trial. State lives in Keychain so re-installing
/// the app or moving the app bundle doesn't reset the clock — only a
/// deliberate Keychain wipe (or new Mac) gives a fresh trial.
///
/// Activation rule:
///   `appState.isPro = devUnlock || licenseValid || trialActive`
@MainActor
final class TrialService {
    static let shared = TrialService()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "Trial")
    private let trialDuration: TimeInterval = 7 * 24 * 3600

    private(set) var startedAt: Date?

    init() {
        self.startedAt = TrialKeychain.load()
        if startedAt == nil {
            // First launch with no license → start the trial clock.
            let now = Date()
            self.startedAt = now
            try? TrialKeychain.save(now)
            logger.info("Trial started at \(now.ISO8601Format(), privacy: .public)")
        }
    }

    /// True while we're inside the 7-day window.
    var isActive: Bool {
        guard let started = startedAt else { return false }
        return Date().timeIntervalSince(started) < trialDuration
    }

    /// Days remaining (0 once expired). Useful for the countdown banner.
    var daysLeft: Int {
        guard let started = startedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(started)
        let remaining = trialDuration - elapsed
        if remaining <= 0 { return 0 }
        return max(1, Int(ceil(remaining / (24 * 3600))))
    }

    /// True iff the trial has been started AND is now expired (we want a
    /// different banner copy than "trial active").
    var hasExpired: Bool {
        startedAt != nil && !isActive
    }

    /// Reset trial state. Used by `dev-unlock toggle off` or for testing.
    /// Not exposed in the UI to normal users.
    func reset() {
        TrialKeychain.clear()
        startedAt = nil
    }
}

// MARK: - Keychain backing

private enum TrialKeychain {
    private static let service = "com.lorislab.throttle.trial"
    private static let account = "started-at"

    static func save(_ date: Date) throws {
        let value = String(Int64(date.timeIntervalSince1970))
        guard let data = value.data(using: .utf8) else { return }
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load() -> Date? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8),
              let secs = Int64(s) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
