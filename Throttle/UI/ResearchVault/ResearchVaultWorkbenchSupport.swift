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

extension Array where Element == ResearchVaultDocumentPayload {
    /// Batches that fit one XPC message: the count limit and, before it, the
    /// byte budget — four large documents do not fit where four small ones do.
    func vaultDocumentBatches(
        maximumCount: Int = ResearchVaultIPCContract.maximumDocumentsPerRequest,
        maximumBytes: Int = ResearchVaultIPCContract.maximumOwnerRequestBytes / 2
    ) -> [[ResearchVaultDocumentPayload]] {
        var batches: [[ResearchVaultDocumentPayload]] = []
        var current: [ResearchVaultDocumentPayload] = []
        var bytes = 0
        for payload in self {
            if !current.isEmpty, current.count >= maximumCount || bytes + payload.byteCount > maximumBytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(payload)
            bytes += payload.byteCount
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
