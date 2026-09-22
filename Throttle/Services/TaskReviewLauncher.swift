import Foundation

/// Prepares the independent review of a task that reached `.review`, and stops
/// short of starting it — the same "advisory, never automatic" split as
/// `TaskLauncher`.
///
/// The reviewer gets a narrower grant than a builder: it may read the plan and
/// record one verdict on this task, never claim or report progress. It works in
/// the task's existing worktree when there is one, so it judges exactly what the
/// builder left.
enum TaskReviewLauncher {

    enum ReviewError: Error, Equatable {
        case unknownTask(String)
        case notAwaitingReview(String, status: String)
        /// The verdict tool refuses a judge from the builder's own family; refusing
        /// here saves the user a session that could only end in that refusal.
        case sameRuntime(String)
    }

    /// A reviewer needs minutes, not the builder's day; a stale review grant is
    /// one nobody is watching.
    static let grantLifetime: TimeInterval = 4 * 60 * 60

    /// The runtime that judges work done by `builder`: the other model family for
    /// an agent's work, Codex for anything else (a human decision, a local model).
    static func reviewer(for builder: String?) -> AgentRuntime {
        builder == AgentRuntime.codex.rawValue ? .claudeCode : .codex
    }

    static func prepare(taskID: String, runtime: AgentRuntime, repo: URL, author: String,
                        missionID: UUID = UUID(), now: Date = Date()) throws -> TaskLauncher.LaunchPlan {
        let store = PlanStore(projectRoot: repo)
        let plan = try store.loadPlan()
        guard let task = plan.task(taskID) else { throw ReviewError.unknownTask(taskID) }
        let state = try store.state(for: taskID)
        guard state.status == .review else {
            throw ReviewError.notAwaitingReview(taskID, status: state.status.rawValue)
        }
        guard state.runtime != runtime.rawValue else { throw ReviewError.sameRuntime(runtime.label) }

        // A human decision never had a worktree; its evidence is in the plan itself.
        let taskWorktree = try TaskWorktreeService.path(for: taskID, in: repo)
        let worktree = FileManager.default.fileExists(atPath: taskWorktree.path) ? taskWorktree : repo
        let authority = PlanMCPAuthority(
            projectRoots: [repo, worktree],
            author: author,
            operations: [.read, .verdict],
            taskID: taskID,
            missionID: missionID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(grantLifetime)
        )
        let descriptor = try TaskLauncher.writeAuthority(authority, missionID: missionID)
        return TaskLauncher.LaunchPlan(
            taskID: taskID,
            runtime: runtime,
            workingDirectory: worktree,
            branch: try TaskWorktreeService.branchName(for: taskID),
            kickoff: kickoff(task: task, state: state, repo: repo, author: author),
            missionID: missionID,
            authorityDescriptor: descriptor,
            budgetAdmission: nil
        )
    }

    static func kickoff(task: PlanTask, state: TaskState, repo: URL, author: String) -> String {
        var lines = [
            "You are the independent reviewer of task \(task.id) — \(task.title).",
            "Another runtime (\(state.runtime ?? "unknown")) did the work; you judge it. Do not modify any file.",
            "",
            "1. Call throttle_plan_read with project \(repo.path) and read \(task.id)'s summary and evidence.",
            "2. Read the evidence files in this worktree and spot-check the claims against the cited sources.",
            "3. Decide: does it answer the task title, with claims that are sourced and consistent?",
            "4. Call throttle_task_verdict once: project \(repo.path), task_id \(task.id), by \(author),",
            "   verdict \"verified\" if it is solid, or \"rejected\" with a reason naming exactly what is missing."
        ]
        if task.workContract?.reviewRubric != nil {
            lines.append("   This task has a review rubric: include the structured review report it requires.")
        }
        if let summary = state.summary {
            lines += ["", "Builder's summary: \(summary)"]
        }
        return lines.joined(separator: "\n")
    }
}
