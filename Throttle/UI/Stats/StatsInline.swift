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
    @State private var todayTokens: Int = 0
    @State private var yesterdayTokens: Int = 0
    @State private var thisWeekTokens: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            rangePicker
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    comparisonCards
                    trendCard
                    modelSplitCard
                    planAdvisorCard
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

    /// Three at-a-glance cards: today, yesterday, this week.
    /// Today vs yesterday gets a delta arrow so you instantly see if you're
    /// burning faster than usual. This week is just an absolute number — the
    /// week-over-week comparison would need a 4th card to fit and gets noisy.
    private var comparisonCards: some View {
        HStack(spacing: 8) {
            comparisonCard(title: String(localized: "Today"),
                           tokens: todayTokens,
                           previousTokens: yesterdayTokens,
                           showDelta: true)
            comparisonCard(title: String(localized: "Yesterday"),
                           tokens: yesterdayTokens,
                           previousTokens: 0,
                           showDelta: false)
            comparisonCard(title: String(localized: "This week"),
                           tokens: thisWeekTokens,
                           previousTokens: 0,
                           showDelta: false)
        }
    }

    private func comparisonCard(title: String,
                                 tokens: Int,
                                 previousTokens: Int,
                                 showDelta: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatTokens(tokens))
                    .font(.title3.bold().monospacedDigit())
                if showDelta, previousTokens > 0 {
                    let pct = Double(tokens - previousTokens) / Double(previousTokens) * 100
                    Image(systemName: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(pct >= 0 ? .red : .green)
                    Text("\(pct >= 0 ? "+" : "")\(Int(pct.rounded()))%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(pct >= 0 ? .red : .green)
                }
            }
            Text("tokens · cache-adjusted")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help("Cache reads bill at ~10% of input rate; cache writes at ~125%. Throttle weights them to a single comparable number.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

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

    /// Linearly extrapolate the current range's cost to a 30-day month.
    /// Returns nil for ranges where extrapolation would be misleading
    /// (less than 6 hours of data, or "All time" which is already past).
    private var monthlyProjection: Double? {
        let hours: Double
        switch range {
        case .last24h: hours = 24
        case .last7d:  hours = 168
        case .last30d: hours = 720
        case .all:     return nil
        }
        guard hours >= 6, costEUR > 0 else { return nil }
        return costEUR * (720.0 / hours)
    }

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
                Text("If you were paying API rates: \(formatEUR(costEUR))")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
                if let projection = monthlyProjection {
                    Text("Extrapolated to a full month: \(formatEUR(projection))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 2)
                }
                Text("Reference number — Anthropic's per-token developer-API rates. Your Claude subscription cost is unrelated and stays at $20–$200/mo.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Subscription advisor — based on the actual weighted-token usage
    /// in the current range, recommends the best Anthropic offering and
    /// the EUR/mo delta vs the user's current plan. Surfaces an extra
    /// hint about Console credits at up to −30% when usage is spiky.
    /// Hidden when the dataset is too thin to advise reliably (<6 h or
    /// zero tokens).
    private var planAdvisorCard: some View {
        let weeklyTokens: Int
        switch range {
        case .last24h: weeklyTokens = totalTokens * 7
        case .last7d:  weeklyTokens = totalTokens
        case .last30d: weeklyTokens = totalTokens * 7 / 30
        case .all:     weeklyTokens = 0
        }
        let opusFraction = computeOpusFraction()
        let verdict: PlanAdvisor.Verdict? = (weeklyTokens > 0 && range != .all)
            ? PlanAdvisor.recommend(weeklyWeightedTokens: weeklyTokens,
                                    opusFraction: opusFraction,
                                    currentPlanID: currentPlanID,
                                    dailyVarianceCoeff: 0)
            : nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("Best plan for your usage").font(.subheadline.bold())
            if let v = verdict {
                ForEach(PlanAdvisor.plans, id: \.id) { p in
                    HStack {
                        Text(p.label)
                            .font(.caption.weight(p.id == v.bestPlanID ? .bold : .regular))
                            .foregroundStyle(p.id == v.bestPlanID ? .primary : .secondary)
                        Spacer()
                        if p.id == "free" {
                            Text("—").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        } else {
                            Text(formatEUR(p.monthlyEUR) + "/mo")
                                .font(.caption.monospaced())
                                .foregroundStyle(p.id == v.bestPlanID ? .primary : .secondary)
                        }
                        if p.id == v.bestPlanID {
                            Text(String(localized: "best"))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                .foregroundStyle(Color.green)
                        }
                    }
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Text(String(localized: "API equivalent"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatEUR(v.apiEquivalentMonthlyEUR) + "/mo")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Text(v.reasoning)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .padding(.top, 2)
                if let extra = v.extraCreditHint {
                    Text(extra)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Reference numbers — Anthropic API rates × your model split. Real subscriptions hit caches more often, so the API column is a conservative upper bound.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                Text("Need at least 6 h of usage in the current range to advise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Total weighted tokens visible in `modelSlices` — used by the plan
    /// advisor to project to the weekly figure plans are sized against.
    private var totalTokens: Int {
        modelSlices.reduce(0) { $0 + $1.weightedTokens }
    }

    /// 0…1 share of usage on Opus models. Falls back to 0.30 when the
    /// model split data isn't loaded yet so the advisor still has
    /// something reasonable to anchor against.
    private func computeOpusFraction() -> Double {
        let total = totalTokens
        guard total > 0 else { return 0.30 }
        let opus = modelSlices
            .filter { $0.tier == .opus }
            .reduce(0) { $0 + $1.weightedTokens }
        return Double(opus) / Double(total)
    }

    /// User's current plan id, persisted as a UserDefaults string. Maps
    /// the calibration's "Pro / Max 5× / Max 20×" choice. Returns nil
    /// when the user hasn't set one (the advisor then frames the verdict
    /// as "%@ covers your weekly capacity" with no overpay/underpay).
    private var currentPlanID: String? {
        guard let raw = UserDefaults.standard.string(forKey: "throttle.calibration.plan") else { return nil }
        switch raw.lowercased() {
        case "pro":      return "pro"
        case "max5x", "max5":  return "max5x"
        case "max20x", "max20": return "max20x"
        default:         return nil
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
            var today: Int = 0
            var yesterday: Int = 0
            var thisWeek: Int = 0
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

            do { b.today = try database.read {
                try StatsDataService.tokensBetween(in: $0, from: 0, to: 24)
            } } catch { if b.firstError == nil { b.firstError = "today: \(error)" } }

            do { b.yesterday = try database.read {
                try StatsDataService.tokensBetween(in: $0, from: 24, to: 48)
            } } catch { if b.firstError == nil { b.firstError = "yesterday: \(error)" } }

            do { b.thisWeek = try database.read {
                try StatsDataService.tokensBetween(in: $0, from: 0, to: 168)
            } } catch { if b.firstError == nil { b.firstError = "thisWeek: \(error)" } }

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
            self.todayTokens = bundle.today
            self.yesterdayTokens = bundle.yesterday
            self.thisWeekTokens = bundle.thisWeek
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

/// Line chart that doesn't use SwiftUI's Canvas. macOS 26.5's RenderBox
/// fails to load Metal shaders for Canvas views inside a MenuBarExtra
/// .window — the same regression that crashed the dropdown via Sparkline.
/// We get the same visual with a plain ZStack of `Shape` views (each
/// returns a Path). Path rendering uses CALayer's CGContext, not Metal,
/// so it survives the regression.
private struct LineChart: View {
    let points: [StatsDataService.LinePoint]
    private let plotLeft: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                gridlines(size: geo.size)
                ForEach([WindowKind.session5h, .weeklyAll, .weeklySonnet], id: \.self) { kind in
                    LineSeries(
                        coords: coords(for: kind, size: geo.size),
                        color: StatsInline.color(for: kind)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func gridlines(size: CGSize) -> some View {
        let yMax = computeYMax()
        let plotHeight = size.height - 4
        ForEach([0.0, yMax / 2.0, yMax], id: \.self) { yVal in
            let yPos = plotHeight * (1 - CGFloat(yVal / yMax)) + 2
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.20))
                    .frame(width: max(0, size.width - plotLeft), height: 0.5)
                    .position(x: plotLeft + max(0, size.width - plotLeft) / 2, y: yPos)
                Text("\(Int(yVal))%")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: 14, y: yPos)
            }
        }
    }

    private func coords(for kind: WindowKind, size: CGSize) -> [CGPoint] {
        let kindPoints = points.filter { $0.kind == kind }
        guard !kindPoints.isEmpty else { return [] }
        let bounds = computeBounds()
        let yMax = computeYMax()
        let plotWidth = size.width - plotLeft
        let plotHeight = size.height - 4
        let span = max(1, bounds.1.timeIntervalSince(bounds.0))
        return kindPoints.map { p in
            let x = plotLeft + CGFloat(p.timestamp.timeIntervalSince(bounds.0) / span) * plotWidth
            let y = plotHeight * (1 - CGFloat((p.percent * 100) / yMax)) + 2
            return CGPoint(x: x, y: y)
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

/// One series in the LineChart: stroked path + small dot at each sample.
/// `Shape` impls go through Core Animation, not Metal — the macOS 26.5
/// RenderBox regression that kills Canvas doesn't affect them.
private struct LineSeries: View {
    let coords: [CGPoint]
    let color: Color

    var body: some View {
        if coords.count >= 2 {
            ZStack {
                LinePath(points: coords)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ForEach(coords.indices, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .position(x: coords[i].x, y: coords[i].y)
                }
            }
        }
    }
}

private struct LinePath: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for c in points.dropFirst() { p.addLine(to: c) }
        return p
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
