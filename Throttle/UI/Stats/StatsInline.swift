import AppKit
import GRDB
import SwiftUI

// SwiftUI Charts intentionally NOT imported — its first-render Metal
// preload crashes (RB::Device::preload_resources → precondition_failure)
// in MenuBarExtra popovers on macOS 26.5 (FB16xxxxx). Hand-drawn Path /
// Rectangle visuals below render in CoreGraphics only and are safe.

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
                    shareBadgeCard
                    if appState.isPro {
                        heatmapCard
                        topProjectsCard
                        savingsCard
                    } else {
                        proTeaserCard
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 240, maxHeight: 420)
        }
        .onAppear {
            AppLogger.app.notice("StatsInline.onAppear range=\(self.range.label, privacy: .public)")
            Task { await reload() }
        }
        .onChange(of: range) { _, newRange in
            AppLogger.app.notice("StatsInline.onChange range=\(newRange.label, privacy: .public)")
            Task { await reload() }
        }
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
                LineChart(points: linePoints)
                    .frame(height: 120)
                trendLegend
            }
        }
    }

    private var trendLegend: some View {
        HStack(spacing: 12) {
            ForEach([WindowKind.session5h, .weeklyAll, .weeklySonnet], id: \.self) { kind in
                HStack(spacing: 4) {
                    Circle().fill(color(for: kind)).frame(width: 8, height: 8)
                    Text(windowLabel(kind)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    static func color(for kind: WindowKind) -> Color {
        switch kind {
        case .session5h:    return .blue
        case .weeklyAll:    return .orange
        case .weeklySonnet: return .purple
        }
    }
    private func color(for kind: WindowKind) -> Color { Self.color(for: kind) }

    private var modelSplitCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model split").font(.subheadline.bold())
            if modelSlices.isEmpty || modelSlices.allSatisfy({ $0.weightedTokens == 0 }) {
                Text("No model usage yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let total = max(1, modelSlices.reduce(0) { $0 + $1.weightedTokens })
                VStack(spacing: 6) {
                    ForEach(modelSlices) { slice in
                        modelRow(slice, totalTokens: total)
                    }
                }
                Text("Estimated API cost: \(formatEUR(costEUR))")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
                Text("(What this would have cost on the developer API at Anthropic's published rates.)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modelRow(_ slice: StatsDataService.ModelSlice, totalTokens: Int) -> some View {
        let pct = Double(slice.weightedTokens) / Double(totalTokens)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(tierLabel(slice.tier)).font(.caption.bold())
                Spacer()
                Text("\(formatTokens(slice.weightedTokens)) · \(Int(pct * 100))%")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(modelColor(slice.tier))
                        .frame(width: max(2, geo.size.width * pct))
                }
            }
            .frame(height: 6)
        }
    }

    private func modelColor(_ tier: ModelTier) -> Color {
        switch tier {
        case .opus:   return .purple
        case .sonnet: return .blue
        case .haiku:  return .orange
        case .other:  return .gray
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
        let saved = max(savedTokens, appState.savedTokensThisWeek)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Hooks saved you").font(.subheadline.bold())
                Spacer()
                Text(formatTokens(saved))
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
        // Use AppState's already-populated savings value rather than the
        // separately-queried `savedTokens`, which can lag if reload() hasn't
        // fired yet. AppState updates whenever the savings ingester runs.
        let saved = max(savedTokens, appState.savedTokensThisWeek)
        if saved > 0 {
            return "\(formatTokens(saved)) tokens saved"
        }
        let pct: Int = {
            if let ex = appState.exactSnapshot, ex.isFresh() {
                return [ex.fiveHour.utilization, ex.sevenDay.utilization, ex.sevenDaySonnet.utilization].max() ?? 0
            }
            let local = [
                appState.snapshot.session5h.percentUsed,
                appState.snapshot.weeklyAll.percentUsed,
                appState.snapshot.weeklySonnet.percentUsed
            ].compactMap { $0 }.max() ?? 0
            return Int(local * 100)
        }()
        return "\(pct)% of my Claude cap"
    }

    private var shareBadgeSubline: String {
        let saved = max(savedTokens, appState.savedTokensThisWeek)
        if saved > 0 {
            return "this week with Throttle's open-source token-opt hooks"
        }
        return "Tracking with Throttle — live menu-bar Claude Code meter"
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
        let database = appState.database
        let r = range
        AppLogger.app.notice("Stats.reload start range=\(r.label, privacy: .public)")

        struct Bundle: Sendable {
            var line: [StatsDataService.LinePoint] = []
            var heat: [StatsDataService.HeatCell] = []
            var model: [StatsDataService.ModelSlice] = []
            var cost: Double = 0
            var saved: Int = 0
            var projects: [StatsDataService.ProjectSlice] = []
            var firstError: String?
        }

        let bundle: Bundle = await Task.detached {
            var b = Bundle()
            do { b.line = try database.read { try StatsDataService.linePoints(in: $0, range: r) } }
            catch { b.firstError = "linePoints: \(error)" }

            do { b.heat = try database.read { try StatsDataService.heatmap(in: $0, range: r) } }
            catch { if b.firstError == nil { b.firstError = "heatmap: \(error)" } }

            do { b.model = try database.read { try StatsDataService.modelSplit(in: $0, range: r) } }
            catch { if b.firstError == nil { b.firstError = "modelSplit: \(error)" } }

            do { b.cost = try database.read { try StatsDataService.extrapolatedCostEUR(in: $0, range: r) } }
            catch { if b.firstError == nil { b.firstError = "cost: \(error)" } }

            do { b.saved = try database.read { try StatsDataService.savedTokensThisWeek(in: $0) } }
            catch { if b.firstError == nil { b.firstError = "saved: \(error)" } }

            do { b.projects = try database.read { try StatsDataService.topProjects(in: $0, range: r) } }
            catch { if b.firstError == nil { b.firstError = "projects: \(error)" } }
            return b
        }.value

        if let err = bundle.firstError {
            AppLogger.app.error("Stats.reload error: \(err, privacy: .public)")
        }
        AppLogger.app.notice("Stats.reload done — line=\(bundle.line.count) heat=\(bundle.heat.count) model=\(bundle.model.count) projects=\(bundle.projects.count) saved=\(bundle.saved)")

        await MainActor.run {
            self.linePoints = bundle.line
            self.heatCells = bundle.heat
            self.modelSlices = bundle.model
            self.costEUR = bundle.cost
            self.savedTokens = bundle.saved
            self.topProjects = bundle.projects
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

// MARK: - Line chart (CoreGraphics, no Metal)

private struct LineChart: View {
    let points: [StatsDataService.LinePoint]

    var body: some View {
        Canvas { context, size in
            guard !points.isEmpty else { return }
            let bounds = computeBounds()
            let yMax = computeYMax()
            let plotLeft: CGFloat = 28
            let plotWidth = size.width - plotLeft
            let plotHeight = size.height - 4

            // Gridlines at 0, mid, max
            let yMarks = [0.0, yMax / 2.0, yMax]
            for yVal in yMarks {
                let yPos = plotHeight * (1 - CGFloat(yVal / yMax)) + 2
                var path = Path()
                path.move(to: CGPoint(x: plotLeft, y: yPos))
                path.addLine(to: CGPoint(x: size.width, y: yPos))
                context.stroke(path, with: .color(.secondary.opacity(0.20)), lineWidth: 0.5)

                let label = Text("\(Int(yVal))%")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: 4, y: yPos), anchor: .leading)
            }

            // One series per window kind
            for kind in [WindowKind.session5h, .weeklyAll, .weeklySonnet] {
                drawSeries(in: &context, kind: kind, size: size, bounds: bounds, yMax: yMax,
                           plotLeft: plotLeft, plotWidth: plotWidth, plotHeight: plotHeight)
            }
        }
    }

    private func drawSeries(in context: inout GraphicsContext,
                            kind: WindowKind,
                            size: CGSize,
                            bounds: (Date, Date),
                            yMax: Double,
                            plotLeft: CGFloat,
                            plotWidth: CGFloat,
                            plotHeight: CGFloat) {
        let kindPoints = points.filter { $0.kind == kind }
        guard !kindPoints.isEmpty else { return }
        let span = max(1, bounds.1.timeIntervalSince(bounds.0))
        let color = StatsInline.color(for: kind)

        let coords: [CGPoint] = kindPoints.map { p in
            let x = plotLeft + CGFloat(p.timestamp.timeIntervalSince(bounds.0) / span) * plotWidth
            let y = plotHeight * (1 - CGFloat((p.percent * 100) / yMax)) + 2
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: coords[0])
        for c in coords.dropFirst() { path.addLine(to: c) }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

        for c in coords {
            let dot = CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(color))
        }
    }

    private func computeBounds() -> (Date, Date) {
        guard let earliest = points.map(\.timestamp).min(),
              let latest = points.map(\.timestamp).max() else {
            let now = Date()
            return (now, now.addingTimeInterval(60))
        }
        if earliest == latest { return (earliest, earliest.addingTimeInterval(60)) }
        return (earliest, latest)
    }

    private func computeYMax() -> Double {
        let maxPct = points.map { $0.percent * 100 }.max() ?? 0
        if maxPct >= 50  { return 100 }
        if maxPct >= 25  { return 50 }
        if maxPct >= 10  { return 25 }
        return 10
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

/// In-popover preview. Doesn't use the full-size ShareBadgeImage — that
/// view's intrinsic size is 1200×630 and scaleEffect doesn't shrink the
/// layout claim, only the visual scale, so it overlaps siblings.
/// This is a hand-rolled compact mirror of the same look.
private struct ShareBadgePreview: View {
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 14)).foregroundStyle(.white)
                    Text("Throttle")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text("lorislab.fr/throttle")
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                }
                Text(topStat)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(subline)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                HStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Made with Throttle")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("lorislab.fr/throttle")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(60)
        }
        .frame(width: 1200, height: 630)
    }
}
