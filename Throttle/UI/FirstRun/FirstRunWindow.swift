import GRDB
import SwiftUI

struct FirstRunWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var step: FirstRunStep = .introduction
    @State private var planChoice: PlanChoice = .skip
    @State private var enableLoginItems: Bool = false

    enum PlanChoice: String, CaseIterable, Identifiable {
        case pro = "Pro"
        case max5x = "Max 5×"
        case max20x = "Max 20×"
        case skip = "Skip — calibrate from usage"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 32)
                .padding(.top, 32)
            Spacer()
            footer
        }
        .frame(width: 520, height: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .introduction:
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to Throttle")
                    .font(.largeTitle).bold()
                Text("Throttle reads your Claude Code session files at `~/.claude/projects/` to compute your usage. Nothing leaves your Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("The free meter shows your 5-hour and weekly windows in your menu bar. Pro features (optimizer + hooks) are sold separately.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .calibration:
            VStack(alignment: .leading, spacing: 16) {
                Text("Which plan are you on?")
                    .font(.title2).bold()
                Text("This pre-fills your usage caps. Throttle also auto-calibrates over time — you can skip this.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Plan", selection: $planChoice) {
                    ForEach(PlanChoice.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        case .loginItems:
            VStack(alignment: .leading, spacing: 16) {
                Text("Start Throttle with macOS?")
                    .font(.title2).bold()
                Text("Most users want Throttle to run automatically. You can change this anytime in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Launch Throttle at login", isOn: $enableLoginItems)
                    .padding(.top, 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            // Cancel is always available since the window has no title-bar close button
            // (hidden-titlebar style — see ThrottleApp.swift).
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            if let prev = step.previous {
                Button("Back") { step = prev }
            }

            Spacer()

            Text("Step \(step.rawValue + 1) of \(FirstRunStep.allCases.count)")
                .foregroundStyle(.secondary)
                .font(.caption)

            Spacer()

            Button(step.next == nil ? "Get Started" : "Continue") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        // Removed `.background(.bar)` — Material backgrounds inside hidden-titlebar
        // windows on macOS 26 can re-trigger the same NSTitlebarBackgroundView
        // pocket-view path that was crashing. Plain background keeps it stable.
    }

    private func advance() {
        if let next = step.next {
            step = next
        } else {
            apply()
        }
    }

    private func apply() {
        // Apply login items
        if enableLoginItems {
            try? LoginItemService.setEnabled(true)
        }
        // Apply plan calibration heuristic (rough — auto-calibration adjusts over time)
        let preset: [(WindowKind, Int)]? = {
            switch planChoice {
            case .pro:    return [(.session5h, 4_000_000), (.weeklyAll, 60_000_000), (.weeklySonnet, 60_000_000)]
            case .max5x:  return [(.session5h, 8_000_000), (.weeklyAll, 200_000_000), (.weeklySonnet, 200_000_000)]
            case .max20x: return [(.session5h, 20_000_000), (.weeklyAll, 800_000_000), (.weeklySonnet, 800_000_000)]
            case .skip:   return nil
            }
        }()
        if let preset {
            // Note: we'd inject the database via AppState. For brevity here we re-open it.
            if let url = try? DatabaseManager.databaseURL(),
               let pool = try? DatabasePool(path: url.path) {
                try? pool.write { db in
                    for (kind, cap) in preset {
                        try CalibrationEngine.setManual(in: db, kind: kind, capTokens: cap)
                    }
                }
            }
        }

        appState.markFirstRunDone()
        appState.refresh()
        dismiss()
    }
}
