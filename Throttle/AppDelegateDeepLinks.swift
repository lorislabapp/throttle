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

    /// Routing and the confirm-or-run decision live in `DeepLinkRoute` (pure,
    /// tested). Any app or web page can open a `throttle://` URL, so routes that
    /// change state run only after the user approves them in an alert.
    func handleDeepLink(_ url: URL) {
        let route = DeepLinkRoute.parse(url)
        if let prompt = route.confirmationPrompt {
            guard confirmDeepLink(prompt) else {
                logger.notice("throttle:// action declined by the user")
                return
            }
        }
        perform(route)
    }

    private func perform(_ route: DeepLinkRoute) {
        switch route {
        case .activate(let key):
            activate(key: key)
        case .cockpit:
            Task { @MainActor in CockpitWindowController.shared.show(appState: self.appState) }
        // The vault window could only be reached by clicking through the menu bar,
        // so nothing outside the app — a shortcut, a script, an agent asked to set
        // the vault up — could even open it. `/library` goes one step further and
        // raises the folder picker, which is still the only thing that can grant
        // access to a tree.
        case .researchVault(let connectLibrary):
            Task { @MainActor in
                ResearchVaultWindowController.shared.show(query: "")
                if connectLibrary {
                    NotificationCenter.default.post(
                        name: .throttleResearchVaultConnectLibrary, object: nil
                    )
                }
            }
        case .command(let action):
            ThrottleCommandChannel.enqueue(action)
        case .ignored(let reason):
            logger.notice("Ignoring throttle:// URL: \(reason, privacy: .public)")
        }
    }

    /// Same modal style as `notifyActivation`. Cancel is the default button so
    /// a stray Return never approves an action a link asked for.
    private func confirmDeepLink(_ prompt: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow this link?"
        alert.informativeText = prompt
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func activate(key: String) {
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
