import SwiftUI

/// Eval-ROI readout — measure-only, per project. Folds the test-run outcomes
/// Throttle sniffed from the terminal (`TestOutcomeStore`) into a green/red /
/// pass-rate signal, shifting the panel from "how many tokens" toward "how many
/// tokens per working outcome". No interception, no rewrite — it only reads a local
/// log of pass/fail counts. Hidden until there's at least one detected run.
struct EvalReadout: View {
    let project: ProjectInfo

    @State private var s = TestOutcomeStore.Summary()
    private var hair: Color { Color.primary.opacity(0.09) }

    var body: some View {
        Group {
            if s.hasData {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("TEST OUTCOMES")
                            .font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Text("measure-only · last 14d")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        if let fw = s.lastFramework {
                            Text(fw).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 18) {
                        cell("\(Int((s.passRate * 100).rounded()))%", "pass rate")
                        cell("\(s.green)", "green runs")
                        cell("\(s.red)", "red runs")
                        if let e = s.eurPerGreen, e > 0 {
                            cell(String(format: "€%.2f", e), "≈ / green run")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(hair).frame(height: 1)
            }
        }
        .task(id: project.encodedName) {
            let enc = project.encodedName
            s = await Task.detached(priority: .utility) { TestOutcomeStore.summary(project: enc) }.value
        }
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
        }
    }
}
