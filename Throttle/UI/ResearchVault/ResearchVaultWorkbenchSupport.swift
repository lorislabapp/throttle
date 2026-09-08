import AppKit
import Observation
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSynthesis
import ResearchVaultXPCClient
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension ResearchVaultReasoningRelationKind {
    var localizedTitle: String {
        switch self {
        case .contradicts:
            String(localized: "Contradicts")
        case .supersedes:
            String(localized: "Supersedes")
        case .dependsOn:
            String(localized: "Depends on")
        }
    }
}

extension Notification.Name {
    /// Raised by the throttle://research-vault/library deep link.
    static let throttleResearchVaultConnectLibrary =
        Notification.Name("throttle.researchVault.connectLibrary")
}

extension Array {
    /// Splits an import into the batches the importer accepts, so a folder larger
    /// than one batch is ingested rather than refused.
    func vaultImportChunks(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
