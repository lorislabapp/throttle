import ResearchVaultModel
import ResearchVaultReasoning
import SwiftUI

extension ResearchVaultWorkbenchView {

    /// The vault read as claims rather than as receipts: every finding in the
    /// lane its evidence earns, and every claim one click from the exact source
    /// it rests on. A lane is shown only when it holds something, so the board
    /// never implies a conflict or a doubt that is not there.
    var claimsBoard: some View {
        let board = ResearchClaimsProjector.board(
            approvedReceipts: scopedApprovedReceipts,
            relations: model.promotedContradictions,
            latestSourceHashes: model.latestSourceHashes
        )
        return Group {
            if board.claims.isEmpty, board.openQuestions.isEmpty {
                ContentUnavailableView(
                    "No reviewed claims",
                    systemImage: "checkmark.message",
                    description: Text(
                        "A claim appears once its receipt is approved. It shows the source it rests on, "
                        + "and moves out of proof if that source changes."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(ResearchClaim.Lane.allCases, id: \.self) { lane in
                            let claims = board.claims(in: lane)
                            if !claims.isEmpty { laneSection(lane, claims: claims) }
                        }
                        if !board.openQuestions.isEmpty { openQuestionsSection(board.openQuestions) }
                        if !board.emptyReceiptIDs.isEmpty {
                            footnote("\(board.emptyReceiptIDs.count) approved receipt(s) carry no finding.")
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func laneSection(_ lane: ResearchClaim.Lane, claims: [ResearchClaim]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            laneHeader(Self.laneTitle(lane), count: claims.count, explanation: Self.laneExplanation(lane))
            ForEach(claims, id: \.reference.stableID) { claim in claimCard(claim) }
        }
    }

    private func claimCard(_ claim: ResearchClaim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(claim.status.rawValue).font(.caption2.weight(.bold))
                Text(claim.projectKey).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(claim.assertedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(claim.text).textSelection(.enabled)
            ForEach(claim.evidence, id: \.source.id) { item in evidenceRow(item) }
            if !claim.danglingEvidenceIDs.isEmpty {
                footnote("Cites \(claim.danglingEvidenceIDs.joined(separator: ", ")), "
                    + "which this receipt does not carry.")
            }
            if !claim.contradicts.isEmpty {
                footnote("Recorded against \(claim.contradicts.count) other claim(s).")
            }
            if claim.evidence.isEmpty, claim.danglingEvidenceIDs.isEmpty {
                footnote("No source attached.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(claim.text))
    }

    /// The whole point of the board: from a claim to the bytes it was made
    /// against. The button carries the hash and the date so a reader can judge
    /// the evidence without leaving the row.
    private func evidenceRow(_ item: ResearchClaimEvidence) -> some View {
        Button {
            model.selectedSourceID = ResearchVaultSourceRow.rowID(
                receiptID: item.receiptID, sourceID: item.source.id
            )
            pane = .sources
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.hasDrifted ? "clock.badge.exclamationmark" : "doc.text.magnifyingglass")
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.source.locator).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text(Self.evidenceDetail(item)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(Text("Show source \(item.source.locator)"))
        .accessibilityHint(Text(item.hasDrifted
            ? "This source changed after the claim was made."
            : "Opens the source panel on this entry."))
    }

    private func openQuestionsSection(_ questions: [ResearchOpenQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            laneHeader("Open questions", count: questions.count,
                       explanation: "Raised by a receipt and not answered anywhere yet.")
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question).textSelection(.enabled)
                    Text(question.projectKey + " · "
                        + question.askedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
            }
        }
    }

    private func laneHeader(_ title: LocalizedStringKey, count: Int, explanation: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }

    private static func evidenceDetail(_ item: ResearchClaimEvidence) -> String {
        let short = String(item.source.sha256.prefix(12))
        let observed = item.source.observedAt.formatted(date: .abbreviated, time: .omitted)
        guard let superseded = item.supersededByHash else { return "\(short) · seen \(observed)" }
        return "\(short) · seen \(observed) · now \(String(superseded.prefix(12)))"
    }

    private static func laneTitle(_ lane: ResearchClaim.Lane) -> LocalizedStringKey {
        switch lane {
        case .proof: "Proof"
        case .hypothesis: "Hypothesis"
        case .contradiction: "Contradiction"
        case .openQuestion: "Unresolved"
        case .drifted: "Source moved"
        }
    }

    private static func laneExplanation(_ lane: ResearchClaim.Lane) -> LocalizedStringKey {
        switch lane {
        case .proof: "Verified or supported, with every cited source present and unchanged."
        case .hypothesis: "Stated without evidence that resolves, so it carries no weight yet."
        case .contradiction: "Something recorded here disagrees. Read both sides before either."
        case .openQuestion: "Recorded as open, or left without a usable status."
        case .drifted: "The source changed after the claim was made. Re-check before reusing."
        }
    }
}
