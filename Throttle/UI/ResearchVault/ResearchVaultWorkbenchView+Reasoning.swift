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

extension ResearchVaultWorkbenchView {
    var reasoningList: some View {
        let references = model.reasoningClaimReferences
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("Relation", selection: $model.reasoningRelation) {
                    ForEach(ResearchVaultReasoningRelationKind.allCases, id: \.self) {
                        Text($0.localizedTitle).tag($0)
                    }
                }
                .frame(width: 150)
                Picker("Subject claim", selection: $model.reasoningSubject) {
                    Text("Subject claim").tag(Optional<ResearchVaultReasoningClaimReference>.none)
                    ForEach(references, id: \.reference) { item in
                        Text(item.title).tag(Optional(item.reference))
                    }
                }
                Picker("Object claim", selection: $model.reasoningObject) {
                    Text("Object claim").tag(Optional<ResearchVaultReasoningClaimReference>.none)
                    ForEach(references, id: \.reference) { item in
                        Text(item.title).tag(Optional(item.reference))
                    }
                }
                Button("Review relation…") {
                    showReasoningPromotionConfirmation = true
                }
                .disabled(
                    model.reasoningSubject == nil
                        || model.reasoningObject == nil
                        || model.reasoningSubject == model.reasoningObject
                )
                Spacer()
                if let generation = model.reasoningGeneration {
                    Text("Generation \(generation) · SHADOW")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .accessibilityElement(children: .contain)

            Divider()

            HStack(spacing: 8) {
                Button("All facts") { Task { await model.refreshReasoningFacts() } }
                Button("Why we believe this") { Task { await model.loadReasoningDetail(.why) } }
                    .disabled(model.selectedReasoningFactID == nil)
                Button("Impacted claims") { Task { await model.loadReasoningDetail(.impacted) } }
                    .disabled(model.selectedReasoningFactID == nil)
                Button("What changed") { Task { await model.loadReasoningDetail(.whatChanged) } }
                Button("Unresolved contradictions") {
                    Task { await model.loadReasoningDetail(.contradictions) }
                }
                Button("Retract relation…", role: .destructive) {
                    showReasoningRetractionConfirmation = true
                }
                .disabled(!model.canRetractSelectedReasoningRelation)
                Spacer()
                Text("ASSERTED ≠ DERIVED · MODEL OUTPUT IS NEVER A RULE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HSplitView {
                Group {
                    if model.reasoningFacts.isEmpty {
                        ContentUnavailableView(
                            "Reasoning shadow not initialized",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    } else {
                        List(model.reasoningFacts, id: \.id) { fact in
                            Button {
                                model.selectedReasoningFactID = fact.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(fact.asserted ? "ASSERTED" : "DERIVED")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(fact.asserted ? Color.blue : Color.purple)
                                        Text(fact.predicate).font(.callout.weight(.semibold))
                                        Spacer()
                                        if fact.id == model.selectedReasoningFactID {
                                            Image(systemName: "checkmark.circle.fill")
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    Text(fact.arguments.joined(separator: " → "))
                                        .font(.caption.monospaced())
                                        .lineLimit(2)
                                    Text("\(fact.receiptIDs.count) receipts · \(fact.sourceIDs.count) sources")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(fact.asserted ? "Asserted" : "Derived") \(fact.predicate)"
                            )
                            .accessibilityHint("Select this fact to inspect proof or impact")
                        }
                    }
                }
                .frame(minWidth: 340)

                reasoningDetailView
                    .frame(minWidth: 420)
            }
        }
    }

    @ViewBuilder
    var reasoningDetailView: some View {
        if let detail = model.reasoningDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(detail.kind.rawValue).font(.headline)
                        Spacer()
                        if detail.truncated {
                            Text("TRUNCATED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    if !detail.addedFactIDs.isEmpty {
                        reasoningIDGroup("Added", values: detail.addedFactIDs)
                    }
                    if !detail.removedFactIDs.isEmpty {
                        reasoningIDGroup("Removed", values: detail.removedFactIDs)
                    }
                    if !detail.updatedFactIDs.isEmpty {
                        reasoningIDGroup("Updated", values: detail.updatedFactIDs)
                    }
                    ForEach(detail.facts, id: \.id) { fact in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(fact.asserted ? "Asserted fact" : "Derived fact"): \(fact.predicate)")
                                .font(.callout.weight(.semibold))
                            Text(fact.arguments.joined(separator: " → "))
                                .font(.caption.monospaced())
                            ForEach(fact.receiptIDs, id: \.self) { receiptID in
                                Text("Receipt \(receiptID)").font(.caption2.monospaced())
                            }
                            ForEach(fact.sourceIDs, id: \.self) { sourceID in
                                Text(reasoningSourceDescription(
                                    receiptIDs: fact.receiptIDs,
                                    sourceID: sourceID
                                ))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(Array(detail.derivations.enumerated()), id: \.offset) { _, derivation in
                        Text(
                            "Rule \(derivation.ruleID): "
                                + derivation.premiseFactIDs.joined(separator: ", ")
                        )
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Select a reasoning action",
                systemImage: "list.bullet.rectangle.portrait"
            )
        }
    }

    func reasoningIDGroup(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(values, id: \.self) { Text($0).font(.caption2.monospaced()) }
        }
        .textSelection(.enabled)
    }

    func reasoningSourceDescription(receiptIDs: [String], sourceID: String) -> String {
        for receipt in scopedApprovedReceipts where receiptIDs.contains(receipt.receiptID) {
            if let source = receipt.sources.first(where: { $0.id == sourceID }) {
                return "Source \(sourceID) · \(source.locator) · SHA-256 \(source.sha256)"
            }
        }
        return "Source \(sourceID) · exact locator unavailable"
    }
}
