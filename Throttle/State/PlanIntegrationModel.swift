import Foundation

/// The integration half of `PlanModel`: everything between a task reaching `done`
/// and its commits being in the base branch.
///
/// This file owns the rebase → verify → merge sequence, the consent prompt in front
/// of the project's own command, and the three caches the card reads — the
/// assessment, the reason there is no assessment, and the diff. `PlanModel.swift`
/// owns the plan itself and keeps the stored `integration` property, because
/// `@Observable` only rewrites a class body; every accessor over it is here.
extension PlanModel {

    /// What the button is doing right now, so the card can say which step it
    /// stopped at rather than only that something failed.
    enum IntegrationStep: String, Sendable {
        case idle, rebasing, verifying, merging
    }

    /// One value for the whole integration half, so the file split above costs the
    /// class exactly one non-private stored property instead of five.
    struct IntegrationState {
        /// Keyed by project root path. A single field greyed out the Integrate button
        /// on *every* project's card while any one of them was running: honest state
        /// — one model serves whichever project is bound — that read as a bug.
        var steps: [String: IntegrationStep] = [:]
        /// Assessing a task shells out to git half a dozen times, so it is computed
        /// when the inspector's selection changes and cached here — never read from a
        /// SwiftUI `body`, which would run git on every draw of a scrolling list.
        var assessments: [String: Assessment] = [:]
        /// Why there is no assessment. A `try?` here used to swallow every `assess`
        /// failure, so a worktree that had wandered off its task branch drew no card
        /// at all — an empty space where the user was looking for the button.
        var errors: [String: String] = [:]
        /// Same as the assessment, fetched only when the user opens the disclosure.
        var diffs: [String: String] = [:]
        /// The command the user has been asked to allow, if any.
        var pendingVerifyCommand: String?

        /// Drops everything keyed by task id, which is everything that describes one
        /// project. `steps` survives on purpose: it is keyed by project root and
        /// describes work in flight, not a project.
        mutating func forgetCaches() {
            assessments = [:]
            errors = [:]
            diffs = [:]
            pendingVerifyCommand = nil
        }
    }

    private static var author: String { "throttle:app" }

    /// The step the *currently bound* project is on. Another project's run leaves
    /// this `.idle`, which is the point.
    var integrationStep: IntegrationStep {
        root.flatMap { integration.steps[$0.path] } ?? .idle
    }

    var pendingVerifyCommand: String? { integration.pendingVerifyCommand }

    /// The task's own command wins over the project's: a task that needs a
    /// narrower check should not be forced through the whole suite.
    func verifyCommand(for taskID: String) -> String? {
        plan?.task(taskID)?.verify ?? plan?.verify
    }

    func assessment(for taskID: String) -> Assessment? { integration.assessments[taskID] }

    /// Why this task cannot be assessed, when it cannot be. The card shows it in
    /// place of the controls rather than drawing nothing.
    func assessmentError(for taskID: String) -> String? { integration.errors[taskID] }

    func integrationDiff(for taskID: String) -> String { integration.diffs[taskID] ?? "" }

    /// Reads what the task would merge, off the main actor. Only a `.done` task has
    /// anything to assess; anything else drops the cached entry, which is what
    /// clears the card once the merge landed.
    ///
    /// The rebind check is on the *write*, not on the call. `assess` shells out to
    /// git several times, and a tab switch during those milliseconds would otherwise
    /// put one project's assessment into another project's cache — task ids are only
    /// unique inside one plan. Guarding before the `await` checked the wrong instant.
    func refreshAssessment(for taskID: String) async {
        guard let root, state(taskID).status == .done else {
            integration.assessments[taskID] = nil
            integration.errors[taskID] = nil
            return
        }
        do {
            let assessment = try await Self.offMain {
                try TaskIntegrationService.assess(taskID: taskID, in: root)
            }
            guard self.root?.path == root.path else { return }
            integration.assessments[taskID] = assessment
            integration.errors[taskID] = nil
        } catch {
            guard self.root?.path == root.path else { return }
            integration.assessments[taskID] = nil
            integration.errors[taskID] = Self.describe(error)
        }
    }

    func refreshDiff(for taskID: String) async {
        guard let root else { return }
        let diff = (try? await Self.offMain {
            try TaskIntegrationService.diff(taskID: taskID, in: root)
        }) ?? ""
        guard self.root?.path == root.path else { return }
        integration.diffs[taskID] = diff
    }

    func allowVerifyCommand() {
        guard let root, let command = integration.pendingVerifyCommand else { return }
        VerifyConsent.grant(project: root, command: command, defaults: verifyConsentDefaults)
        integration.pendingVerifyCommand = nil
    }
}

// MARK: - The sequence

/// Split from the extension above to stay under SwiftLint's `type_body_length`.
extension PlanModel {

