import SwiftUI

/// Cockpit "Dashboard" — the Overview cover page. Instrument-cluster layout: the
/// hero is Claude (the moat — caps, spend, time, projects); the machine is a
/// graphite context panel (CPU per-core, memory/swap, disk, network). Doctrine:
/// the cap gauges may earn orange/red (that IS cap pressure); the machine is
/// always graphite — colour is reserved for the cap, never hardware.
struct CockpitDashboardView: View {
    @Environment(AppState.self) private var appState
    let machine: MemoryHealth

    @State private var data = DashData()
    @State private var host = HostMetricsService.shared
    @State private var sampler: Task<Void, Never>?
    @State private var localRuntimes: [String] = []
    // LOCAL MIX (frontier ↔ local, measured on this Mac)
    @State private var localModelInstalled = false
    @State private var replayLedger = ShadowReplayService.Ledger.empty
    @State private var showAdjudication = false
    @State private var benchProfile: LocalModelBenchService.Profile?
    @State private var replayBusy = false
    @State private var benchBusy = false
    @State private var localMixNote: String?

    private let hair = Color.primary.opacity(0.10)

    struct DashData: Equatable {
        var cap5h: Double = 0, cap7d: Double = 0
        var costEUR: Double = 0, rmcEUR: Double = 0
    var cacheEff: Double?   // prompt-cache hit rate 0…1 (plan-yield score)
        var activeWeekHours: Double = 0
        var projects: [Proj] = []          // top by active time this week
        var spark: [Double] = []           // daily active seconds, last 7d
        struct Proj: Equatable, Identifiable { let id = UUID(); let name: String; let hours: Double }
        // True price-adjusted model mix: (tier label, share 0…1). Opus's share here
        // reflects its 5× price, unlike the equal-token modelSplit elsewhere.
        var modelMix: [ModelBar] = []
        var opusShare: Double = 0
        var sonnetSaving: Double = 0       // est. total-bill fraction if half of Opus → Sonnet
        struct ModelBar: Equatable, Identifiable { let id = UUID(); let label: String; let share: Double; let isOpus: Bool }
        // Retro-attribution (advisory): completed sessions whose shape a local
        // 3–4B serves credibly. A profile match, never a "would have worked".
        var localCandidateCount: Int = 0
        var localScannedSessions: Int = 0
        var localAvoidableEUR: Double = 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                OSIssueBanner()
                claudePanel
                if !data.modelMix.isEmpty { modelMixPanel }
                if localModelInstalled || replayLedger.replayed > 0 { localMixPanel }
                WeekComparisonView()
                machinePanel
                SavingsLedgerView()
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hair, lineWidth: 1))
                if !localRuntimes.isEmpty {
                    Text("Figures cover Anthropic usage only — \(localRuntimes.joined(separator: " · ")) runs locally and isn't tracked here.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onAppear { load(); startSampling() }
        .onDisappear { sampler?.cancel(); sampler = nil }
    }

    // MARK: - CLAUDE (hero)

    private var claudePanel: some View {
        panel("CLAUDE") {
            HStack(alignment: .top, spacing: 24) {
                gauge("5-HOUR", data.cap5h)
                gauge("7-DAY", data.cap7d)
                VStack(alignment: .leading, spacing: 7) {
                    stat("spend", String(format: "€%.2f", data.costEUR), "/ 7d")
                    // The plan-yield number: Anthropic ties cache hit rate to how
                    // far plan rate-limits stretch. <60% = plan burning hot.
                    if let eff = data.cacheEff {
                        stat("cache eff", String(format: "%.0f%%", eff * 100), "/ 7d",
                             warn: eff < 0.6)
                    }
                    if data.rmcEUR >= 0.01 {
                        stat("cache waste", String(format: "≈€%.2f", data.rmcEUR), "recoverable", warn: true)
                    }
                    stat("active", String(format: "%.0fh", data.activeWeekHours), "/ 7d")
                }
                Spacer(minLength: 0)
            }
            if !data.spark.isEmpty {
                DashSparkline(values: data.spark).frame(height: 26).padding(.top, 4)
            }
            if !data.projects.isEmpty {
                Divider().overlay(hair).padding(.vertical, 2)
                ForEach(data.projects) { p in projectRow(p) }
            }
        }
    }

    private func projectRow(_ p: DashData.Proj) -> some View {
        let maxH = max(0.1, data.projects.map(\.hours).max() ?? 1)
        return HStack(spacing: 8) {
            Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(hair)
                    Capsule().fill(Color.accentColor.opacity(0.55))
                        .frame(width: geo.size.width * (p.hours / maxH))
                }
            }.frame(height: 5)
            Text(String(format: "%.1fh", p.hours)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: - MODEL MIX (the real cost lever)

    /// Where the plan actually goes, priced honestly. Unlike the token-count split,
    /// this weights each model by its real price (Opus 1.67× Sonnet), so a user running
    /// Opus for everything sees the truth: it's the dominant line, and moving routine
    /// work to Sonnet is a far bigger lever than trimming output.
    private var modelMixPanel: some View {
        panel("MODEL MIX · 7d") {
            let colorFor: (DashData.ModelBar) -> Color = { $0.isOpus ? .orange : ($0.label == "sonnet" ? .accentColor : .secondary) }
            VStack(spacing: 6) {
                ForEach(data.modelMix) { bar in
                    HStack(spacing: 8) {
                        Text(bar.label.capitalized).font(.system(size: 11, weight: .medium))
                            .frame(width: 64, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(hair)
                                Capsule().fill(colorFor(bar).opacity(0.6))
                                    .frame(width: geo.size.width * max(0.01, bar.share))
                            }
                        }.frame(height: 6)
                        Text(String(format: "%.0f%%", bar.share * 100))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            // The honest nudge — a what-if, not a claim. Only worth showing when Opus
            // dominates AND the estimated saving is material.
            if data.opusShare >= 0.6 && data.sonnetSaving >= 0.05 {
                Text("Opus is \(Int(data.opusShare * 100))% of your cost — it bills the same context at 1.7× Sonnet. Starting routine work (edits, builds, greps) in a Sonnet session could cut ≈\(Int(data.sonnetSaving * 100))% of your plan usage. Switch at a new session, not mid-task (per-model caches).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            // Retro-attribution nudge — a profile observation, not a promise. Only
            // shown when there is something to route AND the money is non-trivial.
            if data.localCandidateCount > 0 && data.localAvoidableEUR >= 0.05 {
                Text("\(data.localCandidateCount) of your last \(data.localScannedSessions) sessions had a bounded, local-safe profile (≤\(LocalCandidateService.maxTurns) turns, small context, small output) — ≈€\(String(format: "%.2f", data.localAvoidableEUR)) est of frontier spend. Quick asks like these are what a Local session is for.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - LOCAL MIX (frontier ↔ local, measured on this Mac)

    /// The measured half of the local-candidate nudge. Shadow replay re-runs
    /// completed local-safe sessions on the embedded model and validates the
    /// Distance to a defensible claim, stated in cases rather than adjectives.
    /// 299 frozen cases with zero false `verified` are what puts the 95% bound
    /// under 1% — below that the honest phrasing is the bound itself, never
    /// "proven".
    @ViewBuilder private var certificationProgress: some View {
        let target = ShadowReplayService.Ledger.casesNeeded(forBound: 0.01)
        let done = replayLedger.certifiedVerifiedClaims
        if let bound = replayLedger.falseVerifiedBound95 {
            Text("0 false verified over \(done) adjudicated certification cases — false-verified rate ≤\(String(format: "%.1f", bound * 100))% (95% bound, est). \(max(0, target - done)) more to claim under 1%.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if replayLedger.falseVerified > 0 {
            Text("\(replayLedger.falseVerified) false verified out of \(done) adjudicated — measured, not bounded. Fix the pipeline before certifying.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Certification: \(done)/\(target) adjudicated cases. Until a human checks these verdicts against the source, none of them bounds how often \"verified\" is wrong.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// result through the delegation contract — building the golden set that
    /// turns "local-safe profile" into evidence. Never touches a real session.
    private var localMixPanel: some View {
        panel("LOCAL MIX") {
            if replayLedger.replayed > 0 {
                HStack(spacing: 14) {
                    kv("REPLAYED", "\(replayLedger.replayed)")
                    kv("VERIFIED", "\(replayLedger.verified)")
                    kv("REVIEW", "\(replayLedger.review)")
                    kv("FAILED", "\(replayLedger.hardFailures)")
                }
                if let bound = replayLedger.hardFailureBound95 {
                    Text("0 hard failures over \(replayLedger.replayed) replays — hard-failure rate ≤\(String(format: "%.0f", bound * 100))% (95% bound, est). Review items still need a human A/B before any claim.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The hard-failure bound above covers the cases the pipeline
                // correctly REFUSED. The risk worth bounding is the opposite: a
                // `verified` that a human would have overturned. That needs
                // frozen, adjudicated cases, so show how far off that is rather
                // than letting the panel imply the question is already settled.
                certificationProgress
                if replayLedger.entries.contains(where: { $0.adjudicatedStatus == nil && $0.status != "error" }) {
                    Button("Adjudicate cases") { showAdjudication = true }
                        .controlSize(.small)
                }
            } else {
                Text("Shadow replay re-runs your completed local-safe sessions on \(EmbeddedModelRuntime.displayName) and validates the output — measuring, on your own data, what a local model actually serves. The real sessions are never touched.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let p = benchProfile {
                HStack(spacing: 14) {
                    kv("THIS MAC", "≈\(Int(p.estTokensPerSecond.rounded())) tok/s est")
                    kv("LOAD", String(format: "%.1fs", p.loadSeconds))
                    kv("MEASURED", p.measuredAt.formatted(.relative(presentation: .named)))
                }
            }
            if LocalWorkerRouter.configuredEndpoint != nil {
                HStack(spacing: 14) {
                    kv("SERVER", LocalWorkerRouter.serverDisplayName)
                    kv("SERVED", "\(LocalWorkerRouter.serverTaskCount)")
                    kv("EMBEDDED", "\(LocalWorkerRouter.embeddedTaskCount)")
                }
                Text("Delegated tasks prefer the server when it answers a health probe and fall back to the embedded model otherwise. Counts are per-task records of which backend actually served.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(replayBusy ? "Replaying…" : "Shadow replay") { runShadowReplay() }
                    .disabled(replayBusy || !localModelInstalled)
                Button(benchBusy ? "Measuring…" : "Benchmark this Mac") { runBench() }
                    .disabled(benchBusy || !localModelInstalled)
                if let note = localMixNote {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .controlSize(.small)
        }
        .sheet(isPresented: $showAdjudication) {
            AdjudicationSheet {
                showAdjudication = false
                replayLedger = ShadowReplayService.loadLedger()   // the bound moves as cases are judged
            }
        }
    }

    private func runShadowReplay() {
        guard !MemoryPressureMonitor.shared.isQuiet else {
            localMixNote = "Skipped — memory pressure. Try when the Mac is quiet."
            return
        }
        replayBusy = true; localMixNote = nil
        let db = appState.database
        Task {
            let prepared = await Task.detached(priority: .utility) {
                () async -> ([LocalCandidateService.Candidate], [String: String]) in
                let report = (try? await db.read { try LocalCandidateService.scan(in: $0) }) ?? .empty
                var paths: [String: String] = [:]
                for c in report.candidates {
                    if let p = try? await db.read({ try StatsDataService.cockpitSessionPath(in: $0, sessionId: c.sessionId) }) {
                        paths[c.sessionId] = p
                    }
                }
                return (report.candidates, paths)
            }.value
            let fresh = await ShadowReplayService.replayBatch(
                candidates: prepared.0, transcriptPaths: prepared.1)
            replayLedger = ShadowReplayService.loadLedger()
            localMixNote = fresh.isEmpty
                ? "No new candidates to replay."
                : "\(fresh.count) session(s) replayed."
            if MemoryPressureMonitor.shared.level != .normal {
                await EmbeddedModelRuntime.shared.unload()
            }
            replayBusy = false
        }
    }

    private func runBench() {
        guard !MemoryPressureMonitor.shared.isQuiet else {
            localMixNote = "Skipped — memory pressure. A benchmark under swap would worsen the very condition it measures."
            return
        }
        benchBusy = true; localMixNote = nil
        Task {
            do { benchProfile = try await LocalModelBenchService.run() } catch { localMixNote = "Benchmark failed: \(error.localizedDescription)" }
            benchBusy = false
        }
    }

    // MARK: - MACHINE (graphite context)

    private var machinePanel: some View {
        let s = host.snapshot
        return panel("MACHINE") {
            HStack(spacing: 8) {
                gLabel("CPU")
                PerCoreBars(values: s.perCore).frame(height: 22)
                Text("\(Int(s.cpuBusy * 100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            machineBar("MEM", used: Double(machine.usedBytes), total: Double(machine.totalBytes),
                       trail: "\(gb(machine.usedBytes)) / \(gb(machine.totalBytes))")
            HStack(spacing: 14) {
                kv("SWAP", gb(machine.swapUsedBytes))
                kv("DISK", "\(gb(UInt64(max(0, s.diskFreeBytes)))) free")
                kv("NET", String(format: "↓%@ ↑%@", rate(s.netDownBytesPerSec), rate(s.netUpBytesPerSec)))
            }
        }
    }

    private func machineBar(_ label: String, used: Double, total: Double, trail: String) -> some View {
        HStack(spacing: 8) {
            gLabel(label)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(hair)
                    Capsule().fill(Color.secondary.opacity(0.5))
                        .frame(width: total > 0 ? geo.size.width * min(1, used / total) : 0)
                }
            }.frame(height: 6)
            Text(trail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
        }
    }

    // MARK: - Bits

    private func panel(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hair, lineWidth: 1))
    }

    private func gauge(_ label: String, _ fraction: Double) -> some View {
        let f = max(0, min(1, fraction))
        let tint: Color = f >= 0.95 ? .red : (f >= 0.8 ? .orange : .accentColor)
        return VStack(spacing: 5) {
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(hair, style: .init(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * f).stroke(tint, style: .init(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(135))
                Text("\(Int(f * 100))%").font(.system(size: 18, weight: .semibold).monospacedDigit())
            }.frame(width: 72, height: 72)
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
        }
    }

    private func stat(_ label: String, _ value: String, _ suffix: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(warn ? Color.orange : .primary)
            Text(suffix).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(label).font(.system(size: 9, weight: .medium)).tracking(0.6).foregroundStyle(.tertiary)
        }.frame(width: 180)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(spacing: 5) { gLabel(k); Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
    }
    private func gLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
    }

    private func gb(_ b: UInt64) -> String { String(format: "%.1fG", Double(b) / 1_073_741_824) }
    private func rate(_ bps: Double) -> String {
        bps >= 1_048_576 ? String(format: "%.1fM", bps / 1_048_576)
            : (bps >= 1024 ? String(format: "%.0fK", bps / 1024) : "0")
    }

    // MARK: - Load + sample

    private func load() {
        localRuntimes = MultiVendorService.localRuntimes()
        localModelInstalled = EmbeddedModelRuntime.isInstalled
        replayLedger = ShadowReplayService.loadLedger()
        benchProfile = LocalModelBenchService.loadProfile()
        // Caps: prefer the server-true exact utilization, else the local estimate.
        if let ex = appState.exactSnapshot {
            data.cap5h = Double(ex.fiveHour.utilization) / 100
            data.cap7d = Double(ex.sevenDay.utilization) / 100
        } else {
            data.cap5h = appState.snapshot.session5h.percentUsed ?? 0
            data.cap7d = appState.snapshot.weeklyAll.percentUsed ?? 0
        }
        let db = appState.database
        Task.detached(priority: .utility) {
            let cost = (try? await db.read { try StatsDataService.extrapolatedCostEUR(in: $0, range: .last7d) }) ?? 0
            let rmc = (try? await db.read { try StatsDataService.recoverableMissCostEUR(in: $0).eur }) ?? 0
            let eff = (try? await db.read { try StatsDataService.cacheEfficiency(in: $0, range: .last7d) })
            let wa = (try? await db.read { try StatsDataService.workActivity(in: $0) }) ?? .init()
            let projects = wa.topProjects.prefix(5).map { DashData.Proj(name: $0.name, hours: $0.seconds / 3600) }
            let spark = wa.daily.map { $0.seconds }
            let breakdown = try? await db.read { try StatsDataService.modelCostBreakdown(in: $0, range: .last7d) }
            let bars: [DashData.ModelBar] = (breakdown?.total ?? 0) > 0
                ? breakdown!.slices.map { .init(label: $0.tier.rawValue, share: $0.cost / breakdown!.total, isOpus: $0.tier == .opus) }
                : []
            let opusShare = breakdown?.opusShare ?? 0
            let saving = breakdown?.sonnetSavingsFraction(opusMovable: 0.5) ?? 0
            let localReport = (try? await db.read { try LocalCandidateService.scan(in: $0) }) ?? .empty
            await MainActor.run {
                data.costEUR = cost; data.rmcEUR = rmc; data.cacheEff = eff
                data.activeWeekHours = wa.activeWeek / 3600
                data.projects = Array(projects); data.spark = spark
                data.modelMix = bars; data.opusShare = opusShare; data.sonnetSaving = saving
                data.localCandidateCount = localReport.candidates.count
                data.localScannedSessions = localReport.scannedSessions
                data.localAvoidableEUR = localReport.avoidableEUR
            }
        }
    }

    private func startSampling() {
        host.sample()
        sampler?.cancel()
        sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                host.sample()
            }
        }
    }
}

// MARK: - Tiny charts

/// Vertical bars, one per CPU core, height ∝ load. Graphite — machine context.
private struct PerCoreBars: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let n = max(values.count, 1)
            let w = geo.size.width / CGFloat(n)
            HStack(alignment: .bottom, spacing: max(1, w * 0.18)) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(height: max(2, geo.size.height * CGFloat(max(0, min(1, v)))))
                }
            }.frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// A flat polyline sparkline (accent), normalized to its own range.
private struct DashSparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let span = max(hi - lo, 0.0001)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = values.count <= 1 ? 0 : geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                    i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                }
            }.stroke(Color.accentColor.opacity(0.7), style: .init(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
