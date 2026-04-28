import AppKit
import Charts
import GRDB
import SwiftUI

/// Stats panel shown when the user picks "Stats…" in the dropdown.
/// Five cards stacked vertically; the popover scrolls.
///
/// Free vs Pro split:
///   Free: trend line, model donut, cost extrapolation
///   Pro:  hour-of-day heatmap, hook-savings counter, share badge
struct StatsInline: View {
    @Environment(AppState.self) private var appState
    let onBack: () -> Void

    @State private var range: StatsDataService.Range = .last7d
    @State private var linePoints: [StatsDataService.LinePoint] = []
    @State private var heatCells: [StatsDataService.HeatCell] = []
    @State private var modelSlices: [StatsDataService.ModelSlice] = []
    @State private var costEUR: Double = 0
    @State private var savedTokens: Int = 0
    @State private var topProjects: [StatsDataService.ProjectSlice] = []

    @State private var showShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            rangePicker
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    trendCard
                    modelSplitCard
                    if appState.isPro {
                        heatmapCard
                        topProjectsCard
                        savingsCard
                        shareBadgeCard
                    } else {
                        proTeaserCard
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 240, maxHeight: 420)
        }
        .task(id: range) { await reload() }
    }

    private var header: some View {
        HStack {
            Button { onBack() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Text("Stats").font(.headline)
            Spacer()
            Spacer().frame(width: 56)
        }
    }

    private var rangePicker: some View {
        Picker("", selection: $range) {
            ForEach(StatsDataService.Range.allCases) { r in
                Text(r.label).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Cards

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Usage trend").font(.subheadline.bold())
            if linePoints.isEmpty {
                Text("No history yet — keep using Claude Code, the chart fills as you go.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(linePoints, id: \.self) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.percent * 100)
                    )
                    .foregroundStyle(by: .value("Window", windowLabel(point.kind)))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: Decimal.FormatStyle().precision(.fractionLength(0)))
                    }
                }
                .chartLegend(position: .bottom, spacing: 4)
                .frame(height: 140)
            }
        }
    }

    private var modelSplitCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model split").font(.subheadline.bold())
            if modelSlices.isEmpty || modelSlices.allSatisfy({ $0.weightedTokens == 0 }) {
                Text("No model usage yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(modelSlices) { slice in
                    SectorMark(
                        angle: .value("Tokens", slice.weightedTokens),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(by: .value("Model", tierLabel(slice.tier)))
                    .cornerRadius(2)
                }
                .frame(height: 140)
                .chartLegend(position: .bottom, spacing: 4)
                Text("Estimated API cost: \(formatEUR(costEUR))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("(What this would have cost on the developer API at Anthropic's published rates.)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("When you burn tokens").font(.subheadline.bold())
            HeatmapGrid(cells: heatCells)
                .frame(height: 130)
            Text("Each cell is one (day, hour) bucket. Brighter = more weighted tokens.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var topProjectsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top projects by tokens").font(.subheadline.bold())
            if topProjects.isEmpty {
                Text("No project data yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(topProjects) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.projectName).font(.caption.bold())
                            Text(p.projectPath).font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(formatTokens(p.weightedTokens))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var savingsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Hooks saved you").font(.subheadline.bold())
                Spacer()
                Text(formatTokens(savedTokens))
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(.green)
            }
            Text("Tokens skipped by session-start-router.sh + structured pre-compact.sh in the last 7 days. Higher = more context preserved for actual work.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shareBadgeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Share your stats").font(.subheadline.bold())
            ShareBadgePreview(
                topStat: shareBadgeTopStat,
                subline: shareBadgeSubline
            )
            .frame(height: 84)
            Button {
                shareBadge()
            } label: {
                Label("Share badge", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var proTeaserCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "lock.fill")
                Text("Heatmap, savings counter, share badge").font(.subheadline)
                Spacer()
                Text("PRO").font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            Text("Three more cards — when (and where) you burn tokens, how much the hooks saved you, and a one-tap shareable badge.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Share badge

    private var shareBadgeTopStat: String {
        let pct: Int = {
            if let ex = appState.exactSnapshot, ex.isFresh() {
                return [
                    ex.fiveHour.utilization,
                    ex.sevenDay.utilization,
                    ex.sevenDaySonnet.utilization
                ].max() ?? 0
            }
            let local = [
                appState.snapshot.session5h.percentUsed,
                appState.snapshot.weeklyAll.percentUsed,
                appState.snapshot.weeklySonnet.percentUsed
            ].compactMap { $0 }.max() ?? 0
            return Int(local * 100)
        }()
        return "\(pct)% used"
    }

    private var shareBadgeSubline: String {
        if savedTokens > 0 {
            return "Saved \(formatTokens(savedTokens)) tokens this week with Throttle"
        }
        return "Tracking my Claude Code usage with Throttle"
    }

    @MainActor
    private func shareBadge() {
        let renderer = ImageRenderer(content: ShareBadgeImage(
            topStat: shareBadgeTopStat,
            subline: shareBadgeSubline
        ))
        renderer.scale = 2.0
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-stats.png")
        try? png.write(to: url)

        let picker = NSSharingServicePicker(items: [url])
        if let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first {
            picker.show(relativeTo: .zero, of: window.contentView ?? NSView(), preferredEdge: .minY)
        }
    }

    // MARK: - Data load

    private func reload() async {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        let r = range
        let line: [StatsDataService.LinePoint] = (try? await Task.detached {
            try pool.read { try StatsDataService.linePoints(in: $0, range: r) }
        }.value) ?? []
        let heat: [StatsDataService.HeatCell] = (try? await Task.detached {
            try pool.read { try StatsDataService.heatmap(in: $0, range: r) }
        }.value) ?? []
        let model: [StatsDataService.ModelSlice] = (try? await Task.detached {
            try pool.read { try StatsDataService.modelSplit(in: $0, range: r) }
        }.value) ?? []
        let cost: Double = (try? await Task.detached {
            try pool.read { try StatsDataService.extrapolatedCostEUR(in: $0, range: r) }
        }.value) ?? 0
        let saved: Int = (try? await Task.detached {
            try pool.read { try StatsDataService.savedTokensThisWeek(in: $0) }
        }.value) ?? 0
        let projects: [StatsDataService.ProjectSlice] = (try? await Task.detached {
            try pool.read { try StatsDataService.topProjects(in: $0, range: r) }
        }.value) ?? []
        await MainActor.run {
            self.linePoints = line
            self.heatCells = heat
            self.modelSlices = model
            self.costEUR = cost
            self.savedTokens = saved
            self.topProjects = projects
        }
    }

    // MARK: - Formatting

    private func windowLabel(_ k: WindowKind) -> String {
        switch k {
        case .session5h:    return "Session"
        case .weeklyAll:    return "Weekly all"
        case .weeklySonnet: return "Weekly Sonnet"
        }
    }

    private func tierLabel(_ t: ModelTier) -> String {
        switch t {
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .other:  return "Other"
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func formatEUR(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "€0"
    }
}

// MARK: - Heatmap grid

private struct HeatmapGrid: View {
    let cells: [StatsDataService.HeatCell]

    private var maxValue: Int {
        cells.map(\.weightedTokens).max() ?? 1
    }

    private var lookup: [Int: [Int: Int]] {
        var out: [Int: [Int: Int]] = [:]
        for c in cells {
            out[c.dayOfWeek, default: [:]][c.hour] = c.weightedTokens
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let cellW = geo.size.width / 24
            let cellH = geo.size.height / 7
            ZStack(alignment: .topLeading) {
                ForEach(1...7, id: \.self) { dow in
                    ForEach(0..<24, id: \.self) { hour in
                        let value = lookup[dow]?[hour] ?? 0
                        let intensity = maxValue > 0 ? Double(value) / Double(maxValue) : 0
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.10 + 0.85 * intensity))
                            .frame(width: cellW - 1, height: cellH - 1)
                            .offset(x: CGFloat(hour) * cellW, y: CGFloat(dow - 1) * cellH)
                    }
                }
            }
        }
    }
}

// MARK: - Share badge image

private struct ShareBadgePreview: View {
    let topStat: String
    let subline: String
    var body: some View {
        ShareBadgeImage(topStat: topStat, subline: subline)
            .scaleEffect(0.18)
            .frame(width: 1200 * 0.18, height: 630 * 0.18)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ShareBadgeImage: View {
    let topStat: String
    let subline: String

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.18),
                         Color(red: 0.18, green: 0.22, blue: 0.32)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 96))
                        .foregroundStyle(.white)
                    Text("Throttle")
                        .font(.system(size: 88, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(topStat)
                    .font(.system(size: 156, weight: .heavy))
                    .foregroundStyle(.white)
                Text(subline)
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("lorislab.fr/throttle")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(60)
        }
        .frame(width: 1200, height: 630)
    }
}
