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
    var quarantineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quarantine (\(model.pendingItems.count))")
                    .font(.caption.weight(.semibold))
                Text("REVIEW REQUIRED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                if model.pendingItems.count > 1 {
                    Button("Approve all") {
                        Task {
                            await model.review(
                                model.pendingItems.map(\.receiptID),
                                action: .approve
                            )
                        }
                    }
                    Button("Reject all", role: .destructive) {
                        showBulkRejectConfirmation = true
                    }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.pendingItems, id: \.receiptID) { item in
                        quarantineRow(item)
                        if item.receiptID != model.pendingItems.last?.receiptID {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Reject all quarantined receipts?",
            isPresented: $showBulkRejectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reject all", role: .destructive) {
                Task {
                    await model.review(
                        model.pendingItems.map(\.receiptID),
                        action: .reject
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rejected receipts are removed from the encrypted vault.")
        }
    }

    func quarantineRow(_ item: ResearchVaultQuarantineItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.question)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.projectKey)
                    Text(item.sensitivity.uppercased())
                    Text(Date(timeIntervalSince1970: Double(item.createdAtMS) / 1_000).formatted())
                    Text("\(item.sourceCount) source(s)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                if let locator = item.firstSourceLocator {
                    Text(locator)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button("Approve") {
                Task { await model.review([item.receiptID], action: .approve) }
            }
            .buttonStyle(.borderless)
            Button("Reject", role: .destructive) {
                Task { await model.review([item.receiptID], action: .reject) }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    func resultCard(_ item: ResearchVaultContextItem, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(identifier).font(.caption2.bold()).foregroundStyle(.tint)
                Text(item.citation.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(item.citation.evidenceStatus?.rawValue.uppercased() ?? "UNCLASSIFIED")
                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            if let heading = item.heading { Text(heading).font(.caption.weight(.medium)) }
            Text(item.excerpt).font(.system(size: 12)).textSelection(.enabled)
            Text("\(item.citation.libraryPath) · \(item.citation.locator)")
                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("SHA-256 \(item.citation.excerptSHA256) · observed \(item.citation.observedAt.formatted())")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
