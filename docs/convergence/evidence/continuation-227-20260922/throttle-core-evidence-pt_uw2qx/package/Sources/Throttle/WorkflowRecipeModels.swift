import CryptoKit
import Foundation

enum WorkflowRecipeID: String, Codable, Sendable, CaseIterable {
    case bugWithRegression = "bug-with-regression"
    case nativeUIWithValidation = "native-ui-with-validation"
    case reviewableChange = "reviewable-change"
}

struct WorkflowRecipeReference: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var id: WorkflowRecipeID
    var revision: Int
}

struct WorkflowRecipeStep: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var outcome: String
}

struct WorkflowRecipeEvidenceRequirement: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var acceptedKinds: [String]
}

/// A recipe describes the order and evidence for a familiar workflow. It has no
/// command, tool or permission field, so selecting one cannot widen authority.
struct WorkflowRecipe: Codable, Sendable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: WorkflowRecipeID
    var revision: Int
    var title: String
    var steps: [WorkflowRecipeStep]
    var evidence: [WorkflowRecipeEvidenceRequirement]

    var reference: WorkflowRecipeReference {
        WorkflowRecipeReference(id: id, revision: revision)
    }

    var digest: String? {
        guard isValid else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        let stepIDs = steps.map(\.id)
        let evidenceIDs = evidence.map(\.id)
        return schemaVersion == 1
            && revision > 0
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !steps.isEmpty
            && !evidence.isEmpty
            && Set(stepIDs).count == stepIDs.count
            && Set(evidenceIDs).count == evidenceIDs.count
            && steps.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.outcome.isEmpty
            }
            && evidence.allSatisfy {
                !$0.id.isEmpty
                    && !$0.title.isEmpty
                    && !$0.acceptedKinds.isEmpty
                    && !$0.acceptedKinds.contains("")
                    && Set($0.acceptedKinds).count == $0.acceptedKinds.count
            }
    }

    func missingEvidence(in events: [TaskEvent]) -> [WorkflowRecipeEvidenceRequirement] {
        let observed = Set(events.compactMap { event -> String? in
            guard event.type == .evidence,
                  !(event.ref ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return event.kind
        })
        return evidence.filter { requirement in
            observed.isDisjoint(with: requirement.acceptedKinds)
        }
    }
}

enum WorkflowRecipeCatalog {
    static let bugWithRegression = WorkflowRecipe(
        id: .bugWithRegression,
        revision: 1,
        title: "Bug fix with regression",
        steps: [
            WorkflowRecipeStep(
                id: "reproduce",
                title: "Reproduce",
                outcome: "Capture the failing behavior and its exact trigger."
            ),
            WorkflowRecipeStep(
                id: "fix",
                title: "Correct",
                outcome: "Apply the smallest change that preserves declared behavior."
            ),
            WorkflowRecipeStep(
                id: "verify",
                title: "Prove",
                outcome: "Run the regression and the relevant broader checks."
            )
        ],
        evidence: [
            WorkflowRecipeEvidenceRequirement(
                id: "reproduction",
                title: "Failing reproduction",
                acceptedKinds: ["reproduction"]
            ),
            WorkflowRecipeEvidenceRequirement(
                id: "regression",
                title: "Regression test",
                acceptedKinds: ["regression-test"]
            ),
            WorkflowRecipeEvidenceRequirement(
                id: "verification",
                title: "Verification result",
                acceptedKinds: ["test-result"]
            )
        ]
    )

    static let nativeUIWithValidation = WorkflowRecipe(
        id: .nativeUIWithValidation,
        revision: 1,
        title: "Native UI with runtime validation",
        steps: [
            WorkflowRecipeStep(
                id: "contract",
                title: "Bind the design contract",
                outcome: "Name the approved flow, states and accessibility criteria."
            ),
            WorkflowRecipeStep(
                id: "implement",
                title: "Implement natively",
                outcome: "Use the platform behavior and preserve loading, empty and error states."
            ),
            WorkflowRecipeStep(
                id: "observe",
                title: "Observe the running build",
                outcome: "Exercise the important path and record runtime and accessibility evidence."
            )
        ],
        evidence: [
            WorkflowRecipeEvidenceRequirement(
                id: "design-contract",
                title: "Design contract",
                acceptedKinds: ["design-contract"]
            ),
            WorkflowRecipeEvidenceRequirement(
                id: "native-build",
                title: "Native build",
                acceptedKinds: ["native-build"]
            ),
            WorkflowRecipeEvidenceRequirement(
                id: "runtime",
                title: "Executed UI path",
                acceptedKinds: ["runtime-validation"]
            ),
            WorkflowRecipeEvidenceRequirement(
                id: "accessibility",
                title: "Accessibility result",
                acceptedKinds: ["accessibility"]
            )
        ]
    )

    static let reviewableChange = WorkflowRecipe(
        id: .reviewableChange,
        revision: 1,
        title: "Prepare a reviewable change",
        steps: [
            WorkflowRecipeStep(
                id: "scope",
                title: "Bound the change",
                outcome: "Keep the diff tied to the task and surface any extra proposal separately."
            ),
            WorkflowRecipeStep(
                id: "validate",
                title: "Validate",
                outcome: "Run the checks that establish the changed behavior."
            ),
            WorkflowRecipeStep(
                id: "explain",
                title: "Prepare review context",
                outcome: "Record behavior, evidence, risks and open gates for a reviewer."
            )
        ],
        evidence: [
            WorkflowRecipeEvidenceRequirement(
                id: "diff",
                title: "Scoped diff",
                acceptedKinds: ["diff"]
            ),
            WorkflowRecipeEvidenceRequirement(
                id: "validation",
                title: "Validation result",
                acceptedKinds: ["test-result"]
            ),
            WorkflowRecipeEvidenceRequirement(
                id: "review-context",
                title: "Review context",
                acceptedKinds: ["review-summary"]
            )
        ]
    )

    static let all = [bugWithRegression, nativeUIWithValidation, reviewableChange]

    static func resolve(_ reference: WorkflowRecipeReference) -> WorkflowRecipe? {
        guard reference.schemaVersion == 1 else { return nil }
        return all.first { recipe in
            recipe.id == reference.id && recipe.revision == reference.revision
        }
    }
}
