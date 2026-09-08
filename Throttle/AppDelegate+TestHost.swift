import AppKit
import SwiftUI

extension AppDelegate {
    /// Layout previews only: the views reject service and persistence actions.
    func showTestHostWindow() {
        guard Self.isIsolatedHost else { return }
        if CommandLine.arguments.contains("-researchVaultWorkbenchTest")
            || CommandLine.arguments.contains("-researchVaultApprovalTest") {
            let model = ResearchVaultWorkbenchModel()
            if CommandLine.arguments.contains("-researchVaultApprovalTest") {
                model.serviceState = .requiresApproval
                model.status = String(localized: "Allow Research Vault in System Settings > Login Items.")
            }
            let controller = NSHostingController(
                rootView: ResearchVaultWorkbenchView(model: model, onBack: {})
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "Research Vault Workbench Test Host"
            window.setContentSize(NSSize(width: 860, height: 540))
            window.center()
            window.makeKeyAndOrderFront(nil)
            researchVaultWorkbenchTestWindow = window
        }
        if CommandLine.arguments.contains("-globalRAGOnboardingTest") {
            let controller = NSHostingController(
                rootView: GlobalRAGOnboardingView(canInstallMCP: false) { _ in }
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "Global Portfolio Setup Test Host"
            if CommandLine.arguments.contains("-globalRAGOnboardingDarkTest") {
                window.appearance = NSAppearance(named: .darkAqua)
            }
            window.setContentSize(NSSize(width: 900, height: 720))
            window.center()
            window.makeKeyAndOrderFront(nil)
            globalRAGOnboardingTestWindow = window
        }
    }
}
