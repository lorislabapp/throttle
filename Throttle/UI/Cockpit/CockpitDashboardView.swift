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

    private let hair = Color.primary.opacity(0.10)

    struct DashData: Equatable {
        var cap5h: Double = 0, cap7d: Double = 0
        var costEUR: Double = 0, rmcEUR: Double = 0
        var activeWeekHours: Double = 0
        var projects: [Proj] = []          // top by active time this week
        var spark: [Double] = []           // daily active seconds, last 7d
        struct Proj: Equatable, Identifiable { let id = UUID(); let name: String; let hours: Double }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                OSIssueBanner()
                claudePanel
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
            let wa = (try? await db.read { try StatsDataService.workActivity(in: $0) }) ?? .init()
            let projects = wa.topProjects.prefix(5).map { DashData.Proj(name: $0.name, hours: $0.seconds / 3600) }
            let spark = wa.daily.map { $0.seconds }
            await MainActor.run {
                data.costEUR = cost; data.rmcEUR = rmc
                data.activeWeekHours = wa.activeWeek / 3600
                data.projects = Array(projects); data.spark = spark
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
