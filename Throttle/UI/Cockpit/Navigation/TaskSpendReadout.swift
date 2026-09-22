import SwiftUI

/// Both task cards and unsupported cloud measurements use the same honest label.
struct TaskSpendLabel: View {
    let entry: TaskSpend.Entry?

    var body: some View {
        Group {
            if let entry, entry.measured, let cost = entry.costEUR {
                Text(verbatim: "≈" + TaskSpend.format(cost))
                    .help(Text(
                        "API price of the tokens these sessions used. Not your subscription, and never added to it."
                    ))
            } else {
                Text("Not measured")
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("task-spend")
    }
}

struct PlanSpendReadout: View {
    let total: TaskSpend.Total

    var body: some View {
        if total.measured + total.unmeasured > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("SPENT ON THIS PLAN")
                    .font(.system(size: 10.5, weight: .semibold)).kerning(0.5).foregroundStyle(.secondary)
                if total.measured > 0 {
                    Text(verbatim: "≈" + TaskSpend.format(total.costEUR))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                } else {
                    Text("Not measured").font(.system(size: 20, weight: .semibold))
                }
                Text("\(total.measured) task(s) measured · \(total.unmeasured) not measured")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("API price of the tokens these sessions used. Not your subscription, and never added to it.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
