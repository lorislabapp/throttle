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
    var sourceList: some View {
        let rows = ResearchVaultWorkbenchProjection.sources(receipts: scopedApprovedReceipts)
        return Group {
            if rows.isEmpty {
                ContentUnavailableView("No approved sources", systemImage: "doc.badge.clock")
            } else {
                let claimCounts = ResearchVaultWorkbenchProjection
                    .claimCountsBySource(receipts: scopedApprovedReceipts)
                let latest = model.latestSourceHashes
                List(rows, selection: $model.selectedSourceID) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.source.locator).font(.callout.weight(.semibold))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(row.sensitivity.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                        }
                        Text(
                            "\(row.projectKey) · \(ResearchVaultWorkbenchProjection.origin(of: row.source))"
                            + " · observed \(row.ageDays)d ago"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Text("SHA-256 \(row.source.sha256)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Text(Self.sourceStanding(
                            claims: claimCounts[row.source.id] ?? 0,
                            hasMoved: latest[row.source.id].map { $0 != row.source.sha256 } == true
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// What this source is worth to the vault, in one line: how many claims
    /// rest on it, and whether it still reads as it did when they were made.
    static func sourceStanding(claims: Int, hasMoved: Bool) -> String {
        let rest = claims == 0
            ? "No claim rests on it"
            : "\(claims) claim(s) rest on it"
        return hasMoved ? rest + " · content changed since" : rest
    }

    var timelineList: some View {
        let receipts = scopedApprovedReceipts.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.receiptID < $1.receiptID
        }
        return Group {
            if receipts.isEmpty {
                ContentUnavailableView("No approved history", systemImage: "clock.arrow.circlepath")
            } else {
                List(receipts, id: \.receiptID) { receipt in
                    let sourceCount = receipt.sources.count
                    let claimCount = receipt.findings.count
                    let sensitivity = receipt.sensitivity.rawValue.uppercased()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(receipt.createdAt.formatted()).font(.caption.monospacedDigit())
                            Text(receipt.projectKey).font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(receipt.contentHash.prefix(12)))
                                .font(.caption2.monospaced())
                        }
                        Text(receipt.question).textSelection(.enabled)
                        Text("\(sourceCount) sources · \(claimCount) claims · \(sensitivity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    var revisionList: some View {
        let revisions = ResearchVaultWorkbenchProjection.revisions(
            receipts: scopedApprovedReceipts
        )
        let audit = ResearchVaultWorkbenchProjection.taxonomyAudit(
            receipts: scopedApprovedReceipts
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Taxonomy audit").font(.caption.weight(.semibold))
                Text("\(audit.projectKeys.count) projects")
                Text("\(audit.sourceKinds.count) source kinds")
                Text("\(audit.evidenceStatuses.count) evidence states")
                Spacer()
                Text("\(audit.orphanEvidenceReferences) orphan references")
                    .foregroundStyle(
                        audit.orphanEvidenceReferences == 0 ? Color.secondary : Color.red
                    )
            }
            .font(.caption.monospacedDigit())
            .padding(12)
            Divider()
            if revisions.isEmpty {
                ContentUnavailableView(
                    "No revised source detected",
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                List(revisions) { revision in
                    let versionCount = revision.versions.count
                    let impactedClaimCount = revision.impactedClaims.count
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.locator).font(.callout.weight(.semibold))
                        Text("\(versionCount) hashed versions · \(impactedClaimCount) impacted claims")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        ForEach(revision.impactedClaims) { claim in
                            Text("\(claim.status.rawValue): \(claim.claim)")
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
