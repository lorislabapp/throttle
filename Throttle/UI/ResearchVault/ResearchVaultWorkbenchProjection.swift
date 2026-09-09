import Foundation
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultReasoning

struct ResearchVaultSpace: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case portfolio, project }

    let id: String
    var name: String
    let kind: Kind
    var projectKeys: [String]

    static let portfolio = ResearchVaultSpace(
        id: "portfolio",
        name: "Portfolio",
        kind: .portfolio,
        projectKeys: []
    )
}

enum ResearchVaultSpaceStore {
    private static let key = "researchVault.spaces.v1"

    static func load(
        projectKeys: Set<String> = [],
        defaults: UserDefaults = .standard
    ) -> [ResearchVaultSpace] {
        let persisted = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([ResearchVaultSpace].self, from: $0)
        } ?? []
        let keys = projectKeys.union(persisted.flatMap(\.projectKeys))
        let projects = keys.sorted().map {
            ResearchVaultSpace(id: "project:" + $0, name: $0, kind: .project, projectKeys: [$0])
        }
        return [.portfolio] + projects
    }

    static func saveProjectKeys(
        _ projectKeys: Set<String>,
        defaults: UserDefaults = .standard
    ) throws {
        defaults.set(
            try JSONEncoder().encode(load(projectKeys: projectKeys, defaults: defaults)),
            forKey: key
        )
    }
}

struct ResearchVaultSavedView: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var query: String
    var projectKey: String?
    var evidenceStatus: ResearchEvidenceStatus?

    init(
        id: UUID = UUID(),
        name: String,
        query: String,
        projectKey: String? = nil,
        evidenceStatus: ResearchEvidenceStatus? = nil
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.projectKey = projectKey
        self.evidenceStatus = evidenceStatus
    }
}

enum ResearchVaultSavedViewStore {
    private static let key = "researchVault.savedViews.v1"
    private static let maximumViews = 32

    static func load(defaults: UserDefaults = .standard) -> [ResearchVaultSavedView] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([ResearchVaultSavedView].self, from: data)
        else { return [] }
        return Array(values.prefix(maximumViews))
    }

    static func save(
        _ values: [ResearchVaultSavedView],
        defaults: UserDefaults = .standard
    ) throws {
        let bounded = Array(values.prefix(maximumViews))
        defaults.set(try JSONEncoder().encode(bounded), forKey: key)
    }
}

struct ResearchVaultSourceRow: Identifiable, Equatable {
    /// One source can be cited by several receipts, so a row is identified by
    /// the pair. A claim navigates with the same key, built here so the two
    /// sides cannot drift apart.
    static func rowID(receiptID: String, sourceID: String) -> String {
        receiptID + "\u{0}" + sourceID
    }

    var id: String { Self.rowID(receiptID: receiptID, sourceID: source.id) }
    let receiptID: String
    let projectKey: String
    let sensitivity: ResearchSensitivity
    let source: ResearchSource
    let ageDays: Int
}

struct ResearchVaultClaimRow: Identifiable, Equatable {
    var id: String { receiptID + "\u{0}" + String(index) }
    let receiptID: String
    let index: Int
    let projectKey: String
    let claim: String
    let status: ResearchEvidenceStatus
    let evidenceIDs: [String]
    let createdAt: Date
}

struct ResearchVaultRevisionRow: Identifiable, Equatable {
    var id: String { locator }
    let locator: String
    let versions: [ResearchSource]
    let impactedClaims: [ResearchVaultClaimRow]
}

struct ResearchVaultTaxonomyAudit: Equatable {
    let projectKeys: [String]
    let sourceKinds: [ResearchSourceKind]
    let evidenceStatuses: [ResearchEvidenceStatus]
    let orphanEvidenceReferences: Int
}

enum ResearchVaultWorkbenchProjection {
    static func sources(
        receipts: [ResearchReceipt],
        now: Date = Date()
    ) -> [ResearchVaultSourceRow] {
        receipts.flatMap { receipt in
            receipt.sources.map { source in
                ResearchVaultSourceRow(
                    receiptID: receipt.receiptID,
                    projectKey: receipt.projectKey,
                    sensitivity: receipt.sensitivity,
                    source: source,
                    ageDays: max(Calendar.current.dateComponents(
                        [.day], from: source.observedAt, to: now
                    ).day ?? 0, 0)
                )
            }
        }.sorted {
            if $0.source.observedAt != $1.source.observedAt {
                return $0.source.observedAt > $1.source.observedAt
            }
            return $0.id < $1.id
        }
    }

