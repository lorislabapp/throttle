import AppKit
import SwiftUI

extension MultiCockpitRoot {

    /// The strip a person meets when they come back. Collapsed, it is one line:
    /// how long they were away, a chip for each session that is blocked on
    /// them, and a count for the rest. The terminal keeps its height; the
    /// sentences are one click away for whoever wants them.
    ///
    /// Only the top tier gets a chip. Progress, spend and heuristics stay in
    /// plain text, because a strip that shouts about everything teaches people
    /// to dismiss it without reading.
    @ViewBuilder
    func reentryPanel(_ digest: SessionReentryDigest) -> some View {
        let waiting = digest.items(in: .waitingOnYou)
        let moved = digest.items(in: .moved)
        let quiet = digest.items(in: .quiet)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(String(localized: "Away \(SessionReentryDigest.duration(digest.awayDuration))"))
                    .font(.system(size: 11.5, weight: .semibold))
                ForEach(waiting.prefix(Self.maxChips)) { reentryChip($0) }
                if waiting.count > Self.maxChips {
                    Text(String(localized: "+\(waiting.count - Self.maxChips) waiting"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let rest = Self.restLine(moved: moved.count, quiet: quiet.count) {
                    Text(rest).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let spent = digest.spentWhileAwayEUR, spent > 0 {
                    Text(verbatim: String(localized: "€\(String(format: "%.2f", spent)) spent"))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(reentryExpanded ? "Hide details" : "Details") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { reentryExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .accessibilityValue(Text(reentryExpanded ? "Expanded" : "Collapsed"))
                Button("Dismiss") {
                    reentryExpanded = false
                    model.dismissReentryDigest()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if reentryExpanded { reentryDetails(digest) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(digest.headline))
    }

    /// The full sentences, shown only on request.
    @ViewBuilder
    private func reentryDetails(_ digest: SessionReentryDigest) -> some View {
        ForEach([SessionReentryDigest.Tier.waitingOnYou, .moved], id: \.self) { tier in
            let items = digest.items(in: tier)
            if !items.isEmpty { tierRows(tier, items: items) }
        }
        let quiet = digest.items(in: .quiet)
        if !quiet.isEmpty {
            Text(Self.quietLine(quiet.map(\.name)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Past three chips the strip wraps on a narrow window; the rest is a count.
    static let maxChips = 3

    /// One session that is blocked on the person. The chip opens it.
    private func reentryChip(_ item: SessionReentryDigest.Item) -> some View {
        Button {
            model.activeID = item.id
            reentryExpanded = false
            model.dismissReentryDigest()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(item.name).font(.system(size: 11.5, weight: .medium))
                if let badge = item.badge {
                    Text(badge).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.10)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(item.headline)
        .accessibilityLabel(Text(item.name + ": " + item.headline))
        .accessibilityHint(Text("Opens this session."))
    }

    /// The sessions that do not need the person, as counts rather than names.
    static func restLine(moved: Int, quiet: Int) -> String? {
        switch (moved, quiet) {
        case (0, 0): return nil
        case (_, 0): return String(localized: "\(moved) moved on")
        case (0, _): return String(localized: "\(quiet) quiet")
        default: return String(localized: "\(moved) moved on · \(quiet) quiet")
        }
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
        case .waitingOnYou: return String(localized: "WAITING ON YOU")
        case .moved: return String(localized: "MOVED ON")
        case .quiet: return String(localized: "QUIET")
        }
    }

    /// Silent sessions are one line, never one row each: they are the part a
    /// returning reader can safely skip.
    static func quietLine(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        if names.count <= 3 { return String(localized: "Quiet: \(names.joined(separator: ", "))") }
        let shown = names.prefix(3).joined(separator: ", ")
        return String(localized: "Quiet: \(shown) and \(names.count - 3) more")
    }
}
