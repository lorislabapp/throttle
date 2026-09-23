@testable import Throttle
import XCTest

final class WorkflowReviewMCPTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")
    private let receiptID = UUID()
    private let stamp = String(repeating: "a", count: 40) + "+" + String(repeating: "b", count: 40)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-review-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".throttle"),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Plan(projectId: "p", title: "Review", tasks: [task()])).write(
            to: root.appendingPathComponent(".throttle/plan.json"),
            options: .atomic
        )
        try prepareReviewState()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStructuredAcceptedReviewPersistsAndFinishesTask() throws {
        let text = PlanMCPTools.verdictText(PlanMCPTools.VerdictRequest(
            project: root.path,
            taskID: "T1",
            author: "claudeCode:judge",
            verdict: "verified",
            reason: nil,
            summary: "Fidelity and quality passed.",
            reviewReport: report()
        ))

        XCTAssertTrue(text.contains("done"), text)
        let state = try PlanStore(projectRoot: root).state(for: "T1")
        XCTAssertEqual(state.status, .done)
        XCTAssertEqual(state.lastReview?.id, report().id)
    }

    func testRubricTaskRefusesLegacyVerdictWithoutReport() throws {
        let text = PlanMCPTools.verdictText(PlanMCPTools.VerdictRequest(
            project: root.path,
            taskID: "T1",
            author: "claudeCode:judge",
            verdict: "verified",
            reason: nil,
            summary: "Looks good."
        ))

        XCTAssertTrue(text.contains("requires a structured"), text)
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "T1").status, .review)
    }

    func testClaimedVerdictMustMatchDeterministicCriterionDecision() throws {
        var report = report()
        report.assessments[0] = WorkflowReviewAssessment(
            criterionID: "fidelity",
            outcome: .notVerified,
            evidence: [],
            note: "The product reference was not checked."
        )
        let text = PlanMCPTools.verdictText(PlanMCPTools.VerdictRequest(
            project: root.path,
            taskID: "T1",
            author: "claudeCode:judge",
            verdict: "verified",
            reason: nil,
            summary: nil,
            reviewReport: report
        ))

        XCTAssertTrue(text.contains("require 'rejected'"), text)
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "T1").status, .review)
    }

    func testRouterDecodesTheStructuredReportObject() throws {
        let encoded = try JSONEncoder.workflow.encode(report())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var output = ""
        PlanMCPTools.routeTaskCall(
            "throttle_task_verdict",
            [
                "project": root.path,
                "task_id": "T1",
                "by": "claudeCode:judge",
                "verdict": "verified",
                "summary": "Reviewed",
                "review_report": object
            ],
            authority: .success(PlanMCPAuthority(
                projectRoots: [root], author: "claudeCode:judge", operations: [.verdict],
                taskID: "T1", missionID: UUID(), issuedAt: Date(), expiresAt: Date().addingTimeInterval(60))),
            { output = $0 },
            { output = "error:\($0)" }
        )

        XCTAssertTrue(output.contains("done"), output)
    }

    private func prepareReviewState() throws {
        let store = PlanStore(projectRoot: root)
        let workDigest = task().workContract?.digest
        try store.append(TaskEvent(
            seq: 0,
            timestamp: Date(),
            author: "codex:builder",
            type: .claimed,
            workContractDigest: workDigest
        ), to: "T1")
        try store.append(TaskEvent(
            seq: 0,
            timestamp: Date(),
            author: "codex:builder",
            type: .evidence,
            kind: "commit",
            ref: "commit:candidate"
        ), to: "T1")
        try store.append(TaskEvent(
            seq: 0,
            timestamp: Date(),
            author: "codex:builder",
            type: .candidateComplete,
            summary: "Candidate"
        ), to: "T1")
        var receipt = WorkflowEvidenceReceipt.command(
            "verify",
            stamp: stamp,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            result: (true, true)
        )
        receipt.id = receiptID
        receipt.workContractDigest = workDigest
        try store.append(TaskEvent(
            seq: 0,
            timestamp: Date(),
            author: "throttle:app",
            type: .checked,
            ref: stamp,
            passed: true,
            receipt: receipt
        ), to: "T1")
        XCTAssertEqual(try store.state(for: "T1").status, .review)
    }

    private func report() -> WorkflowReviewReport {
        let reviewedTask = task()
        return WorkflowReviewReport(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
            taskID: "T1",
            workContractDigest: reviewedTask.workContract?.digest ?? "",
            rubricDigest: reviewedTask.workContract?.reviewRubric?.digest ?? "",
            candidateStamp: stamp,
            producerRuntime: "codex",
            reviewerID: "claudeCode:judge",
            reviewerRuntime: "claudeCode",
            reviewerKind: .model,
            createdAt: Date(timeIntervalSince1970: 3),
            assessments: [
                WorkflowReviewAssessment(
                    criterionID: "fidelity",
                    outcome: .pass,
                    evidence: [WorkflowReviewEvidence(kind: "commit", ref: "commit:candidate")],
                    note: "The candidate matches the approved objective."
                ),
                WorkflowReviewAssessment(
                    criterionID: "quality",
                    outcome: .pass,
                    evidence: [WorkflowReviewEvidence(
                        kind: "verification-receipt",
                        ref: receiptID.uuidString
                    )],
                    note: "The exact verification receipt passed."
                )
            ]
        )
    }

    private func task() -> PlanTask {
        PlanTask(
            id: "T1",
            title: "Reviewed task",
            sotaGate: true,
            workContract: WorkflowWorkContract(
                revision: 1,
                objective: "Ship the approved behavior.",
                approvedProductReference: "decision:review",
                requirements: [WorkflowRequirement(
                    id: "R1",
                    statement: "Review exact evidence",
                    acceptanceCriteria: ["Fidelity and quality are explicit"]
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
                    id: "review-v1",
                    criteria: [
                        WorkflowReviewCriterion(
                            id: "fidelity",
                            dimension: .productFidelity,
                            statement: "Matches the approved objective.",
                            blocking: true,
                            acceptedEvidenceKinds: ["commit"]
                        ),
                        WorkflowReviewCriterion(
                            id: "quality",
                            dimension: .correctness,
                            statement: "Has executable evidence.",
                            blocking: true,
                            acceptedEvidenceKinds: ["verification-receipt"]
                        )
                    ]
                )
            )
        )
    }
}

private extension JSONEncoder {
    static var workflow: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
