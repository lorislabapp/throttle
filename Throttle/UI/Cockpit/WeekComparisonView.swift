import SwiftUI

/// "This week vs last" strip for the Dashboard/Stats: real week-over-week deltas
/// (weighted tokens, est. EUR) plus the time-to-weekly-cap comparison and a couple
/// of honest highlights (when you burn, which project costs most). Every number is
/// read from the DB — never fabricated; a missing prior week degrades to "no prior
/// week" rather than a fake +∞%. No Charts (macOS 26.5 RenderBox guardrail): the
/// bars are hand-rolled.
struct WeekComparisonView: View {
    @Environment(AppState.self) private var appState

    @State private var wow: StatsDataService.WeekOverWeek?
    @State private var peak: StatsDataService.HeatCell?
    @State private var topProject: (name: String, tokens: Int)?

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THIS WEEK vs LAST")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(.secondary)

            if let w = wow {
                HStack(spacing: 10) {
                    deltaTile("Weighted tokens", value: fmtTok(w.tokensThis),
                              delta: pctDelta(w.tokensThis, w.tokensLast), lowerIsBetter: true)
                    deltaTile("Est. cost", value: String(format: "€%.2f", w.costThis),
                              delta: pctDelta(Int(w.costThis * 100), Int(w.costLast * 100)), lowerIsBetter: true)
                    capTile(w)
                }
                highlights
            } else {
                Text("Not enough history yet — a week of usage fills this in.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hair, lineWidth: 1))
        .task { await load() }
    }

    // MARK: tiles

    private func deltaTile(_ title: String, value: String, delta: Delta, lowerIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 19, weight: .semibold, design: .monospaced))
            deltaLabel(delta, lowerIsBetter: lowerIsBetter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }

    private func capTile(_ w: StatsDataService.WeekOverWeek) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Time to weekly cap").font(.system(size: 10)).foregroundStyle(.tertiary)
            if let s = w.capReachSecondsThis {
                Text(fmtDur(s)).font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                capComparison(this: s, last: w.capReachSecondsLast)
            } else {
                Text("not reached").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.green)
                Text(w.capReachSecondsLast == nil ? "nor last week" : "vs \(fmtDur(w.capReachSecondsLast!)) last week")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }

    private func capComparison(this: Int64, last: Int64?) -> some View {
        Group {
            if let last {
                // Longer before hitting the cap = better (more runway), so a later
                // hit this week is the good direction.
                let faster = this < last
                Label(faster ? "\(fmtDur(last - this)) sooner" : "\(fmtDur(this - last)) later",
                      systemImage: faster ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(faster ? .orange : Color.green)
            } else {
                Text("didn't reach it last week").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var highlights: some View {
        HStack(spacing: 10) {
            if let p = peak {
                highlightTile("Peak", "\(dayName(p.dayOfWeek)) · \(hourLabel(p.hour))", "clock")
            }
            if let t = topProject {
                highlightTile("Heaviest project", "\(t.name) · \(fmtTok(t.tokens))", "folder")
            }
        }
    }

    private func highlightTile(_ title: String, _ value: String, _ glyph: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: glyph).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: delta model

    private enum Delta { case up(Int), down(Int), flat, newThisWeek, none }

    private func pctDelta(_ this: Int, _ last: Int) -> Delta {
        guard last > 0 else { return this > 0 ? .newThisWeek : .none }
        let pct = Int(((Double(this) - Double(last)) / Double(last) * 100).rounded())
        if pct == 0 { return .flat }
        return pct > 0 ? .up(pct) : .down(-pct)
    }

    @ViewBuilder private func deltaLabel(_ d: Delta, lowerIsBetter: Bool) -> some View {
        switch d {
        case .up(let p):
            Label("\(p)% vs last", systemImage: "arrow.up")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(lowerIsBetter ? .orange : Color.green)
        case .down(let p):
            Label("\(p)% vs last", systemImage: "arrow.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(lowerIsBetter ? Color.green : .orange)
        case .flat:
            Text("same as last").font(.system(size: 10)).foregroundStyle(.secondary)
        case .newThisWeek:
            Text("new this week").font(.system(size: 10)).foregroundStyle(.secondary)
        case .none:
            Text("no prior week").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: load

    private func load() async {
        let db = appState.database
        let result = try? await Task.detached(priority: .utility) {
            let wow = try? await db.read { try StatsDataService.weekOverWeek(in: $0) }
            let peak = try? await db.read { try StatsDataService.peakSlot(in: $0, range: .last7d) }
            let top = try? await db.read { try StatsDataService.topProjects(in: $0, range: .last7d, limit: 1).first }
            let topPair: (String, Int)? = top.map { ($0.projectName, $0.weightedTokens) }
            return (wow, peak, topPair)
        }.value
        await MainActor.run {
            wow = result?.0 ?? nil
            peak = result?.1 ?? nil
            if let t = result?.2 { topProject = (name: t.0, tokens: t.1) }
        }
    }

    // MARK: format

    private func fmtTok(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    private func fmtDur(_ seconds: Int64) -> String {
        let d = Double(seconds) / 86_400
        if d >= 1 { return String(format: "%.1fd", d) }
        return String(format: "%.0fh", Double(seconds) / 3600)
    }
    private func dayName(_ dow: Int) -> String {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return (1...7).contains(dow) ? names[dow] : "?"
    }
    private func hourLabel(_ h: Int) -> String {
        let hr = h % 12 == 0 ? 12 : h % 12
        return "\(hr)\(h < 12 ? "am" : "pm")"
    }
}
