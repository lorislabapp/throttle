import SwiftUI

/// Records a person's decision on a plan task. Says before the write what will
/// happen to it: counted at once, or held for an agent of another family to review.
struct SettleDecisionSheet: View {
    let decision: ProjectOverview.Decision
    let projectRoot: URL
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice = ""
    @State private var rationale = ""
    @State private var attempt = HumanDecisionRecorder.Attempt()
    @State private var errorText: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settle a decision").font(.system(size: 17, weight: .semibold))
                Text(verbatim: decision.title).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Your choice").font(.system(size: 12, weight: .medium))
                TextField("e.g. Keep MIT", text: $choice)
                    .textFieldStyle(.roundedBorder)
                Text("Why").font(.system(size: 12, weight: .medium))
                TextEditor(text: $rationale)
                    .font(.system(size: 13))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            }
            Text(decision.sotaGate
                 ? "This decision is marked SOTA: an agent of another model family reviews it before it counts."
                 : "Your decision counts as soon as it is recorded.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It is written to the task's log with your name and the time, and cannot be edited afterwards.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(verbatim: errorText).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Record decision") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        saving = true
        defer { saving = false }
        do {
            try HumanDecisionRecorder.record(
                .init(choice: choice, rationale: rationale), taskID: decision.id, decidedBy: NSUserName(),
                attempt: attempt, store: PlanStore(projectRoot: projectRoot)
            )
            onDone()
        } catch HumanDecisionRecorder.RecordError.notOpen {
            errorText = String(localized: "This decision is no longer open: someone or something has already taken it.")
        } catch {
            // The attempt keeps its identity, so trying again cannot write the decision twice.
            errorText = String(localized: "The decision could not be recorded: \(String(describing: error))")
        }
    }
}
