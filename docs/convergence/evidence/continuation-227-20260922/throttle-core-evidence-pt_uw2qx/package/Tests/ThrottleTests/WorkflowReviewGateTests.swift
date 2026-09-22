@testable import Throttle
import XCTest

final class WorkflowReviewGateTests: XCTestCase {
    private let stamp = String(repeating: "a", count: 40) + "+" + String(repeating: "b", count: 40)
    private let receiptID = UUID()

    func testIndependentEvidenceBoundReportAcceptsAllBlockingCriteria() throws {
        let evaluation = try WorkflowReviewGate.evaluate(report(), task: task(), state: state())

        XCTAssertEqual(evaluation.decision, .accepted)
        XCTAssertTrue(evaluation.blockingCriterionIDs.isEmpty)
    }

    func testBlockingNotVerifiedCannotBeCompensatedByAnotherPass() throws {
        var report = report()
        report.assessments[1] = WorkflowReviewAssessment(
            criterionID: "quality",
            outcome: .notVerified,
            evidence: [],
            note: "No executable robustness evidence was supplied."
        )
        let evaluation = try WorkflowReviewGate.evaluate(report, task: task(), state: state())

        XCTAssertEqual(evaluation.decision, .rejected)
        XCTAssertEqual(evaluation.blockingCriterionIDs, ["quality"])
    }

    func testNonblockingFindingRemainsVisibleWithoutOverridingBlockingPasses() throws {
        var task = task()
        task.workContract?.reviewRubric?.criteria[1].blocking = false
        var report = report(task: task)
        report.assessments[1].outcome = .fail
        report.assessments[1].note = "A maintainability issue remains."
        let evaluation = try WorkflowReviewGate.evaluate(report, task: task, state: state())

        XCTAssertEqual(evaluation.decision, .accepted)
        XCTAssertEqual(evaluation.nonblockingFindingIDs, ["quality"])
    }

    func testReviewCannotCiteEvidenceAbsentFromTheTaskLedger() throws {
        var report = report()
        report.assessments[0].evidence[0].ref = "commit:invented"

        XCTAssertThrowsError(try WorkflowReviewGate.evaluate(report, task: task(), state: state())) {
            XCTAssertEqual($0 as? WorkflowReviewError, .unknownEvidence("commit:invented"))
        }
    }

    func testReviewOfEarlierCandidateIsStale() throws {
        var report = report()
        report.candidateStamp = "older"

        XCTAssertThrowsError(try WorkflowReviewGate.evaluate(report, task: task(), state: state())) {
            XCTAssertEqual($0 as? WorkflowReviewError, .staleCandidate)
        }
    }

    func testProducingRuntimeCannotReviewItself() throws {
        var report = report()
        report.reviewerID = "codex:judge"
        report.reviewerRuntime = "codex"

        XCTAssertThrowsError(try WorkflowReviewGate.evaluate(report, task: task(), state: state())) {
            XCTAssertEqual($0 as? WorkflowReviewError, .correlatedReviewer)
        }
    }

    func testHumanCriterionCannotBeSatisfiedByAModelLabel() throws {
        var task = task()
        task.workContract?.reviewRubric?.criteria[0].requiresHuman = true
        let report = report(task: task)

        XCTAssertThrowsError(try WorkflowReviewGate.evaluate(report, task: task, state: state())) {
            XCTAssertEqual($0 as? WorkflowReviewError, .humanReviewRequired)
        }
    }

    func testNotApplicableNeedsAReasonAndNoSyntheticEvidence() throws {
        var report = report()
        report.assessments[1] = WorkflowReviewAssessment(
            criterionID: "quality",
            outcome: .notApplicable,
            evidence: [],
            note: nil,
            notApplicableReason: nil
        )
        XCTAssertThrowsError(try WorkflowReviewGate.evaluate(report, task: task(), state: state())) {
            XCTAssertEqual($0 as? WorkflowReviewError, .invalidReport)
        }

        report.assessments[1].notApplicableReason = "No UI or user interaction changed."
        XCTAssertEqual(
            try WorkflowReviewGate.evaluate(report, task: task(), state: state()).decision,
            .accepted
        )
    }

    private func task() -> PlanTask {
        PlanTask(
            id: "T1",
            title: "Review candidate",
            sotaGate: true,
            workContract: WorkflowWorkContract(
                revision: 1,
                objective: "Preserve product intent and code quality.",
                approvedProductReference: "decision:review",
                requirements: [WorkflowRequirement(
                    id: "R1",
                    statement: "Review exact evidence",
                    acceptanceCriteria: ["Every blocking criterion is evaluated"]
                )],
                allowedChangePaths: ["Throttle/"],
                mustPreserve: ["Approved behavior"],
                exclusions: [],
                platforms: [.macOS],
                baseRevision: String(repeating: "c", count: 40),
                inputs: [],
                permissionRequirements: [],
                budget: WorkflowBudgetContract(),
                reviewRubric: WorkflowReviewRubric(
                    revision: 1,
                    id: "product-quality-v1",
                    criteria: [
                        WorkflowReviewCriterion(
                            id: "fidelity",
                            dimension: .productFidelity,
                            statement: "The candidate serves the approved objective.",
                            blocking: true,
                            acceptedEvidenceKinds: ["commit"]
                        ),
                        WorkflowReviewCriterion(
                            id: "quality",
                            dimension: .robustness,
                            statement: "The candidate has executable regression evidence.",
                            blocking: true,
                            acceptedEvidenceKinds: ["verification-receipt"]
                        )
                    ]
                )
            )
        )
    }

    private func state() -> TaskState {
        var state = TaskState()
        state.runtime = "codex"
        state.evidence = [TaskEvidence(kind: "commit", ref: "commit:candidate", timestamp: Date())]
        var receipt = WorkflowEvidenceReceipt.command(
            "verify",
            stamp: stamp,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            result: (true, true)
        )
        receipt.id = receiptID
        state.lastCheck = TaskCheck(
            passed: true,
            stamp: stamp,
            ranAt: Date(timeIntervalSince1970: 2),
            receipt: receipt
        )
        return state
    }

    private func report(task: PlanTask? = nil) -> WorkflowReviewReport {
        let reviewedTask = task ?? self.task()
        return WorkflowReviewReport(
            id: UUID(),
            taskID: reviewedTask.id,
            workContractDigest: reviewedTask.workContract?.digest ?? "",
            rubricDigest: reviewedTask.workContract?.reviewRubric?.digest ?? "",
            candidateStamp: stamp,
            producerRuntime: "codex",
            reviewerID: "claudeCode:judge",
            reviewerRuntime: "claudeCode",
            reviewerKind: .model,
            createdAt: Date(),
            assessments: [
                WorkflowReviewAssessment(
                    criterionID: "fidelity",
                    outcome: .pass,
                    evidence: [WorkflowReviewEvidence(kind: "commit", ref: "commit:candidate")],
                    note: "The diff implements the approved objective."
                ),
                WorkflowReviewAssessment(
                    criterionID: "quality",
                    outcome: .pass,
                    evidence: [WorkflowReviewEvidence(
                        kind: "verification-receipt",
                        ref: receiptID.uuidString
                    )],
                    note: "The required regression evidence passed."
                )
            ]
        )
    }
}
