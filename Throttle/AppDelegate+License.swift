import AppKit
import GRDB
import OSLog
import SwiftUI

extension AppDelegate {

    /// Keep the Pro JWT alive. `activate` is the only endpoint that mints one, so a
    /// license that isn't re-minted decays to Free the moment `exp` + grace passes —
    /// with the key still sitting in Keychain. Fires at launch, daily, and on wake
    /// (a Mac asleep for weeks would otherwise miss every tick).
    func startLicenseRenewal() {
        Task { @MainActor in
            await LicenseService.shared.refreshIfNeeded()
            appState.refreshProStatus()
        }
        licenseRenewalTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await LicenseService.shared.refreshIfNeeded()
                self.appState.refreshProStatus()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await LicenseService.shared.refreshIfNeeded()
                self.appState.refreshProStatus()
            }
        }
    }

    func notifyActivation(success: Bool, message: String) {
        let alert = NSAlert()
        alert.messageText = success ? "Throttle Pro" : "Activation failed"
        alert.informativeText = message
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func describeActivationError(_ err: LicenseService.ActivationError) -> String {
        switch err {
        case .invalidKey:           return "Invalid license key."
        case .machineLimitReached:  return "Already activated on 3 Macs. Deactivate one first."
        case .revoked:              return "License revoked. Contact support@lorislab.fr."
        case .verificationFailed:   return "Server response failed signature check. Don't trust this network."
        case .network(let m):       return "Network error: \(m)"
        case .server(let code):     return "Server error \(code). Try again later."
        case .decode(let m):        return "Couldn't decode response: \(m)"
        }
    }
}
