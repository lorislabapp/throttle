@testable import Throttle
import XCTest

final class RedTeamCampaignStoreTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")
    private var boundary = URL(fileURLWithPath: "/")
    private var fixture = URL(fileURLWithPath: "/")
    private let campaignID = UUID()
    private let revision = String(repeating: "a", count: 40)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("red-team-store-\(UUID().uuidString)", isDirectory: true)
        boundary = root.appendingPathComponent("sandbox", isDirectory: true)
        fixture = boundary.appendingPathComponent("synthetic-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCampaignRefusesTargetsOutsideTheSyntheticBoundary() throws {
        let store = RedTeamCampaignStore(projectRoot: root, allowedSandboxRoot: boundary)
        var outside = campaign()
        outside.targetRoot = root.path
        XCTAssertThrowsError(try store.bootstrap(outside)) {
            XCTAssertEqual($0 as? RedTeamCampaignError, .unsafeCampaign)
        }
        XCTAssertEqual(campaign().networkPolicy, .denied)
    }

    func testFindingNeedsTriageAndAnIndependentRetestBeforeDelivery() throws {
        let store = try configuredStore()
        let finding = try store.observe(
            campaignID: campaignID,
            observation: observation()
        )
        let triaged = try store.triage(
            campaignID: campaignID,
            findingID: finding.id,
            triage: WorkflowFindingTriage(
                severity: .high,
                justification: "Cross-task mutation breaks the task authority boundary.",
                analyst: "analyst:blue"
            )
        )
        XCTAssertEqual(triaged.status, .confirmed)

        let corrected = try store.submitRemediation(
            campaignID: campaignID,
            findingID: finding.id,
            remediation: WorkflowFindingRemediation(
                candidateRevision: String(repeating: "b", count: 40),
                taskID: "SEC-1",
                submittedBy: "corrector:one",
                submittedAt: Date(),
                evidence: [evidence("patch", "candidate.diff")]
            )
        )
        XCTAssertEqual(corrected.status, .remediationCandidate)
        XCTAssertNil(corrected.integratedRevision)
        XCTAssertNil(corrected.deliveredVersion)

        try assertIndependentRetestAndDelivery(store, findingID: finding.id)
    }

    private func assertIndependentRetestAndDelivery(
        _ store: RedTeamCampaignStore,
        findingID: UUID
    ) throws {
        XCTAssertThrowsError(try store.recordRetest(
            campaignID: campaignID,
            findingID: findingID,
            retest: retest(by: "corrector:one")
        )) {
            XCTAssertEqual($0 as? RedTeamCampaignError, .correlatedRetest)
        }

        let retested = try store.recordRetest(
            campaignID: campaignID,
            findingID: findingID,
            retest: retest(by: "retester:two")
        )
        XCTAssertEqual(retested.status, .retestPassed)
        let integrated = try store.markIntegrated(
            campaignID: campaignID,
            findingID: findingID,
            revision: String(repeating: "b", count: 40),
            by: "coordinator:app"
        )
        XCTAssertEqual(integrated.status, .integrated)
        let delivered = try store.markDelivered(
            campaignID: campaignID,
            findingID: findingID,
            version: "3.8.0",
            by: "coordinator:release"
        )
        XCTAssertEqual(delivered.status, .delivered)
    }

    func testDuplicateObservationKeepsOneFindingAndPrivateStorage() throws {
        let store = try configuredStore()
        let first = try observation(store)
        let second = try observation(store)
        XCTAssertEqual(first.id, second.id)

        let snapshot = try store.snapshot(campaignID)
        XCTAssertEqual(snapshot.findings.count, 1)
        let url = root.appendingPathComponent(
            ".throttle/red-team/campaigns/\(campaignID.uuidString).json"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    private func configuredStore() throws -> RedTeamCampaignStore {
        let store = RedTeamCampaignStore(projectRoot: root, allowedSandboxRoot: boundary)
        try store.bootstrap(campaign())
        return store
    }

    private func observation(_ store: RedTeamCampaignStore) throws -> WorkflowSecurityFinding {
        try store.observe(campaignID: campaignID, observation: observation())
    }

    private func observation() -> WorkflowFindingObservation {
        WorkflowFindingObservation(
            scenarioID: "cross-task-grant",
            component: "PlanMCPAuthority",
            preconditions: ["valid grant for T1", "request names T2"],
            evidence: [evidence("fixture-output", "cross-task-refused.txt")],
            impact: "A broad grant could mutate another task.",
            challenger: "challenger:red"
        )
    }

    private func retest(by actor: String) -> WorkflowFindingRetest {
        WorkflowFindingRetest(
            passed: true,
            regressionID: "PlanMCPAuthorityTests/testTaskBound",
            testedBy: actor,
            testedAt: Date(),
            candidateRevision: String(repeating: "b", count: 40),
            evidence: [evidence("test-result", "retest.xml")]
        )
    }

    private func campaign() -> RedTeamCampaign {
        RedTeamCampaign(
            id: campaignID,
            targetComponent: "PlanMCPAuthority",
            targetRevision: revision,
            targetRoot: fixture.path,
            fixtureRoot: fixture.path,
            scenarioIDs: ["cross-task-grant"],
            networkPolicy: .denied,
            createdAt: Date(timeIntervalSince1970: 1),
            requestedBy: "throttle:test"
        )
    }

    private func evidence(_ kind: String, _ ref: String) -> WorkflowFindingEvidence {
        WorkflowFindingEvidence(kind: kind, ref: ref)
    }
}
