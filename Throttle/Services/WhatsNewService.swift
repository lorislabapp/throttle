import Foundation

/// Tracks whether the "What's new / optimizations" tour should show — once per
/// app version, so users discover the new cost-cutting features after an update.
enum WhatsNewService {
    private static let key = "whatsNewLastSeenVersion"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// True when this version's tour hasn't been seen yet (and we know the version).
    static var shouldShow: Bool {
        !currentVersion.isEmpty && UserDefaults.standard.string(forKey: key) != currentVersion
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: key)
    }
}
