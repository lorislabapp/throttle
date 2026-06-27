import SwiftUI

/// Phase 1.5 readout — surfaces the accumulated *potential* TOON savings measured
/// by the tokopt hook (`toon-potential.jsonl`) so we can decide whether Phase 2
/// (Compress-Cache-Retrieve) is worth shipping with real numbers instead of guesses.
///
/// Measure-only: this is what TOON *would* save, never realized spend. Per the
/// golden rule it reads as an estimate — muted tone, `≈` prefix, an explicit
/// "potential" tag — and the whole strip hides when there's no data yet.
struct TOONPotentialReadout: View {
    @State private var p = TOONTranspiler.Potential()

    private var hair: Color { Color.primary.opacity(0.09) }

    var body: some View {
        Group {
            if p.hasData {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("TOON POTENTIAL")
                            .font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Text("measure-only · if Phase 2 ships")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Text(footnote).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 18) {
                        cell("≈\(pct)", "compressible")
                        cell("≈\(byteStr(p.savedBytes))", "saveable")
                        cell("≈\(tokenStr(p.savedTokensApprox))", "tokens")
                        cell("\(p.samples)", "tool outputs")
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(hair).frame(height: 1)
            }
        }
        .task { p = await Task.detached(priority: .utility) { TOONTranspiler.potentialSummary() }.value }
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
        }
    }

    private var pct: String { "\(Int((p.savedFraction * 100).rounded()))%" }

    private var footnote: String {
        var s = ""
        if let t = p.topTool { s += "mostly \(t)" }
        if let d = p.since {
            let days = max(1, Int(Date().timeIntervalSince(d) / 86_400))
            s += s.isEmpty ? "over \(days)d" : " · over \(days)d"
        }
        return s
    }

    private func byteStr(_ b: Int) -> String {
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1_024 { return String(format: "%.0f KB", Double(b) / 1_024) }
        return "\(b) B"
    }

    private func tokenStr(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK", Double(t) / 1_000) }
        return "\(t)"
    }
}
