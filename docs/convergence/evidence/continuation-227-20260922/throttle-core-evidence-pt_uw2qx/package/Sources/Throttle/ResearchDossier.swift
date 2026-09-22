import Foundation

/// The viability dossier: what research actually established about a project,
/// with the source for every claim.
///
/// The point of the shape is refusal. A finding without a source does not go in,
/// and a verdict cannot be computed while a pillar is empty — a number produced
/// from nothing looks exactly like a number produced from evidence, which is the
/// failure mode worth designing against.

enum ViabilityPillar: String, Codable, Sendable, CaseIterable {
    case feasibility        // can it be built, and what provably cannot
    case competition        // who ships it, at what price, positioned how
    case demand             // what their users complain about, in their words
    case differentiation    // what nobody in the space does yet

    var label: String {
        switch self {
        case .feasibility: return "Feasibility"
        case .competition: return "Competition"
        case .demand: return "Demand"
        case .differentiation: return "Differentiation"
        }
    }
}

struct ResearchFinding: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var pillar: ViabilityPillar
    var claim: String
    /// A URL, a file path, or a local corpus id. Required — a claim Throttle
    /// cannot let the user check is not evidence, it is an opinion.
    var source: String
    /// The agent's own reading of this pillar, 0 (hostile) to 3 (favourable).
    var rating: Int
    var recordedBy: String
    var recordedAt: Date

    init(id: String = UUID().uuidString, pillar: ViabilityPillar, claim: String,
         source: String, rating: Int, recordedBy: String, recordedAt: Date = Date()) {
        self.id = id
        self.pillar = pillar
        self.claim = claim
        self.source = source
        self.rating = min(max(rating, 0), 3)
        self.recordedBy = recordedBy
        self.recordedAt = recordedAt
    }
}

struct ResearchDossier: Codable, Sendable, Equatable {
    var schema: Int = 1
    var projectId: String
    var findings: [ResearchFinding] = []

    func findings(for pillar: ViabilityPillar) -> [ResearchFinding] {
        findings.filter { $0.pillar == pillar }
    }
}

/// A verdict, or an honest refusal to give one.
enum ViabilityAssessment: Sendable, Equatable {
    /// 0–100, plus the per-pillar averages it was built from so the number can be
    /// argued with rather than believed.
    case scored(score: Int, byPillar: [ViabilityPillar: Double], sources: Int)
    /// Which pillars have no sourced finding yet.
    case insufficientEvidence(missing: [ViabilityPillar])

    var score: Int? {
        if case .scored(let value, _, _) = self { return value }
        return nil
    }
}

enum ViabilityScorer {

    /// Every pillar weighs the same. Weighting them differently would encode a
    /// theory of what makes a product work that nothing here has established.
    static func assess(_ dossier: ResearchDossier) -> ViabilityAssessment {
        let missing = ViabilityPillar.allCases.filter { dossier.findings(for: $0).isEmpty }
        guard missing.isEmpty else { return .insufficientEvidence(missing: missing) }

        var byPillar: [ViabilityPillar: Double] = [:]
        for pillar in ViabilityPillar.allCases {
            let ratings = dossier.findings(for: pillar).map { Double($0.rating) }
            byPillar[pillar] = ratings.reduce(0, +) / Double(ratings.count)
        }
        let average = byPillar.values.reduce(0, +) / Double(byPillar.count)
        return .scored(score: Int((average / 3 * 100).rounded()),
                       byPillar: byPillar,
                       sources: Set(dossier.findings.map(\.source)).count)
    }
}
