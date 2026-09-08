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

extension ResearchVaultWorkbenchModel {
    var reasoningClaimReferences: [(reference: ResearchVaultReasoningClaimReference, title: String)] {
        let scope = Set(selectedProjectKeys)
        return approvedReceipts.filter { scope.contains($0.projectKey) }.flatMap { receipt in
            receipt.findings.enumerated().compactMap { index, finding in
                guard finding.status == .verified || finding.status == .supported else { return nil }
                return (
                    ResearchVaultReasoningClaimReference(
                        receiptID: receipt.receiptID,
                        findingIndex: index
                    ),
                    finding.claim
                )
            }
        }.sorted { left, right in
            if left.title != right.title { return left.title < right.title }
            if left.reference.receiptID != right.reference.receiptID {
                return left.reference.receiptID < right.reference.receiptID
            }
            return left.reference.findingIndex < right.reference.findingIndex
        }
    }

    var canRetractSelectedReasoningRelation: Bool {
        guard let selectedReasoningFactID,
              let fact = reasoningFacts.first(where: { $0.id == selectedReasoningFactID }) else {
            return false
        }
        return fact.asserted && ResearchVaultReasoningRelationKind(rawValue: fact.predicate) != nil
    }

    func refreshReasoningFacts(reportFailure: Bool = true) async {
        guard let client else { return }
        do {
            let response = try await client.reasoning(
                ResearchVaultReasoningQuery(kind: .facts, limit: 256)
            )
            reasoningFacts = response.facts
            reasoningGeneration = response.generation
            if selectedReasoningFactID == nil
                || !reasoningFacts.contains(where: { $0.id == selectedReasoningFactID }) {
                selectedReasoningFactID = reasoningFacts.first?.id
            }
        } catch {
            reasoningFacts = []
            reasoningDetail = nil
            reasoningGeneration = nil
            if reportFailure {
                status = String(localized: "Reasoning shadow is not initialized yet.")
            }
        }
    }

    func promoteSelectedReasoningRelation() async {
        guard let client, let reasoningSubject, let reasoningObject else { return }
        guard reasoningSubject != reasoningObject else {
            status = String(localized: "A claim cannot relate to itself.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.promoteReasoningRelations([
                ResearchVaultReasoningRelation(
                    relation: reasoningRelation,
                    subject: reasoningSubject,
                    object: reasoningObject
                )
            ])
            reasoningGeneration = response.generation
            status = String(
                // swiftlint:disable:next line_length
                localized: "Reasoning shadow refreshed with \(response.baseFactCount) asserted facts and \(response.derivedFactCount) derived facts."
            )
            await refreshReasoningFacts(reportFailure: true)
            await loadReasoningDetail(.whatChanged)
        } catch {
            status = String(localized: "Relation promotion failed closed; no fact or rule changed.")
        }
    }

    func retractSelectedReasoningRelation() async {
        guard let client,
              let factID = selectedReasoningFactID,
              let fact = reasoningFacts.first(where: { $0.id == factID }),
              fact.asserted,
              ResearchVaultReasoningRelationKind(rawValue: fact.predicate) != nil else {
            status = String(localized: "Only an asserted reviewed relation can be retracted.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.refreshReasoningRelations(removingFactIDs: [factID])
            reasoningGeneration = response.generation
            status = String(localized: "The selected relation was retracted from the reasoning shadow.")
            await refreshReasoningFacts(reportFailure: true)
            await loadReasoningDetail(.whatChanged)
        } catch {
            status = String(localized: "Relation retraction failed closed; no fact or rule changed.")
        }
    }

    func loadReasoningDetail(_ kind: ResearchVaultReasoningQueryKind) async {
        guard let client else { return }
        let factID = kind == .why || kind == .impacted ? selectedReasoningFactID : nil
        do {
            reasoningDetail = try await client.reasoning(
                ResearchVaultReasoningQuery(kind: kind, factID: factID, limit: 128)
            )
        } catch {
            reasoningDetail = nil
            status = String(localized: "The bounded reasoning explanation is unavailable.")
        }
    }
}
