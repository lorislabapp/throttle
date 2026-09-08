import AppKit
import Foundation

/// URL routing lives beside the delegate rather than inside it: every new deep
/// link grew the one switch that already carried licence activation, and the
/// class it sat in was over its length before this file existed.
extension AppDelegate {
    /// Handle deep links: `throttle://activate?key=THROTTLE-XXXX-XXXX-XXXX-XXXX`.
    /// Lets the purchase email link auto-activate Pro instead of asking the user
    /// to copy the key, find the menu bar pill, and click Paste license key.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleDeepLink(url)
        }
    }

    func handleDeepLink(_ url: URL) {
        guard !Self.isIsolatedHost else { return }
        guard url.scheme?.lowercased() == "throttle" else {
            logger.notice("Ignoring URL with unknown scheme: \(url.scheme ?? "nil", privacy: .public)")
            return
        }
        routeDeepLink(url)
    }

    private func routeDeepLink(_ url: URL) {
        let host = url.host?.lowercased()
        switch host {
        case "activate":
            activate(from: url)
        case "cockpit":
            Task { @MainActor in CockpitWindowController.shared.show(appState: self.appState) }
        // The vault window could only be reached by clicking through the menu bar,
        // so nothing outside the app — a shortcut, a script, an agent asked to set
        // the vault up — could even open it. `/library` goes one step further and
        // raises the folder picker, which is still the only thing that can grant
        // access to a tree.
        case "research-vault":
            Task { @MainActor in
                ResearchVaultWindowController.shared.show(query: "")
                if url.path.lowercased() == "/library" {
                    NotificationCenter.default.post(
                        name: .throttleResearchVaultConnectLibrary, object: nil
                    )
                }
            }
        case "pause":   ThrottleCommandChannel.enqueue(.pauseAll)
        case "resume":  ThrottleCommandChannel.enqueue(.resumeAll)
        case "quiet":   ThrottleCommandChannel.enqueue(.quietOn)
        case "unquiet": ThrottleCommandChannel.enqueue(.quietOff)
        default:
            logger.notice("Ignoring throttle:// URL with unknown host: \(host ?? "nil", privacy: .public)")
        }
    }

    private func activate(from url: URL) {
        // ?key=THROTTLE-… in either query or path component.
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let key = comps?.queryItems?.first(where: { $0.name == "key" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard let key, key.hasPrefix("THROTTLE-") else {
            logger.notice("activate URL missing or malformed key")
            return
        }
        Task { @MainActor in
            let result = await LicenseService.shared.activate(key: key)
            switch result {
            case .success:
                self.appState.refreshProStatus()
                self.notifyActivation(success: true, message: "Throttle Pro activated.")
            case .failure(let err):
                self.notifyActivation(success: false, message: self.describeActivationError(err))
            }
        }
    }
}
