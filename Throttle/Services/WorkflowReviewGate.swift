import Foundation

/// A deterministic gate over a qualitative report. A model may write the
/// observations; this component binds them to the exact contract, candidate and
/// evidence, then applies every blocking criterion independently.
enum WorkflowReviewGate {
    static func evaluate(
        _ report: WorkflowReviewReport,
        task: PlanTask,
        state: TaskState
    ) throws -> WorkflowReviewEvaluation {
        guard let contract = task.workContract,
              let contractDigest = contract.digest else {
            throw WorkflowReviewError.staleContract
        }
        guard let rubric = contract.reviewRubric else {
            throw WorkflowReviewError.missingRubric
        }
        guard let rubricDigest = rubric.digest else {
            throw WorkflowReviewError.invalidRubric
        }
        guard report.schemaVersion == 1,
              report.taskID == task.id,
              report.workContractDigest == contractDigest,
              report.rubricDigest == rubricDigest,
              report.digest != nil else {
            throw WorkflowReviewError.invalidReport
        }
        guard let check = state.lastCheck, check.passed,
              report.candidateStamp == check.stamp else {
            throw WorkflowReviewError.staleCandidate
        }
        guard report.producerRuntime == state.runtime else {
            throw WorkflowReviewError.producerMismatch
        }
        try validateReviewer(report, rubric: rubric)
        try validateAssessments(report.assessments, rubric: rubric, state: state)

        let criterionByID = Dictionary(uniqueKeysWithValues: rubric.criteria.map { ($0.id, $0) })
        let blocking = report.assessments.compactMap { assessment -> String? in
            guard criterionByID[assessment.criterionID]?.blocking == true,
                  assessment.outcome == .fail || assessment.outcome == .notVerified else { return nil }
            return assessment.criterionID
        }.sorted()
        let nonblocking = report.assessments.compactMap { assessment -> String? in
            guard criterionByID[assessment.criterionID]?.blocking == false,
                  assessment.outcome == .fail || assessment.outcome == .notVerified else { return nil }
            return assessment.criterionID
        }.sorted()
        return WorkflowReviewEvaluation(
            decision: blocking.isEmpty ? .accepted : .rejected,
            blockingCriterionIDs: blocking,
            nonblockingFindingIDs: nonblocking
        )
    }

    private static func validateReviewer(
        _ report: WorkflowReviewReport,
        rubric: WorkflowReviewRubric
    ) throws {
        guard nonempty(report.reviewerID), nonempty(report.reviewerRuntime),
              nonempty(report.producerRuntime) else {
            throw WorkflowReviewError.invalidReport
        }
        if rubric.criteria.contains(where: \.requiresHuman), report.reviewerKind != .human {
            throw WorkflowReviewError.humanReviewRequired
        }
        if report.reviewerKind == .model {
            guard report.reviewerRuntime != report.producerRuntime,
                  report.reviewerID.hasPrefix(report.reviewerRuntime + ":") else {
                throw WorkflowReviewError.correlatedReviewer
            }
        }
    }

    private static func validateAssessments(
        _ assessments: [WorkflowReviewAssessment],
        rubric: WorkflowReviewRubric,
        state: TaskState
    ) throws {
        let expected = Set(rubric.criteria.map(\.id))
        let received = assessments.map(\.criterionID)
        guard Set(received) == expected, Set(received).count == received.count else {
            throw WorkflowReviewError.invalidReport
        }
        let known = knownEvidence(in: state)
        for assessment in assessments {
            guard let criterion = rubric.criteria.first(where: { $0.id == assessment.criterionID }) else {
                throw WorkflowReviewError.invalidReport
            }
            try validateAssessment(assessment, criterion: criterion, knownEvidence: known)
        }
    }

    private static func validateAssessment(
        _ assessment: WorkflowReviewAssessment,
        criterion: WorkflowReviewCriterion,
        knownEvidence: Set<WorkflowReviewEvidence>
    ) throws {
        let acceptedKinds = Set(criterion.acceptedEvidenceKinds)
        guard assessment.evidence.allSatisfy({ acceptedKinds.contains($0.kind) }) else {
            throw WorkflowReviewError.evidenceKindMismatch(criterion.id)
        }
        if let unknown = assessment.evidence.first(where: { !knownEvidence.contains($0) }) {
            throw WorkflowReviewError.unknownEvidence(unknown.ref)
        }
        switch assessment.outcome {
        case .pass, .fail:
            guard !assessment.evidence.isEmpty,
                  nonempty(assessment.note ?? ""),
                  assessment.notApplicableReason == nil else {
                throw WorkflowReviewError.invalidReport
            }
        case .notVerified:
            guard assessment.evidence.isEmpty,
                  nonempty(assessment.note ?? ""),
                  assessment.notApplicableReason == nil else {
                throw WorkflowReviewError.invalidReport
            }
        case .notApplicable:
            guard assessment.evidence.isEmpty,
                  assessment.note == nil,
                  nonempty(assessment.notApplicableReason ?? "") else {
                throw WorkflowReviewError.invalidReport
            }
        }
    }

    private static func knownEvidence(in state: TaskState) -> Set<WorkflowReviewEvidence> {
        var evidence = Set(state.evidence.map {
            WorkflowReviewEvidence(kind: $0.kind, ref: $0.ref)
        })
        if let check = state.lastCheck {
            evidence.insert(WorkflowReviewEvidence(kind: "revision-stamp", ref: check.stamp))
            if let receipt = check.receipt {
                evidence.insert(WorkflowReviewEvidence(
                    kind: "verification-receipt",
                    ref: receipt.id.uuidString
                ))
            }
        }
        return evidence
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
