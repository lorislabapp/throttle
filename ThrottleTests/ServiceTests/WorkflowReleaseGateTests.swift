import Foundation
import Testing
@testable import Throttle

@Suite("Workflow release gates")
struct WorkflowReleaseGateTests {
    @Test("a direct release cannot collapse build, notarization, staple, and publication proof")
    func directReleaseNeedsEveryLayer() throws {
        let manifest = makeManifest()
        let evidence = evidenceFor(manifest, gates: [
            .manifestValidated, .sourceVerified, .testsAccepted, .artifactTrusted,
            .candidateAccepted, .complianceAccepted
        ])
        let result = WorkflowReleaseGateEvaluator.evaluate(
            manifest: manifest,
            evidence: evidence,
            stage: .publish,
            targetID: "mac-direct",
            request: request()
        )
        #expect(!result.ready)
        #expect(result.blockers.contains("gate_not_passed:notarizationAccepted"))
        #expect(result.blockers.contains("gate_not_passed:stapleVerified"))
        #expect(result.blockers.contains("external_action_authorization_missing"))
    }

    @Test("evidence from a previous manifest cannot satisfy a new release")
    func staleManifestEvidenceIsRejected() throws {
        let manifest = makeManifest()
        var evidence = evidenceFor(manifest, gates: [.manifestValidated, .sourceVerified, .testsAccepted])
        evidence = evidence.map {
            var stale = $0
            stale.manifestDigest = String(repeating: "b", count: 64)
            return stale
        }
        let result = WorkflowReleaseGateEvaluator.evaluate(
            manifest: manifest,
            evidence: evidence,
            stage: .prepare
        )
        #expect(!result.ready)
        #expect(result.blockers.count == 3)
    }

    @Test("a contradictory gate is disqualified even when a passing receipt exists")
    func contradictionsBlock() throws {
        let manifest = makeManifest()
        var evidence = evidenceFor(manifest, gates: [.manifestValidated, .sourceVerified, .testsAccepted])
        var contradiction = evidence[0]
        contradiction.id = UUID()
        contradiction.outcome = .failed
        evidence.append(contradiction)
        let result = WorkflowReleaseGateEvaluator.evaluate(
            manifest: manifest,
            evidence: evidence,
            stage: .prepare
        )
        #expect(!result.ready)
        #expect(result.blockers == ["gate_contradiction:manifestValidated"])
    }

    @Test("authorization binds the exact manifest, action, target, audience, and payload")
    func contentAddressedAuthorization() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let manifest = makeManifest()
        let allGates: [WorkflowReleaseGate] = [
            .manifestValidated, .sourceVerified, .testsAccepted, .artifactTrusted,
            .notarizationAccepted, .stapleVerified, .candidateAccepted, .complianceAccepted
        ]
        let action = request()
        let authorization = WorkflowExternalActionAuthorization(
            id: UUID(),
            releaseID: manifest.releaseID,
            manifestDigest: try #require(manifest.digest),
            action: action.action,
            targetID: action.targetID,
            audience: action.audience,
            payloadDigest: action.payloadDigest,
            approvedBy: ["user:kevin"],
            issuedAt: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(600)
        )
        let accepted = WorkflowReleaseGateEvaluator.evaluate(
            manifest: manifest,
            evidence: evidenceFor(manifest, gates: allGates),
            stage: .publish,
            targetID: "mac-direct",
            request: action,
            authorization: authorization,
            now: now
        )
        #expect(accepted.ready)

        var changed = action
        changed.payloadDigest = String(repeating: "c", count: 64)
        let refused = WorkflowReleaseGateEvaluator.evaluate(
            manifest: manifest,
            evidence: evidenceFor(manifest, gates: allGates),
            stage: .publish,
            targetID: "mac-direct",
            request: changed,
            authorization: authorization,
            now: now
        )
        #expect(refused.blockers == ["authorization_payload_mismatch"])
    }

    @Test("a manifest revision must preserve an explicit digest chain")
    func manifestRevisionChain() {
        var manifest = makeManifest()
        manifest.manifestRevision = 2
        #expect(!manifest.isValid)
        manifest.previousManifestDigest = String(repeating: "d", count: 64)
        #expect(manifest.isValid)
    }

    private func makeManifest() -> WorkflowReleaseManifest {
        WorkflowReleaseManifest(
            releaseID: "throttle-3.7.0-221",
            manifestRevision: 1,
            state: .frozen,
            productID: "throttle",
            version: "3.7.0",
            buildNumber: "221",
            sourceRevision: String(repeating: "a", count: 40),
            targets: [
                WorkflowReleaseTarget(
                    id: "mac-direct",
                    platform: .macOS,
                    distribution: .developerID
                )
            ]
        )
    }

    private func request() -> WorkflowExternalActionRequest {
        WorkflowExternalActionRequest(
            action: "release.publish",
            targetID: "mac-direct",
            audience: "public",
            payloadDigest: String(repeating: "e", count: 64)
        )
    }

    private func evidenceFor(
        _ manifest: WorkflowReleaseManifest,
        gates: [WorkflowReleaseGate]
    ) -> [WorkflowReleaseGateEvidence] {
        gates.map { gate in
            WorkflowReleaseGateEvidence(
                id: UUID(),
                gate: gate,
                targetID: targetSpecific(gate) ? "mac-direct" : nil,
                outcome: .passed,
                manifestDigest: manifest.digest ?? "",
                sourceRevision: manifest.sourceRevision,
                artifactDigest: String(repeating: "f", count: 64),
                ref: "receipt://\(gate.rawValue)",
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        }
    }

    private func targetSpecific(_ gate: WorkflowReleaseGate) -> Bool {
        ![
            .manifestValidated, .sourceVerified, .testsAccepted, .complianceAccepted, .releaseClosed
        ].contains(gate)
    }
}
