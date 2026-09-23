import SwiftUI

extension PlanTreeView {
    @ViewBuilder
    func productCycleDetails(_ task: PlanTask) -> some View {
        if let cycle = task.workContract?.productCycle {
            VStack(alignment: .leading, spacing: 7) {
                section("PRODUCT CYCLE")
                if let release = cycle.releaseManifest {
                    fact("Release", "\(release.releaseID) · \(release.state.rawValue)")
                    fact("Version", "\(release.version) (\(release.buildNumber))")
                    fact("Source", String(release.sourceRevision.prefix(12)))
                    fact("Targets", release.targets.map(\.id).joined(separator: ", "))
                }
                if let dependency = cycle.dependencyAssessment {
                    let evaluation = WorkflowDependencyEvaluator.evaluate(dependency)
                    fact("Dependency", dependency.candidateID)
                    fact("Decision", dependency.proposedDecision.rawValue)
                    fact(
                        "Evidence",
                        "\(evaluation.evidenceCoverage)% · \(evaluation.verdict.rawValue)"
                    )
                }
                if let reuse = cycle.technologyReuseRequest {
                    fact("Reuse", reuse.desiredCapability)
                    fact("Mode", reuse.proposedMode.rawValue)
                    fact("Pinned", String(reuse.expectedSourceRevision.prefix(12)))
                }
                if let parity = cycle.parityAudit {
                    let audit = WorkflowParityAuditor.evaluate(parity)
                    fact("Parity", audit.releaseReady
                         ? String(localized: "ready")
                         : String(localized: "blocked"))
                    fact("Verified", "\(audit.verifiedRequired)/\(audit.totalRequired) required")
                }
                if let assessment = cycle.ipAssessment {
                    let evaluation = WorkflowIPEvaluator.evaluate(
                        assessment: assessment,
                        humanDecision: nil
                    )
                    fact("IP", assessment.proposedMode.publicLabel)
                    fact("IP gate", evaluation.verdict.rawValue)
                }
                Text("""
                These are pinned decisions and gates. Installation, upload, licensing \
                and publication remain separate effects.
                """)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
