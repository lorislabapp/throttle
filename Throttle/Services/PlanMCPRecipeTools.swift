import Foundation

extension PlanMCPTools {
    private struct ClaimRequest {
        var projectRoot: URL
        var taskID: String
        var author: String
        var missionID: String?
        var retry: MutationRetry
    }

    private struct ClaimContext {
        var event: TaskEvent
        var task: PlanTask
        var recipe: WorkflowRecipe?
        var plan: Plan
        var retry: MutationRetry
    }

    static func claimText(
        project: String?,
        taskID: String,
        author: String,
        missionID: String?,
        retry: MutationRetry = MutationRetry()
    ) -> String {
        let request = ClaimRequest(
            projectRoot: URL(
                fileURLWithPath: project ?? FileManager.default.currentDirectoryPath,
                isDirectory: true
            ),
            taskID: taskID,
            author: author,
            missionID: missionID,
            retry: retry
        )
        do {
            return try store(project).mutate { prepareClaim(request, store: $0) }
        } catch {
            return "Refused: the plan mutation could not be safely persisted."
        }
    }

    private static func prepareClaim(_ request: ClaimRequest, store: PlanStore) -> String {
        guard let plan = try? store.loadPlan() else {
            return "Refused: no plan at this project root."
        }
        guard let task = plan.task(request.taskID) else {
            return "Refused: no task \(request.taskID) in this plan."
        }
        let prepared: WorkflowClaimContract.Prepared
        do {
            prepared = try WorkflowClaimContract.prepare(
                task: task,
                projectRoot: request.projectRoot,
                author: request.author,
                missionID: request.missionID
            )
        } catch let error as WorkflowClaimContractError {
            return "Refused: \(error.description)"
        } catch {
            return "Refused: the workflow contract could not be prepared."
        }
        var context = ClaimContext(
            event: prepared.event,
            task: task,
            recipe: prepared.recipe,
            plan: plan,
            retry: request.retry
        )
        return completeClaim(&context, store: store)
    }

    private static func completeClaim(
        _ context: inout ClaimContext,
        store: PlanStore
    ) -> String {
        let taskID = context.task.id
        if let replay = retryResponse(
            &context.event,
            retry: context.retry,
            taskID: taskID,
            store: store
        ) { return replay }
        guard let current = try? store.state(for: taskID) else {
            return "Refused: could not read the log for \(taskID)."
        }
        if let owner = current.owner {
            return "Refused: \(taskID) is already held by \(owner). Pick another task from throttle_plan_read."
        }
        let unmet = context.task.dependsOn.filter {
            (try? store.state(for: $0))?.status != .done
        }
        if !unmet.isEmpty {
            return "Refused: \(taskID) depends on \(unmet.joined(separator: ", ")), which is not done."
        }
        guard current.chainValid,
              current.status == .pending,
              context.plan.isLeafByID[taskID] == true else {
            return "Refused: this task is not an actionable leaf with a valid history."
        }
        guard let written = try? store.append(context.event, to: taskID) else {
            return "Refused: could not write the log for \(taskID)."
        }
        return claimResponse(written: written, task: context.task, recipe: context.recipe)
    }

    private static func claimResponse(
        written: TaskEvent,
        task: PlanTask,
        recipe: WorkflowRecipe?
    ) -> String {
        var output = """
        Claimed \(task.id) — \(task.title) (seq \(written.seq)).
        You now own it: report with throttle_task_event, and release it if you stop.
        """
        output += "\nWhen the work is ready, report `candidate_complete`. Throttle's verification"
            + " decides whether it may become done."
        if task.sotaGate {
            output += " A green check then sends it to independent counter-analysis."
        }
        if let recipe {
            let evidence = recipe.evidence.map {
                $0.acceptedKinds.joined(separator: "|")
            }.joined(separator: ", ")
            output += "\nRecipe \(recipe.id.rawValue) r\(recipe.revision) is pinned to this claim."
                + " Required evidence: \(evidence)."
        }
        return output
    }

    static func recipeRefusal(
        task: PlanTask,
        author: String,
        project: String?,
        store: PlanStore
    ) -> String? {
        guard let history = try? store.events(for: task.id) else {
            return "Refused: could not read the log for \(task.id)."
        }
        let root = URL(
            fileURLWithPath: project ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return WorkflowClaimContract.candidateRefusal(
            task: task,
            author: author,
            projectRoot: root,
            events: history.events
        ).map { "Refused: \($0.description)" }
    }
}
