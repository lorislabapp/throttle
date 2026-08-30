import SwiftUI

/// The Plan segment: a project's task tree on the left, the selected task's log on
/// the right.
///
/// Read-only on purpose. The plan's authority is the log an agent wrote, so the UI
/// shows what happened rather than offering a second, conflicting way to say it.
struct PlanTreeView: View {

    let model: PlanModel
    /// The cockpit opens the session; this view only asks for it. Keeps the
    /// "advisory, never automatic" rule visible in the type signature.
    var onLaunch: ((TaskLauncher.LaunchPlan) -> Void)?

    @State private var launchError: String?

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Rectangle().fill(hair).frame(height: 1)
                tree
            }
            .frame(minWidth: 340)

            inspector
                .frame(minWidth: 260)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.plan?.title.uppercased() ?? "PLAN")
                .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if model.hasPlan {
                Text("\(model.overallPct)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - Tree

    @ViewBuilder
    private var tree: some View {
        if let error = model.loadError {
            message("This project's plan could not be read.", detail: error)
        } else if !model.hasPlan {
            message("No plan in this project.",
                    detail: "Throttle reads .throttle/plan.json. Nothing here yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        taskRow(row)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = row.task.id }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func taskRow(_ row: PlanModel.Row) -> some View {
        let state = model.state(row.task.id)
        let selected = model.selection == row.task.id
        return HStack(spacing: 8) {
            Circle().fill(color(state.status)).frame(width: 6, height: 6)
                .padding(.leading, CGFloat(row.depth) * 14)

            Text(row.task.title)
                .font(.system(size: 12, weight: row.depth == 0 ? .semibold : .regular))
                .lineLimit(1)

            if !state.chainValid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .help("This task's log was written outside Throttle — its hash chain does not verify.")
            }

            Spacer(minLength: 8)

            if let runtime = state.runtime {
                Text(runtime.uppercased())
                    .font(.system(size: 9, weight: .medium)).kerning(0.4)
                    .foregroundStyle(.secondary)
            }
            if state.status == .blocked, let waiting = state.blockedReason {
                Text("← \(waiting)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            progressBar(state.pct, status: state.status)
            Text("\(state.pct)%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(selected ? Color.primary.opacity(0.06) : .clear)
    }

    private func progressBar(_ pct: Int, status: TaskStatus) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color(status))
                    .frame(width: geo.size.width * CGFloat(pct) / 100)
            }
        }
        .frame(width: 56, height: 4)
    }

    private func color(_ status: TaskStatus) -> Color {
        switch status {
        case .done:                 return .green
        case .failed:               return .red
        case .running, .claimed:    return .blue
        case .review:               return .purple
        case .blocked:              return .orange
        case .pending:              return .secondary.opacity(0.5)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let id = model.selection, let task = model.plan?.task(id) {
            let state = model.state(id)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.title).font(.system(size: 13, weight: .semibold))

                    facts(task, state)

                    if !state.evidence.isEmpty {
                        section("EVIDENCE")
                        ForEach(Array(state.evidence.enumerated()), id: \.offset) { _, item in
                            Text("\(item.kind)  \(item.ref)")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    if !state.rejected.isEmpty {
                        section("REJECTED EVENTS")
                        ForEach(Array(state.rejected.enumerated()), id: \.offset) { _, item in
                            Text("seq \(item.seq)  \(item.author)  \(item.type.rawValue) — \(item.reason.rawValue)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let advice = model.advice[id] { recommendation(advice, taskID: id) }

                    section("LOG")
                    ForEach(model.events(for: id), id: \.seq) { event in
                        Text("\(event.seq)  \(event.author)  \(event.type.rawValue)"
                             + (event.pct.map { "  \($0)%" } ?? ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } else {
            message("Select a task.", detail: nil)
        }
    }

    private func facts(_ task: PlanTask, _ state: TaskState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fact("Status", state.status.rawValue)
            fact("Progress", "\(state.pct)%")
            fact("Kind", task.kind.rawValue)
            if let owner = state.owner { fact("Held by", owner) }
            if let mission = state.missionID { fact("Mission", mission) }
            if let hint = task.runtimeHint, state.owner == nil { fact("Suggested", hint) }
            if task.sotaGate { fact("Gate", "SOTA — completion parks in review") }
            if !task.dependsOn.isEmpty { fact("Depends on", task.dependsOn.joined(separator: ", ")) }
            if let summary = state.summary { fact("Summary", summary) }
            if !state.chainValid { fact("Chain", "does not verify") }
        }
    }

    // MARK: - Recommendation

    @ViewBuilder
    private func recommendation(_ advice: DispatchAdvice, taskID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            section("RECOMMENDATION")

            switch advice.verdict {
            case .runtime(let runtime):
                HStack(spacing: 6) {
                    Image(systemName: runtime.symbol).font(.system(size: 11))
                    Text(runtime.label).font(.system(size: 12, weight: .semibold))
                    Text(advice.confidence.rawValue)
                        .font(.system(size: 9, weight: .medium)).kerning(0.4)
                        .foregroundStyle(.secondary)
                }
            case .abstain:
                // Saying "I don't know" plainly is the product behaviour, not a
                // failure state — so it reads as a considered answer.
                Text("No clear choice — pick one")
                    .font(.system(size: 12, weight: .semibold))
                if let wait = advice.waitUntil {
                    Text("every runtime is out of window until "
                         + wait.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            ForEach(Array(advice.reasons.enumerated()), id: \.offset) { _, reason in
                Text("· \(reason)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The multiplier is the number that costs money, so it is stated
            // before the button, not hidden behind it.
            if let multiplier = advice.tokenMultiplier {
                Text(String(format: "≈%.0f× the tokens of a single agent", multiplier))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if let runtime = advice.runtime {
                    Button("Launch") { launch(taskID: taskID, runtime: runtime) }
                        .controlSize(.small)
                }
                Menu(advice.runtime == nil ? "Choose…" : "Change…") {
                    ForEach([AgentRuntime.claudeCode, .codex]) { runtime in
                        Button(runtime.label) { launch(taskID: taskID, runtime: runtime) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }
            .padding(.top, 2)

            if let launchError {
                Text(launchError).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func launch(taskID: String, runtime: AgentRuntime) {
        do {
            launchError = nil
            onLaunch?(try model.prepareLaunch(taskID: taskID, runtime: runtime))
        } catch let error as TaskLauncher.LaunchError {
            switch error {
            case .alreadyHeld(_, let owner): launchError = "Taken by \(owner) a moment ago."
            case .unknownTask(let id): launchError = "No task \(id) in this plan."
            }
        } catch {
            launchError = String(describing: error)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .medium)).kerning(0.3)
                .foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: 11)).textSelection(.enabled)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).kerning(0.5)
            .foregroundStyle(.secondary).padding(.top, 4)
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
