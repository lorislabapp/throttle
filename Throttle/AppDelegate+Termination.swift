import AppKit
import GRDB
import OSLog
import SwiftUI

extension AppDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isIsolatedHost else { return .terminateNow }
        guard !quitPending else { return .terminateLater }
        quitPending = true
        Task { @MainActor in
            let stopped = await MultiCockpitModel.shared.stop()
            quitPending = false
            if !stopped {
                let alert = NSAlert()
                alert.messageText = "Session stop could not be confirmed"
                alert.informativeText =
                    "Throttle kept the session tabs for recovery. Review the session status before quitting."
                alert.alertStyle = .warning
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isIsolatedHost else { return }
        codexUsageTimer?.invalidate()
        CaffeineService.shared.setActive(false) // release the power assertion (M04)
        coordinator.stop()
        savingsIngester.stop()
        codexIngester.stop()
        traycer.stop()
        logger.notice("Throttle quitting")
    }
}
