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
        /// Nil means no project budget ledger was configured. A value proves only
        /// local admission; provider-side enforcement remains separately observed.
        let budgetAdmission: BudgetAdmissionDecision?
    }

    enum LaunchError: Error, Equatable {
        case unknownTask(String)
        case alreadyHeld(String, owner: String)
        case budget(BudgetAdmissionError)
    }

    private struct PreparationContext {
        let author: String
        let base: String
        let missionID: UUID
        let role: AgentRole
    }

    static func prepare(taskID: String, runtime: AgentRuntime, repo: URL,
                        author: String, base: String = "HEAD",
                        missionID: UUID = UUID(), role: AgentRole = .builder) throws -> LaunchPlan {
        let store = PlanStore(projectRoot: repo)
        return try store.mutate { store in
            try prepareLocked(taskID: taskID, runtime: runtime, repo: repo,
                              context: PreparationContext(author: author, base: base, missionID: missionID, role: role),
                              store: store)
        }
    }

    private static func prepareLocked(taskID: String, runtime: AgentRuntime, repo: URL,
                                      context: PreparationContext,
                                      store: PlanStore) throws -> LaunchPlan {
        let (author, base, missionID) = (context.author, context.base, context.missionID)
        let plan = try store.loadPlan()
        guard let task = plan.task(taskID) else { throw LaunchError.unknownTask(taskID) }

        // Re-check ownership here rather than trusting the UI's last refresh: a
        // second agent may have claimed the task since the button was drawn.
        try requireUnclaimed(taskID: taskID, store: store)

        var preparedClaim = try WorkflowClaimContract.prepare(
            task: task,
            projectRoot: repo,
            author: author,
            missionID: missionID.uuidString
        )
        let admission = try budgetAdmission(for: task, missionID: missionID, repo: repo)
        preparedClaim.event.budgetReservationID = admission?.reservation.id
        preparedClaim.event.budgetLedgerRevision = admission?.ledgerRevision

        var descriptor: URL?
        do {
            let worktreeBase = task.workContract?.baseRevision ?? base
            let worktree = try TaskWorktreeService.create(taskID: taskID, in: repo, base: worktreeBase)
            let issuedAt = Date()
            let authority = PlanMCPAuthority(
                projectRoots: [repo, worktree],
                author: author,
                operations: [.read, .event, .verdict],
                taskID: taskID,
                missionID: missionID,
                issuedAt: issuedAt,
                expiresAt: authorityExpiration(task: task, issuedAt: issuedAt)
            )
            descriptor = try writeAuthority(authority, missionID: missionID)
            preparedClaim.event.authorityGrantID = authority.grantID
            try store.append(preparedClaim.event, to: taskID)
            return LaunchPlan(
                taskID: taskID,
                runtime: runtime,
                workingDirectory: worktree,
                branch: try TaskWorktreeService.branchName(for: taskID),
                kickoff: retryAwareKickoff(task, plan, context, admission, store),
                missionID: missionID,
                authorityDescriptor: try descriptor.unwrapped(),
                budgetAdmission: admission
            )
        } catch {
            if let descriptor { try? FileManager.default.removeItem(at: descriptor) }
            if let reservationID = admission?.reservation.id {
                _ = try? BudgetAdmissionStore(projectRoot: repo).release(reservationID: reservationID)
            }
            throw error
        }
    }

    private static func requireUnclaimed(taskID: String, store: PlanStore) throws {
        let current = try store.state(for: taskID)
        if let owner = current.owner {
            throw LaunchError.alreadyHeld(taskID, owner: owner)
        }
        guard current.chainValid else { throw PlanStoreError.invalidLog(taskID) }
    }

    private static func budgetAdmission(
        for task: PlanTask,
        missionID: UUID,
        repo: URL
    ) throws -> BudgetAdmissionDecision? {
        do {
            return try TaskBudgetAdmission.reserveIfConfigured(
                task: task,
                missionID: missionID,
                projectRoot: repo
            )
        } catch let error as BudgetAdmissionError {
            throw LaunchError.budget(error)
        }
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
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              Darwin.chmod(directory.path, 0o700) == 0 else {
            throw PlanStoreError.unsafeStorage
        }
        let url = directory.appendingPathComponent(missionID.uuidString + ".json")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PlanStoreError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: try authority.encoded())
        try PlanStore.synchronize(descriptor)
        try handle.close()
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { throw PlanStoreError.unsafeStorage }
        defer { Darwin.close(directoryDescriptor) }
        try PlanStore.synchronize(directoryDescriptor)
        return url
    }

    /// The kickoff with what earlier attempts on the task taught and the chosen role.
    private static func retryAwareKickoff(_ task: PlanTask, _ plan: Plan, _ context: PreparationContext,
                                          _ admission: BudgetAdmissionDecision?, _ store: PlanStore) -> String {
        let history = AttemptHistory.lessons(taskID: task.id, events: (try? store.events(for: task.id).events) ?? [])
        return kickoff(for: task, author: context.author, plan: plan, budgetAdmission: admission,
                       history: history, role: context.role)
    }

    /// The prompt the agent opens on. It states the task, the boundary it must not
    /// cross, and how to report — an agent that does not know it should report
    /// leaves the plan looking stalled while it works.
    static func kickoff(
        for task: PlanTask,
        author: String,
        plan: Plan,
        budgetAdmission: BudgetAdmissionDecision? = nil,
        history: [AttemptHistory.Lesson] = [],
        role: AgentRole = .builder
    ) -> String {
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
            "  throttle_task_event  candidate_complete — when the result is ready for Throttle to verify",
            "  throttle_task_event  released   — if you stop, so someone else can take it"
        ])
        lines.append(contentsOf: workContractLines(task.workContract))
        lines.append(contentsOf: role.charter)
        lines.append(contentsOf: AttemptHistory.kickoffLines(history))
        if let budgetAdmission {
            let amounts = budgetAdmission.reservation.request.amounts.map {
                "\($0.value) \($0.resource.rawValue)"
            }.joined(separator: ", ")
            lines.append("Budget reserved locally: \(amounts). External enforcement: unavailable.")
        }
        if let reference = task.effectiveRecipe,
           let recipe = WorkflowRecipeCatalog.resolve(reference) {
            lines.append("")
            lines.append("Workflow recipe \(recipe.id.rawValue) r\(recipe.revision):")
            lines.append(contentsOf: recipe.steps.map { "  \($0.id) — \($0.outcome)" })
            lines.append("Required evidence kinds: " + recipe.evidence.flatMap(\.acceptedKinds).joined(separator: ", "))
            lines.append("The recipe adds evidence obligations; it grants no tools or permissions.")
        }
        if task.sotaGate {
            lines.append("")
            lines.append("This task is SOTA-gated: a verified candidate parks for counter-analysis. "
                + "Do not report it to the user as finished.")
        }
        return lines.joined(separator: "\n")
    }

    private static func workContractLines(_ contract: WorkflowWorkContract?) -> [String] {
        guard let contract else { return [] }
        var lines = [
            "",
            "Work contract r\(contract.revision): \(contract.objective)",
            "Approved product reference: \(contract.approvedProductReference)",
            "Allowed paths: \(contract.allowedChangePaths.joined(separator: ", "))",
            "Must preserve: \(contract.mustPreserve.joined(separator: "; "))"
        ]
        if !contract.exclusions.isEmpty {
            lines.append("Excluded: \(contract.exclusions.joined(separator: "; "))")
        }
        if !contract.permissionRequirements.isEmpty {
            lines.append("Permission requirements are obligations to obtain approval, not grants.")
        }
        return lines
    }
}

private extension Optional {
    func unwrapped() throws -> Wrapped {
        guard let self else { throw PlanStoreError.unsafeStorage }
        return self
    }
}
