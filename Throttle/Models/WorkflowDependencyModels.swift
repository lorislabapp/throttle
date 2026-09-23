import Foundation

enum WorkflowDependencyDecision: String, Codable, Sendable {
    case adopt, adapt, wrap, fork, buildOurOwn
}

enum WorkflowDependencySourceFamily: String, Codable, Sendable, CaseIterable {
    case nativeAPI, swiftPackage, sourceLibrary, commercialSDK, commandLineTool, service
}

enum WorkflowDependencyGate: String, Codable, Sendable, CaseIterable {
    case functionalConformance
    case correctness
    case requiredPlatforms
    case licensePolicy
    case securityPolicy
    case privacyPolicy
    case artifactTrust
    case performanceBudget
}

enum WorkflowDependencyDimension: String, Codable, Sendable, CaseIterable {
    case functionalFit
    case integrationDesign
    case performance
    case memory
    case binaryFootprint
    case concurrency
    case platformCompatibility
    case maintenance
    case community
    case engineeringQuality
    case security
    case license
    case dependencyFootprint

    var weight: Int {
        switch self {
        case .functionalFit: 18
        case .integrationDesign: 9
        case .performance: 8
        case .memory: 5
        case .binaryFootprint: 5
        case .concurrency: 5
        case .platformCompatibility: 11
        case .maintenance: 8
        case .community: 7
        case .engineeringQuality: 5
        case .security: 9
        case .license: 5
        case .dependencyFootprint: 5
        }
    }
}

struct WorkflowDependencyGateAssessment: Codable, Sendable, Equatable {
    var gate: WorkflowDependencyGate
    var outcome: WorkflowGateOutcome
    var evidenceRefs: [String]

    var isValid: Bool {
        !evidenceRefs.isEmpty
            && evidenceRefs.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct WorkflowDependencyDimensionAssessment: Codable, Sendable, Equatable {
    var dimension: WorkflowDependencyDimension
    /// Nil means unknown. It contributes neither points nor evidence coverage.
    var grade: Int?
    var evidenceRefs: [String]

    var isMeasured: Bool {
        grade.map { (0...5).contains($0) } == true
            && !evidenceRefs.isEmpty
            && evidenceRefs.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isValid: Bool {
        if let grade { return (0...5).contains(grade) && isMeasured }
        return evidenceRefs.isEmpty
    }
}

struct WorkflowDependencyAssessment: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var capabilityID: String
    var candidateID: String
    var candidateVersion: String
    var candidateRevision: String
    var applicableSourceFamilies: [WorkflowDependencySourceFamily]
    var searchedSourceFamilies: [WorkflowDependencySourceFamily]
    var distinctCandidateCount: Int
    var soleViableCandidateEvidence: String?
    var hardGates: [WorkflowDependencyGateAssessment]
    var dimensions: [WorkflowDependencyDimensionAssessment]
    var proposedDecision: WorkflowDependencyDecision
    var decisionRationale: [String]

    var score: Double {
        dimensions.reduce(0) { result, assessment in
            guard assessment.isMeasured, let grade = assessment.grade else { return result }
            return result + Double(assessment.dimension.weight * grade) / 5.0
        }
    }

    var evidenceCoverage: Int {
        dimensions.reduce(0) { result, assessment in
            result + (assessment.isMeasured ? assessment.dimension.weight : 0)
        }
    }

    var isValid: Bool {
        let gateIDs = hardGates.map(\.gate)
        let dimensions = dimensions.map(\.dimension)
        return schemaVersion == 1
            && nonempty(capabilityID)
            && nonempty(candidateID)
            && nonempty(candidateVersion)
            && isObjectID(candidateRevision)
            && !applicableSourceFamilies.isEmpty
            && Set(applicableSourceFamilies).count == applicableSourceFamilies.count
            && Set(searchedSourceFamilies).count == searchedSourceFamilies.count
            && distinctCandidateCount > 0
            && Set(gateIDs) == Set(WorkflowDependencyGate.allCases)
            && gateIDs.count == WorkflowDependencyGate.allCases.count
            && hardGates.allSatisfy(\.isValid)
            && Set(dimensions) == Set(WorkflowDependencyDimension.allCases)
            && dimensions.count == WorkflowDependencyDimension.allCases.count
            && self.dimensions.allSatisfy(\.isValid)
            && !decisionRationale.isEmpty
            && decisionRationale.allSatisfy(nonempty)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }
}

enum WorkflowDependencyVerdict: String, Codable, Sendable {
    case eligible, ineligible, needsEvidence
}

struct WorkflowDependencyEvaluation: Sendable, Equatable {
    var verdict: WorkflowDependencyVerdict
    var score: Double
    var evidenceCoverage: Int
    var blockers: [String]
}

enum WorkflowDependencyEvaluator {
    static func evaluate(
        _ assessment: WorkflowDependencyAssessment,
        minimumCoverage: Int = 85
    ) -> WorkflowDependencyEvaluation {
        guard assessment.isValid, (0...100).contains(minimumCoverage) else {
            return result(.needsEvidence, assessment, ["assessment_invalid"])
        }
        let failed = assessment.hardGates.filter { $0.outcome == .failed }.map {
            "hard_gate_failed:\($0.gate.rawValue)"
        }
        if !failed.isEmpty { return result(.ineligible, assessment, failed) }

        var blockers = assessment.hardGates.filter { $0.outcome == .notVerified }.map {
            "hard_gate_not_verified:\($0.gate.rawValue)"
        }
        let requiredFamilies = Set(assessment.applicableSourceFamilies)
        if !requiredFamilies.isSubset(of: Set(assessment.searchedSourceFamilies)) {
            blockers.append("discovery_incomplete")
        }
        let soleCandidateHasEvidence = assessment.soleViableCandidateEvidence?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if assessment.distinctCandidateCount < 3 && !soleCandidateHasEvidence {
            blockers.append("candidate_set_too_small")
        }
        if assessment.evidenceCoverage < minimumCoverage {
            blockers.append("evidence_coverage_below_\(minimumCoverage)")
        }
        if assessment.proposedDecision == .adopt, assessment.score < 85 {
            blockers.append("adopt_score_below_85")
        }
        return result(blockers.isEmpty ? .eligible : .needsEvidence, assessment, blockers)
    }

    private static func result(
        _ verdict: WorkflowDependencyVerdict,
        _ assessment: WorkflowDependencyAssessment,
        _ blockers: [String]
    ) -> WorkflowDependencyEvaluation {
        .init(
            verdict: verdict,
            score: assessment.score,
            evidenceCoverage: assessment.evidenceCoverage,
            blockers: blockers.sorted()
        )
    }
}
