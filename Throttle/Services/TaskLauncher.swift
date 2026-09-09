import Foundation

/// Prepares everything a task needs to start, and stops short of starting it.
///
/// The split is deliberate: `prepare` creates the worktree, claims the task and
/// writes the kickoff prompt — all testable — and returns a plan the cockpit
/// turns into a tab. Nothing here opens a session on its own, which keeps the
/// "advisory, never automatic" rule true in the code and not just in the UI.
enum TaskLauncher {

    struct LaunchPlan: Sendable, Equatable {
        let taskID: String
        let runtime: AgentRuntime
        /// The task's own worktree — never the user's main checkout.
        let workingDirectory: URL
        let branch: String
        let kickoff: String
        let missionID: UUID
        /// The private grant the runtime is launched with: this plan's repository
        /// and this worktree, this author, reporting only — never another claim.
        let authorityDescriptor: URL
    }

    enum LaunchError: Error, Equatable {
        case unknownTask(String)
        case alreadyHeld(String, owner: String)
    }

    private struct PreparationContext {
        let author: String
        let base: String
        let missionID: UUID
    }

    static func prepare(taskID: String, runtime: AgentRuntime, repo: URL,
                        author: String, base: String = "HEAD",
                        missionID: UUID = UUID()) throws -> LaunchPlan {
        let store = PlanStore(projectRoot: repo)
        return try store.mutate { store in
            try prepareLocked(taskID: taskID, runtime: runtime, repo: repo,
                              context: PreparationContext(author: author, base: base, missionID: missionID),
                              store: store)
        }
    }

    private static func prepareLocked(taskID: String, runtime: AgentRuntime, repo: URL,
                                      context: PreparationContext,
                                      store: PlanStore) throws -> LaunchPlan {
        let author = context.author
        let base = context.base
        let missionID = context.missionID
        let plan = try store.loadPlan()
        guard let task = plan.task(taskID) else { throw LaunchError.unknownTask(taskID) }

        // Re-check ownership here rather than trusting the UI's last refresh: a
        // second agent may have claimed the task since the button was drawn.
        let current = try store.state(for: taskID)
        if let owner = current.owner {
            throw LaunchError.alreadyHeld(taskID, owner: owner)
        }
        guard current.chainValid else { throw PlanStoreError.invalidLog(taskID) }

        let worktree = try TaskWorktreeService.create(taskID: taskID, in: repo, base: base)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: author,
                                   type: .claimed, missionID: missionID.uuidString),
                         to: taskID)

        let authority = PlanMCPAuthority(projectRoots: [repo, worktree], author: author,
                                         operations: [.read, .event, .verdict], expiresAt: nil)
        let descriptor = try writeAuthority(authority, missionID: missionID)
        return LaunchPlan(taskID: taskID, runtime: runtime, workingDirectory: worktree,
                          branch: try TaskWorktreeService.branchName(for: taskID),
                          kickoff: kickoff(for: task, author: author, plan: plan),
                          missionID: missionID, authorityDescriptor: descriptor)
    }

    /// Descriptors live in the user's own Application Support, never inside a
    /// repository an agent could commit, and are created exclusively with 0600.
    static var authorityDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Throttle/authority", isDirectory: true)
    }

    static func writeAuthority(_ authority: PlanMCPAuthority, missionID: UUID,
                               directory: URL = authorityDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(missionID.uuidString + ".json")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PlanStoreError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: try authority.encoded())
        try handle.close()
        return url
    }

    /// The prompt the agent opens on. It states the task, the boundary it must not
    /// cross, and how to report — an agent that does not know it should report
    /// leaves the plan looking stalled while it works.
    static func kickoff(for task: PlanTask, author: String, plan: Plan) -> String {
        var lines = [
            "You are working on one task from this project's Throttle plan.",
            "",
            "TASK \(task.id) — \(task.title)",
            "Kind: \(task.kind.rawValue)"
        ]
        if !task.dependsOn.isEmpty {
            lines.append("Depends on: \(task.dependsOn.joined(separator: ", ")) (already done)")
        }
        let siblings = plan.children(of: task.parent).filter { $0.id != task.id }
        if !siblings.isEmpty {
            lines.append("Other agents may be working on: "
                + siblings.map(\.id).joined(separator: ", ")
                + ". Stay inside this task; do not fix theirs.")
        }
        lines.append(contentsOf: [
            "",
            "You are in a git worktree of your own. Commit here; do not merge.",
            "",
            "Report as you go, with `by` set to \"\(author)\":",
            "  throttle_task_event  progress   — with a pct",
            "  throttle_task_event  evidence   — a commit sha, a test count, a file path",
            "  throttle_task_event  blocked    — with the reason, rather than guessing",
            "  throttle_task_event  completed  — when it is genuinely done",
            "  throttle_task_event  released   — if you stop, so someone else can take it"
        ])
        if task.sotaGate {
            lines.append("")
            lines.append("This task is SOTA-gated: `completed` parks it for counter-analysis. "
                + "Do not report it to the user as finished.")
        }
        return lines.joined(separator: "\n")
    }
}