    /// The hash each source carries today, newest observation wins. A claim
    /// made against an older hash is what the board calls drift.
    static func latestSourceHashes(receipts: [ResearchReceipt]) -> [String: String] {
        var observedAt: [String: Date] = [:]
        var hashes: [String: String] = [:]
        for receipt in receipts {
            for source in receipt.sources where (observedAt[source.id] ?? .distantPast) <= source.observedAt {
                observedAt[source.id] = source.observedAt
                hashes[source.id] = source.sha256
            }
        }
        return hashes
    }

    /// Contradictions the owner actually promoted. An unasserted candidate is
    /// not a contradiction, and a fact whose arguments do not read back as
    /// claim references is ignored rather than half-applied.
    static func promotedContradictions(
        facts: [ResearchVaultReasoningFactDTO]
    ) -> [ResearchRelationCandidate] {
        facts.compactMap { fact in
            guard fact.asserted, fact.predicate == ResearchRelationKind.contradicts.rawValue,
                  fact.arguments.count == 2,
                  let subject = ResearchClaimReference(stableID: fact.arguments[0]),
                  let object = ResearchClaimReference(stableID: fact.arguments[1]),
                  subject != object else { return nil }
            return ResearchRelationCandidate(relation: .contradicts, subject: subject, object: object)
        }
    }

    static func claims(receipts: [ResearchReceipt]) -> [ResearchVaultClaimRow] {
        receipts.flatMap { receipt in
            let findings = receipt.findings.enumerated().map { index, finding in
                ResearchVaultClaimRow(
                    receiptID: receipt.receiptID,
                    index: index,
                    projectKey: receipt.projectKey,
                    claim: finding.claim,
                    status: finding.status,
                    evidenceIDs: finding.evidenceIDs,
                    createdAt: receipt.createdAt
                )
            }
            let questions = receipt.openQuestions.enumerated().map { offset, question in
                ResearchVaultClaimRow(
                    receiptID: receipt.receiptID,
                    index: receipt.findings.count + offset,
                    projectKey: receipt.projectKey,
                    claim: question,
                    status: .open,
                    evidenceIDs: [],
                    createdAt: receipt.createdAt
                )
            }
            return findings + questions
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    static func revisions(receipts: [ResearchReceipt]) -> [ResearchVaultRevisionRow] {
        let claims = claims(receipts: receipts)
        let grouped = Dictionary(grouping: sources(receipts: receipts), by: { $0.source.locator })
        return grouped.compactMap { locator, rows in
            let versions = rows.map(\.source).sorted { $0.observedAt < $1.observedAt }
            guard Set(versions.map(\.sha256)).count > 1 else { return nil }
            let sourceIDs = Set(versions.map(\.id))
            let impacted = claims.filter { !sourceIDs.isDisjoint(with: $0.evidenceIDs) }
            return ResearchVaultRevisionRow(
                locator: locator,
                versions: versions,
                impactedClaims: impacted
            )
        }.sorted { $0.locator < $1.locator }
    }

    static func taxonomyAudit(receipts: [ResearchReceipt]) -> ResearchVaultTaxonomyAudit {
        let allSources = receipts.flatMap(\.sources)
        let sourceIDsByReceipt = Dictionary(uniqueKeysWithValues: receipts.map {
            ($0.receiptID, Set($0.sources.map(\.id)))
        })
        let allClaims = claims(receipts: receipts)
        let orphanCount = allClaims.reduce(into: 0) { total, claim in
            let known = sourceIDsByReceipt[claim.receiptID] ?? []
            total += claim.evidenceIDs.filter { !known.contains($0) }.count
        }
        return ResearchVaultTaxonomyAudit(
            projectKeys: Array(Set(receipts.map(\.projectKey))).sorted(),
            sourceKinds: Array(Set(allSources.map(\.kind))).sorted { $0.rawValue < $1.rawValue },
            evidenceStatuses: Array(Set(allClaims.map(\.status))).sorted { $0.rawValue < $1.rawValue },
            orphanEvidenceReferences: orphanCount
        )
    }
}