    /// Runs rebase → verify → merge and returns nil on success, or the refusal to
    /// show. Stops at the first thing that says no; nothing is written to the base
    /// branch unless all three passed.
    ///
    /// Async because the middle step runs the project's own check command, which
    /// can take minutes — on the actor that draws, that is a frozen app.
    func integrate(taskID: String) async -> String? {
        guard let root, let store, let task = plan?.task(taskID) else {
            return "This project has no plan to integrate against."
        }
        // Per project, not per model: a run in another project is not a reason to
        // refuse this one, and the button on its card is not greyed out either.
        guard integration.steps[root.path, default: .idle] == .idle else {
            return "An integration is already running."
        }
        // Only the card gated this before. A `.review` task would have run the
        // project's verify command for nothing: `checked` is accepted only on a task
        // that reached `.done`, so the event would have been silently rejected and
        // the integration refused as unverified — after minutes of shelling out.
        guard state(taskID).status == .done else {
            return "\(taskID) is \(state(taskID).status.rawValue), not done — nothing to integrate yet."
        }
        guard let command = verifyCommand(for: taskID) else {
            return "No verify command in this plan — add `verify` to the plan or the task."
        }
        guard VerifyConsent.isGranted(project: root, command: command,
                                      defaults: verifyConsentDefaults) else {
            integration.pendingVerifyCommand = command
            return "Throttle has not been allowed to run `\(command)` in this project yet."
        }
        integration.pendingVerifyCommand = nil

        integration.steps[root.path] = .rebasing
        let outcome = await runSequence(taskID: taskID, task: task, root: root,
                                        store: store, command: command)
        // Released for the project the sequence ran in, never for whichever one is
        // bound now: the work it stood for has ended, and it was that project's.
        integration.steps[root.path] = .idle
        // The tail, too, belongs to the project the sequence ran in. A tab switch
        // during those minutes rebinds the model, and reloading or caching an
        // assessment then would write this run's conclusions into a plan it says
        // nothing about — task ids are only unique inside one plan. The refusal string
        // is still returned; the card drops it when the selection has moved.
        guard self.root?.path == root.path else { return outcome }
        reload()
        await refreshAssessment(for: taskID)
        return outcome
    }

    /// The three steps themselves, each one off the main actor with the step
    /// published between them. Split from `integrate` so the guards, the step
    /// reset and the reload all happen on exactly one path.
    private func runSequence(taskID: String, task: PlanTask, root: URL,
                             store: PlanStore, command: String) async -> String? {
        let author = Self.author
        do {
            _ = try await Self.offMain {
                try TaskIntegrationService.rebase(taskID: taskID, in: root)
            }
            integration.steps[root.path] = .verifying
            let verdict = try await Self.offMain {
                try TaskIntegrationService.verify(taskID: taskID, in: root, command: command,
                                                  store: store, author: author)
            }
            guard verdict.passed else {
                return "The verification failed, so nothing was merged.\n"
                    + String(verdict.output.suffix(600))
            }
            integration.steps[root.path] = .merging
            _ = try await Self.offMain {
                try TaskIntegrationService.integrate(taskID: taskID, in: root, store: store,
                                                     task: task, author: author)
            }
            return nil
        } catch let error as TaskIntegrationError {
            return Self.explain(error)
        } catch {
            return String(describing: error)
        }
    }

    /// One blocking git or shell call, run off the main actor. `PlanStore` guards
    /// itself with a lock and `TaskIntegrationService` is a stateless enum, so both
    /// are safe here; what is not safe is holding the drawing actor for minutes.
    private static func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private static func describe(_ error: Error) -> String {
        (error as? TaskIntegrationError).map(explain) ?? String(describing: error)
    }

    private static func explain(_ error: TaskIntegrationError) -> String {
        switch error {
        case .noWorktree(let id):
            return "\(id) has no worktree — nothing to integrate."
        case .gitFailed(let output):
            return String(output.suffix(600))
        case .rebaseAbortFailed(let rebaseOutput, let abortOutput):
            // The one case where the worktree may be left mid-rebase, so it names
            // the command that gets the agent's own state back.
            return "The rebase conflicted and could not be undone — the worktree may still "
                + "be mid-rebase. Run `git rebase --abort` in it.\n"
                + String(rebaseOutput.suffix(300)) + "\n" + String(abortOutput.suffix(300))
        case .refused(.dirty):
            return "The worktree still holds uncommitted changes."
        case .refused(.behind):
            return "The base moved — rebase again before integrating."
        case .refused(.unverified):
            return "No green check for these exact commits."
        case .refused(.ungated):
            return "SOTA-gated: counter-analysis has not ruled on it."
        case .refused(.detached):
            return "The task's worktree is not on its own branch — check `task/<id>` back out "
                + "in it before integrating."
        }
    }
}
