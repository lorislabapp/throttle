import AppKit
import ResearchVaultModel
import ResearchVaultReasoning
import SwiftUI

extension ResearchVaultWorkbenchView {

    /// The vault read as claims rather than as receipts: one list, riskiest
    /// first, every claim one click from the exact source it rests on. A
    /// contradiction is a single row with both sides, so a reader never judges
    /// one side without the other in view.
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
                VStack(spacing: 0) {
                    laneFilter(board)
                    Divider()
                    ScrollView { claimsList(board).padding(.horizontal, 20) }
                }
            }
        }
    }

    private func claimsList(_ board: ResearchClaimsBoard) -> some View {
        let rows = ResearchClaimsRiskList.rows(board, lane: claimsLane, source: claimsSourceID)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("Nothing in this lane.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                claimRow(row)
                if index < rows.count - 1 || showsQuestions(board) { Divider() }
            }
            if showsQuestions(board) {
                ForEach(Array(board.openQuestions.enumerated()), id: \.offset) { _, question in
                    openQuestionRow(question)
                }
            }
            if claimsLane == nil, claimsSourceID == nil, !board.emptyReceiptIDs.isEmpty {
                footnote(String(localized: "\(board.emptyReceiptIDs.count) approved receipt(s) carry no finding."))
                    .padding(.vertical, 10)
            }
        }
    }

    private func showsQuestions(_ board: ResearchClaimsBoard) -> Bool {
        claimsSourceID == nil && (claimsLane == nil || claimsLane == .openQuestion) && !board.openQuestions.isEmpty
    }

    // MARK: Filter

    private func laneFilter(_ board: ResearchClaimsBoard) -> some View {
        let counts = board.counts
        return HStack(spacing: 6) {
            filterButton(title: "All", systemImage: nil, count: board.claims.count, lane: nil)
            ForEach(ResearchClaimsRiskList.lanes, id: \.self) { lane in
                filterButton(title: Self.laneTitle(lane), systemImage: Self.laneSymbol(lane),
                             count: counts[lane] ?? 0, lane: lane)
            }
            Spacer(minLength: 8)
            if let sourceID = claimsSourceID {
                Button { claimsSourceID = nil } label: {
                    Label(Self.sourceFilterTitle(sourceID, board: board), systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 180)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .help(Text("Show claims from every source"))
            } else {
                Text("Sorted by risk").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filter by status"))
    }

    private func filterButton(title: LocalizedStringKey, systemImage: String?, count: Int,
                              lane: ResearchClaim.Lane?) -> some View {
        let isOn = claimsLane == lane
        return Button {
            claimsLane = lane
            if lane == nil { claimsSourceID = nil }
        } label: {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(title)
                Text(verbatim: "\(count)").monospacedDigit().foregroundStyle(isOn ? .primary : .secondary)
            }
            .font(.system(size: 12, weight: isOn ? .semibold : .medium))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .foregroundStyle(isOn ? AnyShapeStyle(Color(nsColor: .textBackgroundColor))
                             : lane == .drifted ? AnyShapeStyle(Self.driftTint) : AnyShapeStyle(.primary))
            .background(isOn ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isOn ? Color.clear : Color.primary.opacity(0.10)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Rows

    private func claimRow(_ row: ResearchClaimsRiskList.Row) -> some View {
        HStack(alignment: .top, spacing: 16) {
            laneColumn(row)
            Group {
                switch row {
                case .opposed(let claim, let against): opposedBody(claim, against: against)
                case .claim(let claim): claimBody(claim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private func laneColumn(_ row: ResearchClaimsRiskList.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            laneLabel(row.lane, tinted: true)
            Text(Self.laneSubtitle(row)).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(width: 128, alignment: .leading)
    }

    private func laneLabel(_ lane: ResearchClaim.Lane, tinted: Bool) -> some View {
        Label(Self.laneTitle(lane), systemImage: Self.laneSymbol(lane))
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(lane == .drifted && tinted ? AnyShapeStyle(Self.driftTint)
                             : lane == .hypothesis || lane == .openQuestion ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(.primary))
    }

    private func claimBody(_ claim: ResearchClaim) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            claimText(claim.text)
            if claim.evidence.isEmpty {
                Text("No source · \(claim.projectKey) · \(Self.shortDate(claim.assertedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(claim.evidence, id: \.source.id) { evidenceRow($0) }
            danglingNote(claim)
            if claim.lane == .drifted, let moved = claim.evidence.first(where: \.hasDrifted) {
                HStack(spacing: 10) {
                    footnote(String(localized: "The source changed after the claim. Neither confirmed nor refuted."))
                    Spacer(minLength: 0)
                    Button("Re-check") { showSource(moved) }
                        .controlSize(.small)
                        .help(Text("Opens the source as it reads now."))
                }
            }
        }
    }

    private func opposedBody(_ claim: ResearchClaim, against: [ResearchClaim]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            opposedSide(claim)
            ForEach(against, id: \.reference.stableID) { other in
                HStack(spacing: 8) {
                    VStack { Divider() }
                    Text("AGAINST").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    VStack { Divider() }
                }
                .accessibilityHidden(true)
                opposedSide(other)
            }
        }
    }

    /// One side of a contradiction: its own status, and its first source with a
    /// count of the rest, so both sides stay short enough to read together.
    private func opposedSide(_ claim: ResearchClaim) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                claimText(claim.text)
                Spacer(minLength: 0)
                Text(Self.statusTitle(claim.status))
                    .font(.system(size: 11, weight: .bold)).textCase(.uppercase)
                    .foregroundStyle(claim.status == .verified || claim.status == .supported
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            if let first = claim.evidence.first {
                evidenceRow(first, extra: claim.evidence.count - 1, project: claim.projectKey)
            } else {
                Text("No source · \(claim.projectKey) · \(Self.shortDate(claim.assertedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            danglingNote(claim)
        }
        .accessibilityElement(children: .contain)
    }

    private func claimText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func danglingNote(_ claim: ResearchClaim) -> some View {
        if !claim.danglingEvidenceIDs.isEmpty {
            footnote(String(localized:
                "Cites \(claim.danglingEvidenceIDs.joined(separator: ", ")), which this receipt does not carry."))
        }
    }

    /// The whole point of the board: from a claim to the bytes it was made
    /// against. The row carries the hash and the date so a reader can judge the
    /// evidence without leaving the list.
    private func evidenceRow(_ item: ResearchClaimEvidence, extra: Int = 0, project: String? = nil) -> some View {
        Button { showSource(item) } label: {
            HStack(spacing: 7) {
                Image(systemName: item.hasDrifted ? "clock.badge.exclamationmark" : "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(item.hasDrifted ? AnyShapeStyle(Self.driftTint) : AnyShapeStyle(.secondary))
                Text(item.source.locator)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Self.evidenceDetail(item, extra: extra, project: project))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(item.hasDrifted ? AnyShapeStyle(Self.driftTint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Show source \(item.source.locator)"))
        .accessibilityHint(Text(item.hasDrifted
            ? "This source changed after the claim was made."
            : "Opens the source panel on this entry."))
    }

    private func showSource(_ item: ResearchClaimEvidence) {
        model.selectedSourceID = ResearchVaultSourceRow.rowID(receiptID: item.receiptID, sourceID: item.source.id)
        pane = .sources
    }

    private func openQuestionRow(_ question: ResearchOpenQuestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            laneLabel(.openQuestion, tinted: false)
                .frame(width: 128, alignment: .leading)
            Text(question.question).font(.system(size: 13)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "\(question.projectKey) · \(Self.shortDate(question.askedAt))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Wording

extension ResearchVaultWorkbenchView {
    /// Amber, not red: a moved source is something to re-read, not a failure.
    static let driftTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.94, green: 0.63, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.35, blue: 0.09, alpha: 1)
    })

    static func sourceFilterTitle(_ sourceID: String, board: ResearchClaimsBoard) -> String {
        let locator = board.claims.lazy.flatMap(\.evidence).first { $0.source.id == sourceID }?.source.locator
        return String(localized: "Source: \(locator ?? sourceID)")
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .omitted)
    }

    /// First and last four hex digits: enough to tell two versions apart at a
    /// glance, and the full hash is one click away in the source panel.
    static func shortHash(_ hash: String) -> String {
        guard hash.count > 8 else { return hash }
        return "\(hash.prefix(4))…\(hash.suffix(4))"
    }

    static func evidenceDetail(_ item: ResearchClaimEvidence, extra: Int, project: String?) -> String {
        var parts: [String] = []
        if extra > 0 { parts.append("+ \(extra)") }
        if let project { parts.append(project) }
        parts.append(shortHash(item.source.sha256))
        parts.append(item.source.observedAt.formatted(.dateTime.day(.twoDigits).month(.twoDigits)))
        let detail = parts.joined(separator: " · ")
        guard let now = item.supersededByHash else { return detail }
        return String(localized: "\(detail) → now \(shortHash(now))")
    }

    static func laneSubtitle(_ row: ResearchClaimsRiskList.Row) -> String {
        switch row {
        case .opposed(let claim, let against):
            return String(localized: "\(against.count + 1) claims · \(claim.projectKey)")
        case .claim(let claim):
            switch claim.lane {
            case .contradiction: return claim.projectKey
            case .drifted: return String(localized: "Re-check before reuse")
            case .openQuestion: return String(localized: "Nobody settled it")
            case .hypothesis: return String(localized: "Carries no weight")
            case .proof: return String(localized: "\(claim.evidence.count) source(s) unchanged")
            }
        }
    }

    static func laneTitle(_ lane: ResearchClaim.Lane) -> LocalizedStringKey {
        switch lane {
        case .proof: "Proof"
        case .hypothesis: "Hypothesis"
        case .contradiction: "Contradiction"
        case .openQuestion: "Unresolved"
        case .drifted: "Source moved"
        }
    }

    static func laneSymbol(_ lane: ResearchClaim.Lane) -> String {
        switch lane {
        case .proof: "checkmark"
        case .hypothesis: "circle.dashed"
        case .contradiction: "arrow.left.arrow.right"
        case .openQuestion: "questionmark.circle"
        case .drifted: "clock.badge.exclamationmark"
        }
    }

    /// Keyed apart from the verbs "Open" and "Verify": a status is an adjective
    /// and agrees with "affirmation" in French.
    static func statusTitle(_ status: ResearchEvidenceStatus) -> String {
        switch status {
        case .verified: String(localized: "claim.status.verified", defaultValue: "Verified")
        case .supported: String(localized: "claim.status.supported", defaultValue: "Supported")
        case .hypothesis: String(localized: "claim.status.hypothesis", defaultValue: "Hypothesis")
        case .open: String(localized: "claim.status.open", defaultValue: "Open")
        case .contradicted: String(localized: "claim.status.contradicted", defaultValue: "Contradicted")
        case .stale: String(localized: "claim.status.stale", defaultValue: "Stale")
        }
    }
}
