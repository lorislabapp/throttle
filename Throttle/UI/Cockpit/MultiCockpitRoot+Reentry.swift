import AppKit
import SwiftUI

extension MultiCockpitRoot {

    /// The panel a person meets when they come back. It answers one question —
    /// what happened while I was away — and then gets out of the way.
    ///
    /// Only the top tier is stated as needing them. Progress, spend and
    /// heuristics sit below it in plain language, because a panel that shouts
    /// about everything teaches people to close it without reading.
    @ViewBuilder
    func reentryPanel(_ digest: SessionReentryDigest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(digest.headline)
                    .font(.system(size: 12, weight: .semibold))
                if let spent = digest.spentWhileAwayEUR, spent > 0 {
                    Text(String(format: "€%.2f spent", spent))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Dismiss") { model.dismissReentryDigest() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
            }
            ForEach(SessionReentryDigest.Tier.allCases, id: \.self) { tier in
                let items = digest.items(in: tier)
                if tier != .quiet, !items.isEmpty { tierRows(tier, items: items) }
            }
            if !digest.items(in: .quiet).isEmpty {
                Text(Self.quietLine(digest.items(in: .quiet).map(\.name)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(digest.headline))
    }

    @ViewBuilder
    private func tierRows(_ tier: SessionReentryDigest.Tier,
                          items: [SessionReentryDigest.Item]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.tierTitle(tier))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            ForEach(items) { item in
                Button {
                    model.activeID = item.id
                    model.dismissReentryDigest()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(minWidth: 90, alignment: .leading)
                        Text(item.headline).font(.system(size: 11.5))
                        if let note = item.note {
                            Text("· " + note)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.name + ": " + item.headline))
                .accessibilityHint(Text("Opens this session."))
            }
        }
    }

    static func tierTitle(_ tier: SessionReentryDigest.Tier) -> String {
        switch tier {
        case .waitingOnYou: return "WAITING ON YOU"
        case .moved: return "MOVED ON"
        case .quiet: return "QUIET"
        }
    }

    /// Silent sessions are one line, never one row each: they are the part a
    /// returning reader can safely skip.
    static func quietLine(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        if names.count <= 3 { return "Quiet: " + names.joined(separator: ", ") }
        return "Quiet: " + names.prefix(3).joined(separator: ", ")
            + " and \(names.count - 3) more"
    }
}
