import Foundation

enum WorkflowClaimContractError: Error, Equatable, CustomStringConvertible {
    case unavailableRecipe(String)
    case invalidWorkContract(String)
    case workContractChanged
    case instructionCaptureFailed
    case unboundRecipe
    case instructionsChanged
    case missingEvidence([String])

    var description: String {
        switch self {
        case .unavailableRecipe(let taskID):
            return "\(taskID) names an unavailable or invalid workflow recipe."
        case .invalidWorkContract(let taskID):
            return "\(taskID) has an invalid or contradictory work contract."
        case .workContractChanged:
            return "the work contract changed during this work. Release and review it first."
        case .instructionCaptureFailed:
            return "project instructions could not be captured for this recipe."
        case .unboundRecipe:
            return "the workflow recipe is not bound to this claim. Release and claim it again."
        case .instructionsChanged:
            return "project instructions changed during this work. Release and review them first."
        case .missingEvidence(let kinds):
            return "recipe evidence is missing: \(kinds.joined(separator: ", "))."
        }
    }
}

enum WorkflowClaimContract {
    struct Prepared: Sendable {
        var event: TaskEvent
        var recipe: WorkflowRecipe?
    }

    static func prepare(
        task: PlanTask,
        projectRoot: URL,
        author: String,
        missionID: String?,
        now: Date = Date()
    ) throws -> Prepared {
        var event = TaskEvent(
            seq: 0,
            timestamp: now,
            author: author,
            type: .claimed,
            missionID: missionID
        )
        guard task.contractIsValid else {
            throw WorkflowClaimContractError.invalidWorkContract(task.id)
        }
        event.workContractDigest = task.workContract?.digest
        guard let reference = task.effectiveRecipe else {
            return Prepared(event: event, recipe: nil)
        }
        guard let recipe = WorkflowRecipeCatalog.resolve(reference),
              let recipeDigest = recipe.digest else {
            throw WorkflowClaimContractError.unavailableRecipe(task.id)
        }
        guard let instructionDigest = instructionDigest(at: projectRoot) else {
            throw WorkflowClaimContractError.instructionCaptureFailed
        }
        event.recipeID = recipe.id
        event.recipeDigest = recipeDigest
        event.instructionSnapshotDigest = instructionDigest
        return Prepared(event: event, recipe: recipe)
    }

    static func candidateRefusal(
        task: PlanTask,
        author: String,
        projectRoot: URL,
        events: [TaskEvent]
    ) -> WorkflowClaimContractError? {
        guard task.contractIsValid else { return .invalidWorkContract(task.id) }
        guard task.workContract != nil || task.effectiveRecipe != nil else { return nil }
        guard let claim = events.last(where: {
            $0.type == .claimed && $0.author == author
        }) else { return .unboundRecipe }
        guard claim.workContractDigest == task.workContract?.digest else {
            return .workContractChanged
        }
        guard let reference = task.effectiveRecipe else { return nil }
        guard let recipe = WorkflowRecipeCatalog.resolve(reference),
              let recipeDigest = recipe.digest else {
            return .unavailableRecipe(task.id)
        }
        guard claim.recipeID == recipe.id, claim.recipeDigest == recipeDigest else {
            return .unboundRecipe
        }
        guard instructionDigest(at: projectRoot) == claim.instructionSnapshotDigest else {
            return .instructionsChanged
        }
        let missing = recipe.missingEvidence(in: events.filter { $0.seq > claim.seq })
        guard missing.isEmpty else {
            return .missingEvidence(missing.map {
                $0.acceptedKinds.joined(separator: "|")
            })
        }
        return nil
    }

    private static func instructionDigest(at root: URL) -> String? {
        guard let snapshot = try? ProjectInstructionService.capture(
            projectRoot: root,
            targetDirectory: root
        ) else { return nil }
        return snapshot.digest
    }
}
