import AppKit
import GRDB
import SwiftUI

// SwiftUI Charts intentionally NOT imported — its first-render Metal
// preload crashes (RB::Device::preload_resources → precondition_failure)
// in MenuBarExtra popovers on macOS 26.5 (FB16xxxxx). Hand-drawn Path /
// Rectangle visuals below render in CoreGraphics only and are safe.

/// Stats panel ("The Statement", Direction B-hybrid — see UI-SPEC-stats.md).
/// Inherits the meter's precise-cockpit language: flat sections, full-bleed
/// hairlines, graphite bars, mono digits, colour only under genuine pressure.
/// The Plan Advisor verdict is the hero; the statement table justifies it.
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

    @State private var todayTokens: Int = 0
    @State private var yesterdayTokens: Int = 0
    @State private var thisWeekTokens: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            hairline
            rangeBar
            hairline
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    advisorSection
                    hairline
                    secLabel("Usage trend · \(range.label)")
                    trendSection
                    if hasModelData {
                        hairline
                        secLabel("Model split · weighted", link: "API rates")
                        modelSplitSection
                    }
                    hairline
                    periodStrip
                    if appState.isPro {
                        hairline
                        secLabel("Activity · last 7 days")
                        heatmapSection
                        hairline
                        secLabel("Top projects", link: "All›")
                        topProjectsSection
                    } else {
                        hairline
                        proLock
                    }
                    hairline
                    statsTail
                }
            }
            .frame(minHeight: 240, maxHeight: 460)
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

    // MARK: - Cockpit scaffolding (mirrors the meter)

    private var hairColor: Color { Color.primary.opacity(0.09) }
    private var hairline: some View {
        Rectangle().fill(hairColor).frame(height: 1).padding(.horizontal, 16)
    }

    private func secLabel(_ label: String, link: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let link {
                Text(link)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13).padding(.bottom, 1)
    }

    private var estTag: some View {
        Text("estimate")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    // MARK: - Title + range

    private var titleRow: some View {
        HStack(spacing: 9) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            Text("Stats").font(.system(size: 14.5, weight: .semibold))
            Spacer(minLength: 0)
            if appState.isPro { pillSoft("PRO") } else { pillOutline("FREE") }
            if appState.exactSnapshot?.isFresh() == true {
                HStack(spacing: 4) {
                    Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 4, height: 4)
                    Text("EXACT")
                }
                .font(.system(size: 9.5, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 12)
    }

    private func pillSoft(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.secondary)
    }
    private func pillOutline(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(.tertiary)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var rangeBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 1) {
                ForEach(StatsDataService.Range.allCases, id: \.self) { r in
                    Button { range = r } label: {
                        Text(r.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(range == r ? Color.primary : Color.secondary)
                            .padding(.horizontal, 13)
                            .frame(minHeight: 26)
                            .background(
                                range == r
                                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                                : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 0)
            Text("local").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: - Advisor (verdict hero + statement)

    /// Whether figures should read as estimates — same rule as the meter:
    /// exact mode is on but the latest poll isn't fresh. Pure-local users
    /// (exact never enabled) are NOT flagged; local token data is real truth.
    private var est: Bool {
        appState.exactModeEnabled && !(appState.exactSnapshot?.isFresh() ?? false)
    }

    private var weeklyTokens: Int {
        switch range {
        case .last24h: return totalTokens * 7
        case .last7d:  return totalTokens
        case .last30d: return totalTokens * 7 / 30
        case .all:     return 0
        }
    }

    private var verdict: PlanAdvisor.Verdict? {
        guard weeklyTokens > 0, range != .all else { return nil }
        return PlanAdvisor.recommend(
            weeklyWeightedTokens: weeklyTokens,
            opusFraction: computeOpusFraction(),
            currentPlanID: currentPlanID,
            dailyVarianceCoeff: 0
        )
    }

    private var ladderRows: [PlanAdvisor.LadderRow] {
        guard let v = verdict else { return [] }
        return PlanAdvisor.ladder(weeklyTokens: weeklyTokens, currentPlanID: currentPlanID, bestPlanID: v.bestPlanID)
    }

    @ViewBuilder
    private var advisorSection: some View {
        if let v = verdict {
            verdictHero(v)
            secLabel("Plan statement · vs API")
            statementTable(v)
            reasoningLine
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 13)
        } else {
            advisorEmpty
        }
    }

    @ViewBuilder
    private func verdictHero(_ v: PlanAdvisor.Verdict) -> some View {
        let savings = max(0, v.apiEquivalentMonthlyEUR - v.bestPlanMonthlyEUR)
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan advisor · recommendation")
                .font(.system(size: 10, weight: .semibold)).tracking(0.9)
                .textCase(.uppercase).foregroundStyle(.tertiary)
                .padding(.bottom, 9)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(planShortName(v.bestPlanID))
                    .font(.system(size: 21, weight: .semibold)).tracking(-0.4)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if est {
                        Text(verbatim: "≈").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Text(eur(v.bestPlanMonthlyEUR))
                        .font(.system(size: 20, weight: .medium).monospacedDigit())
                    Text(verbatim: "/mo").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                (Text(verbatim: "— ").foregroundStyle(.secondary)
                 + Text("best for your usage").foregroundStyle(.primary).fontWeight(.semibold))
                    .font(.system(size: 12.5))
                if savings > 0 {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    (Text("saves ").foregroundStyle(.secondary)
                     + Text("\(est ? "≈" : "")\(eur(savings))").foregroundStyle(.primary)
                     + Text("/mo vs API").foregroundStyle(.secondary))
                        .font(.system(size: 12.5))
                }
                if est { estTag }
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 14)
    }

    @ViewBuilder
    private func statementTable(_ v: PlanAdvisor.Verdict) -> some View {
        VStack(spacing: 0) {
            // header
            HStack(spacing: 10) {
                Text("Plan").frame(maxWidth: .infinity, alignment: .leading)
                Text("€/mo").frame(width: 54, alignment: .trailing)
                Text("fit to your burn").frame(width: 104, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
            .textCase(.uppercase).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 7)

            ForEach(ladderRows) { row in
                statementRow(row)
            }
            apiRow(v)
        }
        .padding(.top, 1)
    }

    @ViewBuilder
    private func statementRow(_ row: PlanAdvisor.LadderRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(planShortName(row.id))
                    .font(.system(size: 12.5, weight: .medium))
                if row.isCurrent {
                    Text("NOW").font(.system(size: 8, weight: .bold)).tracking(0.5)
                        .foregroundStyle(.tertiary)
                }
                if row.isBest {
                    Text("BEST").font(.system(size: 8, weight: .bold)).tracking(0.5)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(eur(row.monthlyEUR))
                .font(.system(size: 13).monospacedDigit())
                .frame(width: 54, alignment: .trailing)
            Text(row.fit.label)
                .font(.system(size: 11))
                .foregroundStyle(row.isBest ? Color.primary : Color.secondary)
                .fontWeight(row.isBest ? .medium : .regular)
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(row.isBest ? Color.primary.opacity(0.05) : Color.clear)
        .overlay(alignment: .leading) {
            if row.isBest { Rectangle().fill(Color.primary).frame(width: 2) }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(hairColor).frame(height: 1)
        }
    }

    @ViewBuilder
    private func apiRow(_ v: PlanAdvisor.Verdict) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("API equivalent").font(.system(size: 12.5, weight: .medium))
                Text("UPPER BOUND").font(.system(size: 8, weight: .bold)).tracking(0.5)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(est ? "≈" : "")\(eur(v.apiEquivalentMonthlyEUR))")
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text("pay per token").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
        }
    }

    private var reasoningLine: some View {
        let opusPct = Int((computeOpusFraction() * 100).rounded())
        let heavy = computeOpusFraction() >= 0.5
            ? "Opus-heavy (\(opusPct)%)"
            : "Sonnet-heavy (\(100 - opusPct)%)"
        return Text("You burn \(est ? "≈" : "")\(formatTokens(weeklyTokens)) weighted tokens/wk, \(heavy).")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help("Weekly projection from the selected range — not last-7-days actuals. A busy 24h can project higher than a quiet 30-day span; that's the rate, not a bug.")
    }

    private var advisorEmpty: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 20)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Need more usage to advise")
                    .font(.system(size: 13, weight: .medium))
                Text("Keep using Claude Code in this range — the advisor needs a bit more history before it can size a plan.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 17)
    }

    private func planShortName(_ id: String) -> String {
        switch id {
        case "free":   return String(localized: "Free")
        case "pro":    return String(localized: "Pro")
        case "max5x":  return "Max 5×"
        case "max20x": return "Max 20×"
        default:       return id
        }
    }

    /// Compact whole-euro string ("€90") — matches the design and stays
    /// deterministic across locales (NumberFormatter would yield "90 €" in FR).
    private func eur(_ amount: Double) -> String { "€\(Int(amount.rounded()))" }

    // MARK: - Advisor inputs

    private var totalTokens: Int {
        modelSlices.reduce(0) { $0 + $1.weightedTokens }
    }

    private func computeOpusFraction() -> Double {
        let total = totalTokens
        guard total > 0 else { return 0.30 }
        let opus = modelSlices.filter { $0.tier == .opus }.reduce(0) { $0 + $1.weightedTokens }
        return Double(opus) / Double(total)
    }

    private var currentPlanID: String? {
        guard let raw = UserDefaults.standard.string(forKey: "throttle.calibration.plan") else { return nil }
        switch raw.lowercased() {
        case "pro":             return "pro"
        case "max5x", "max5":   return "max5x"
        case "max20x", "max20": return "max20x"
        default:                return nil
        }
    }

    // MARK: - Trend

    @ViewBuilder
    private var trendSection: some View {
        if linePoints.isEmpty {
            Text("No history yet — keep using Claude Code; the chart fills as you go.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                LineChart(points: linePoints).frame(height: 64)
                HStack(spacing: 16) {
                    legendItem(dash: [], opacity: 0.6, label: "Session 5h")
                    legendItem(dash: [4, 3], opacity: 0.42, label: "Weekly all")
                    legendItem(dash: [1.5, 3], opacity: 0.3, label: "Weekly Sonnet")
                    if est { estTag }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        }
    }

    private func legendItem(dash: [CGFloat], opacity: Double, label: String) -> some View {
        HStack(spacing: 6) {
            LegendSwatch(dash: dash, opacity: opacity)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Model split

    private var hasModelData: Bool {
        !(modelSlices.isEmpty || modelSlices.allSatisfy { $0.weightedTokens == 0 })
    }

    private var modelSplitSection: some View {
        let total = max(1, totalTokens)
        return VStack(alignment: .leading, spacing: 11) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(modelSlices) { slice in
                        let w = geo.size.width * (Double(slice.weightedTokens) / Double(total))
                        modelColor(slice.tier).frame(width: max(0, w))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(Color.primary.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(alignment: .top, spacing: 8) {
                ForEach(modelSlices) { slice in
                    let pct = Int((Double(slice.weightedTokens) / Double(total) * 100).rounded())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(modelColor(slice.tier)).frame(width: 8, height: 8)
                            Text(tierLabel(slice.tier)).font(.system(size: 11, weight: .medium))
                        }
                        Text("\(est ? "≈" : "")\(pct)%").font(.system(size: 14).monospacedDigit())
                        Text("≈\(eur(tierMonthlyEUR(slice)))/mo API")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
    }

    private func tierMonthlyEUR(_ slice: StatsDataService.ModelSlice) -> Double {
        let rate: Double
        switch slice.tier {
        case .opus:   rate = PlanAdvisor.opus47.weightedPerM
        case .sonnet: rate = PlanAdvisor.sonnet46.weightedPerM
        case .haiku:  rate = PlanAdvisor.haiku45.weightedPerM
        case .other:  rate = PlanAdvisor.sonnet46.weightedPerM
        }
        let share = Double(slice.weightedTokens) / Double(max(1, totalTokens))
        let monthlyTokens = Double(weeklyTokens) * share * 4.33
        return monthlyTokens / 1_000_000 * rate
    }

    private func modelColor(_ tier: ModelTier) -> Color {
        switch tier {
        case .opus:   return Color.primary.opacity(0.72)
        case .sonnet: return Color.primary.opacity(0.42)
        case .haiku:  return Color.primary.opacity(0.20)
        case .other:  return Color.primary.opacity(0.12)
        }
    }

    // MARK: - Period strip

    private var periodStrip: some View {
        let savedEUR = Double(max(savedTokens, appState.savedTokensThisWeek)) / 1_000_000 * 6.00
        return HStack(spacing: 0) {
            periodCell("Today", "\(est ? "≈" : "")\(formatTokens(todayTokens))", muted: false, leading: false)
            periodCell("This week", "\(est ? "≈" : "")\(formatTokens(thisWeekTokens))", muted: false, leading: true)
            periodCell("Saved", "≈\(eur(savedEUR))", muted: true, leading: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func periodCell(_ key: String, _ value: String, muted: Bool, leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                .textCase(.uppercase).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 16).monospacedDigit())
                .foregroundStyle(muted ? Color.secondary : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, leading ? 14 : 0)
        .overlay(alignment: .leading) {
            if leading { Rectangle().fill(hairColor).frame(width: 1) }
        }
    }

    // MARK: - Pro extras

    private var heatmapSection: some View {
        HeatmapGrid(cells: heatCells)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
    }

    private var topProjectsSection: some View {
        let maxTok = max(1, topProjects.map(\.weightedTokens).max() ?? 1)
        return VStack(spacing: 0) {
            ForEach(Array(topProjects.enumerated()), id: \.element.id) { idx, p in
                if idx > 0 { Rectangle().fill(hairColor).frame(height: 1) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(p.projectName).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Text(formatTokens(p.weightedTokens))
                            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.09))
                            Capsule().fill(Color.primary.opacity(0.45))
                                .frame(width: max(4, geo.size.width * Double(p.weightedTokens) / Double(maxTok)))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.vertical, 7)
            }
            if topProjects.isEmpty {
                Text("No project data yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private var proLock: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 16)).foregroundStyle(.tertiary)
            Text("Activity heatmap & top projects")
                .font(.system(size: 13, weight: .medium))
            Text("See where your tokens go, hour by hour and project by project.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: "https://lorislab.fr/throttle/buy") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Upgrade to Pro")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Tail

    private var statsTail: some View {
        VStack(spacing: 0) {
            Button {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open claude.ai/usage")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 13)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).frame(height: 32)

            Rectangle().fill(hairColor).frame(height: 1).padding(.horizontal, 16)

            HStack(spacing: 14) {
                Button { shareBadge() } label: { Text("Share badge").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button { onBack() } label: { Text("Back").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }

    // MARK: - Share badge

    private var shareBadgeTopStat: String {
        let saved = max(savedTokens, appState.savedTokensThisWeek)
        if saved > 0 { return "\(formatTokens(saved)) tokens saved" }
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
        if saved > 0 { return "this week with Throttle's open-source token-opt hooks" }
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
}

// MARK: - Trend legend swatch

private struct LegendSwatch: View {
    let dash: [CGFloat]
    let opacity: Double
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 1))
            p.addLine(to: CGPoint(x: 14, y: 1))
        }
        .stroke(Color.primary.opacity(opacity), style: StrokeStyle(lineWidth: 1.5, dash: dash))
        .frame(width: 14, height: 2)
    }
}

// MARK: - Line chart (CoreGraphics, no Metal)

/// Line chart that doesn't use SwiftUI's Canvas. macOS 26.5's RenderBox
/// fails to load Metal shaders for Canvas views inside a MenuBarExtra
/// .window. Plain `Shape` views (Path) render via CALayer's CGContext.
/// Three neutral-graphite series — session solid, weekly dashed, sonnet dotted.
private struct LineChart: View {
    let points: [StatsDataService.LinePoint]
    private let plotLeft: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                gridlines(size: geo.size)
                LineSeries(coords: coords(for: .weeklySonnet, size: geo.size), opacity: 0.30, dash: [1.5, 3])
                LineSeries(coords: coords(for: .weeklyAll, size: geo.size), opacity: 0.42, dash: [4, 3])
                LineSeries(coords: coords(for: .session5h, size: geo.size), opacity: 0.60, dash: [])
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
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: max(0, size.width - plotLeft), height: 0.5)
                    .position(x: plotLeft + max(0, size.width - plotLeft) / 2, y: yPos)
                Text("\(Int(yVal))%")
                    .font(.system(size: 9, weight: .regular).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .position(x: 13, y: yPos)
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

/// One series: a stroked Path with a dash pattern. No per-sample dots — the
/// cockpit trend is thin lines only. `Shape` goes through Core Animation, not
/// Metal, so the macOS 26.5 RenderBox regression doesn't affect it.
private struct LineSeries: View {
    let coords: [CGPoint]
    let opacity: Double
    let dash: [CGFloat]

    var body: some View {
        if coords.count >= 2 {
            LinePath(points: coords)
                .stroke(
                    Color.primary.opacity(opacity),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dash)
                )
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

/// 7 days × 24 hours of weighted-token intensity, graphite (ink-opacity) cells.
/// RoundedRectangles only — no Metal/Canvas.
private struct HeatmapGrid: View {
    let cells: [StatsDataService.HeatCell]
    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    private var maxValue: Int { max(1, cells.map(\.weightedTokens).max() ?? 1) }

    private var lookup: [Int: [Int: Int]] {
        var out: [Int: [Int: Int]] = [:]
        for c in cells { out[c.dayOfWeek, default: [:]][c.hour] = c.weightedTokens }
        return out
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(1...7, id: \.self) { dow in
                HStack(spacing: 6) {
                    Text(dayLabels[dow - 1])
                        .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        .frame(width: 12, alignment: .trailing)
                    HStack(spacing: 2) {
                        ForEach(0..<24, id: \.self) { hour in
                            let value = lookup[dow]?[hour] ?? 0
                            let intensity = Double(value) / Double(maxValue)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.primary.opacity(intensity > 0.06 ? 0.05 + 0.62 * intensity : 0.05))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            HStack {
                Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p"); Spacer(); Text("11p")
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            .padding(.leading, 18)
        }
    }
}

// MARK: - Share badge

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
