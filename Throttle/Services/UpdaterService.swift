import Foundation
import Sparkle
import OSLog

/// Wraps SPUStandardUpdaterController so the rest of the app talks to a
/// stable, MainActor-friendly façade. We keep automatic checks on by
/// default (interval is set in Info.plist via SUScheduledCheckInterval).
@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "Updater")
    private let updater: SPUStandardUpdaterController

    override init() {
        self.updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        logger.info("Sparkle updater started — feed: \(self.updater.updater.feedURL?.absoluteString ?? "none", privacy: .public)")
    }

    /// User-initiated check. Sparkle handles the UI flow (modal sheet,
    /// download, install). Replaces the user driver — banner-style.
    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        updater.updater.canCheckForUpdates
    }

    var lastCheckDate: Date? {
        updater.updater.lastUpdateCheckDate
    }
}
