import SwiftUI

// The block that writes to the base branch, kept out of the tree view for the same
// reason as the recommendation: the part that changes the repository reads on its
// own.
//
// Nothing here shells out to git. The assessment and the diff are read into the
// model — on selection, and on opening the disclosure — because a `body` runs on
// every draw and git does not belong there.
extension PlanTreeView {

    @ViewBuilder
    func integration(_ task: PlanTask, _ state: TaskState) -> some View {
        if state.status == .integrated {
            VStack(alignment: .leading, spacing: 4) {
                section("INTEGRATED")
                Text(state.integratedSHA.map { String($0.prefix(10)) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else if state.status == .done, let assessment = model.assessment(for: task.id) {
            VStack(alignment: .leading, spacing: 6) {
                section("INTEGRATION")
                shape(assessment)
                mergeNotice(assessment)
                if let command = model.verifyCommand(for: task.id) {
                    Text("verify: \(command)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                controls(task.id, assessment)
                if let integrationError {
                    Text(integrationError).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                diffDisclosure(task.id)
            }
        } else if state.status == .done, let reason = model.assessmentError(for: task.id) {
            // A `done` task the user is looking for the button on, and there is a
            // reason there isn't one. Saying it is the whole point: the card used to
            // render as an empty space, which reads as Throttle having forgotten.
            VStack(alignment: .leading, spacing: 4) {
                section("INTEGRATION")
                Text(reason).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// What the task touched, before anything about whether it merges.
    private func shape(_ assessment: Assessment) -> some View {
        Text("\(assessment.files.count) file(s)  "
             + "+\(assessment.files.reduce(0) { $0 + $1.added })  "
             + "−\(assessment.files.reduce(0) { $0 + $1.removed })")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func mergeNotice(_ assessment: Assessment) -> some View {
        switch assessment.mergeability {
        case .clean:
            if assessment.behindBy > 0 {
                Text("\(assessment.behindBy) commit(s) behind — will rebase first")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .conflicted(let paths):
            // A quarter of agent branches land here, so it is a state with named
            // files, not an error to apologise for.
            Text("Conflicts with the base in:")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            ForEach(paths, id: \.self) { path in
                Text("· \(path)").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        case .unknown:
            // Says so without disabling the button: the sequence always rebases
            // first, and a rebase is git's own answer to the question this git
            // could not precompute.
            Text("This git cannot say whether it merges cleanly (needs 2.38).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// One button. It names the step it is on, so a verification that takes minutes
    /// reads as work rather than as a hang — and when it is disabled, the line under
    /// it says why. A disabled control with no reason is the one thing this card
    /// avoids everywhere else.
    private func controls(_ taskID: String, _ assessment: Assessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            buttons(taskID, assessment)
            if let reason = Self.blockReason(assessment) {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buttons(_ taskID: String, _ assessment: Assessment) -> some View {
        HStack(spacing: 8) {
            Button(model.integrationStep == .idle
                   ? "Integrate" : model.integrationStep.rawValue.capitalized) {
                // The previous refusal goes before the new attempt, not after it:
                // old red text under a button reading "Rebasing" describes nothing.
                integrationError = nil
                Task {
                    let outcome = await model.integrate(taskID: taskID)
                    // A verification runs for minutes, and the user is free to look
                    // elsewhere meanwhile. A refusal that belongs to a card nobody
                    // is on is dropped rather than pinned under the next task — the
                    // failed `checked` event is in that task's own log either way.
                    guard model.selection == taskID else { return }
                    integrationError = outcome
                }
            }
            .controlSize(.small)
            .disabled(model.integrationStep != .idle || Self.blocked(assessment))

            // Only on the tasks that would actually face this prompt — the pending
            // command is one value, but it is not every task's command.
            if model.pendingVerifyCommand != nil,
               model.pendingVerifyCommand == model.verifyCommand(for: taskID) {
                Button("Allow this command") {
                    model.allowVerifyCommand()
                    integrationError = nil
                }
                .controlSize(.small)
            }
        }
    }

    /// The diff is fetched when it is opened, not on every draw. Keying the
    /// expansion on the task id also closes it when the selection moves.
    private func diffDisclosure(_ taskID: String) -> some View {
        let isOpen = Binding(
            get: { expandedDiff == taskID },
            set: { open in
                expandedDiff = open ? taskID : nil
                if open { Task { await model.refreshDiff(for: taskID) } }
            })
        return DisclosureGroup("Diff", isExpanded: isOpen) {
            ScrollView(.horizontal) {
                Text(model.integrationDiff(for: taskID))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
        }
        .font(.system(size: 11))
    }

    /// Conflicts and loose changes are the two things no click can push through.
    static func blocked(_ assessment: Assessment) -> Bool { blockReason(assessment) != nil }

    /// Why the button is disabled, in the user's terms — nil when it is not.
    ///
    /// `hasLooseWork`, not `isDirty`: the untracked-inclusive view is what a `.build/`
    /// directory left by the last verification trips, and reading it here disabled the
    /// button with no explanation and nothing the user could do from the card. The
    /// service refuses on tracked modifications only, so this reads the same thing.
    static func blockReason(_ assessment: Assessment) -> String? {
        if case .conflicted = assessment.mergeability {
            return "Blocked: the files above conflict with the base. Resolve them in the "
                + "worktree and commit, then this can merge."
        }
        if assessment.hasLooseWork {
            return "Blocked: the worktree has uncommitted changes to tracked files. "
                + "Commit or discard them in it first."
        }
        return nil
    }
}
