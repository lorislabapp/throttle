import Foundation
import ResearchVaultModel
import ResearchVaultReasoning

@_spi(ReasoningPersistence)
public enum SQLCipherReasoningError: Error, Equatable, Sendable {
    case authorizationDenied
    case projectMismatch
    case evidenceRequired(String)
    case unapprovedEvidence(receiptID: String, sourceID: String)
    case invalidRulePackHash
    case invalidEngineVersion
    case baseGenerationMismatch(expected: Int64, actual: Int64)
    case baseSnapshotMismatch
    case corruptPayload
}

@_spi(ReasoningPersistence)
public struct SQLCipherReasoningCache: Sendable, Equatable {
    public let baseGeneration: Int64
    public let rulePackHash: String
    public let engineVersion: String
    public let baseFacts: [ResearchFact]
    public let derivedFacts: [ResearchFact]
    public let rules: [ResearchRule]
    public let derivations: [ResearchDerivation]
}

@_spi(ReasoningPersistence)
public extension SQLCipherReceiptStore {
    // Transaction kept cohesive so evidence validation and cache invalidation
    // cannot be called independently by mistake.
    // swiftlint:disable:next function_body_length
    func replaceReasoningBaseFacts(
        _ facts: [ResearchFact],
        forProject projectKey: String,
        authorization: VaultAuthorization
    ) throws -> Int64 {
        guard facts.allSatisfy({ $0.projectKey == projectKey }) else {
            throw SQLCipherReasoningError.projectMismatch
        }
        guard facts.allSatisfy({ authorization.permits(
            projectKey: $0.projectKey,
            sensitivity: $0.sensitivity
        ) }) else {
            throw SQLCipherReasoningError.authorizationDenied
        }
        _ = try ResearchReasoningEngine().evaluate(baseFacts: facts, rules: [])
        for fact in facts {
            guard !fact.evidence.isEmpty else {
                throw SQLCipherReasoningError.evidenceRequired(fact.id)
            }
            for evidence in fact.evidence {
                let approved = try connection.scalarInteger(
                    """
                    SELECT count(*)
                    FROM sources s JOIN receipts r ON r.receipt_id = s.receipt_id
                    WHERE s.receipt_id = ?1 AND s.source_id = ?2
                      AND r.review_state = 'approved'
                      AND r.project_key = ?3
                      AND r.sensitivity_rank <= ?4;
                    """,
                    binds: [
                        .text(evidence.receiptID), .text(evidence.sourceID),
                        .text(fact.projectKey), .integer(Int64(fact.sensitivity.policyRank))
                    ]
                ) == 1
                guard approved else {
                    throw SQLCipherReasoningError.unapprovedEvidence(
                        receiptID: evidence.receiptID,
                        sourceID: evidence.sourceID
                    )
                }
            }
        }

        let encoder = Self.reasoningEncoder()
        return try connection.transaction {
            try connection.execute(
                "DELETE FROM reasoning_base_facts WHERE project_key = ?1;",
                binds: [.text(projectKey)]
            )
            for fact in facts.sorted(by: { $0.id < $1.id }) {
                try connection.execute(
                    """
                    INSERT INTO reasoning_base_facts(
                        fact_id, project_key, predicate, sensitivity_rank, payload
                    ) VALUES (?1, ?2, ?3, ?4, ?5);
                    """,
                    binds: [
                        .text(fact.id), .text(fact.projectKey), .text(fact.predicate),
                        .integer(Int64(fact.sensitivity.policyRank)),
                        .blob(try encoder.encode(fact))
                    ]
                )
                for evidence in fact.evidence {
                    try connection.execute(
                        "INSERT INTO reasoning_fact_evidence(fact_id, receipt_id, source_id) VALUES (?1, ?2, ?3);",
                        binds: [.text(fact.id), .text(evidence.receiptID), .text(evidence.sourceID)]
                    )
                }
            }
            try connection.execute("DELETE FROM reasoning_derived_cache;")
            try connection.execute(
                """
                UPDATE reasoning_generations
                SET base_generation = base_generation + 1,
                    rule_pack_hash = '', engine_version = '', rules_json = X'5b5d'
                WHERE name = 'active';
                """
            )
            guard let generation = try connection.scalarInteger(
                "SELECT base_generation FROM reasoning_generations WHERE name = 'active';"
            ) else { throw SQLCipherReasoningError.corruptPayload }
            return generation
        }
    }

    // Cache replacement is one atomic write boundary by design.
    // swiftlint:disable:next function_body_length
    func persistReasoningCache(
        _ snapshot: ResearchReasoningSnapshot,
        baseGeneration: Int64,
        rulePackHash: String,
        engineVersion: String
    ) throws {
        guard rulePackHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw SQLCipherReasoningError.invalidRulePackHash
        }
        guard engineVersion.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else { throw SQLCipherReasoningError.invalidEngineVersion }

        let actualGeneration = try activeReasoningGeneration()
        guard actualGeneration == baseGeneration else {
            throw SQLCipherReasoningError.baseGenerationMismatch(
                expected: baseGeneration,
                actual: actualGeneration
            )
        }
        let storedBase = try loadReasoningFacts(table: "reasoning_base_facts")
        let snapshotBase = snapshot.facts
            .filter { snapshot.baseFactIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        guard storedBase == snapshotBase else {
            throw SQLCipherReasoningError.baseSnapshotMismatch
        }

        let encoder = Self.reasoningEncoder()
        let derived = snapshot.facts.filter { !snapshot.baseFactIDs.contains($0.id) }
        let derivedIDs = Set(derived.map(\.id))
        try connection.transaction {
            try connection.execute("DELETE FROM reasoning_derived_cache;")
            for fact in derived {
                try connection.execute(
                    """
                    INSERT INTO reasoning_derived_cache(
                        fact_id, project_key, sensitivity_rank, base_generation,
                        rule_pack_hash, engine_version, payload
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
                    """,
                    binds: [
                        .text(fact.id), .text(fact.projectKey),
                        .integer(Int64(fact.sensitivity.policyRank)), .integer(baseGeneration),
                        .text(rulePackHash), .text(engineVersion), .blob(try encoder.encode(fact))
                    ]
                )
            }
            for derivation in snapshot.derivations where derivedIDs.contains(derivation.conclusionFactID) {
                try connection.execute(
                    """
                    INSERT INTO reasoning_derivations(
                        conclusion_fact_id, rule_id, premise_fact_ids_json
                    ) VALUES (?1, ?2, ?3);
                    """,
                    binds: [
                        .text(derivation.conclusionFactID), .text(derivation.ruleID),
                        .blob(try encoder.encode(derivation.premiseFactIDs))
                    ]
                )
            }
            try connection.execute(
                """
                UPDATE reasoning_generations
                SET rule_pack_hash = ?1, engine_version = ?2, rules_json = ?3
                WHERE name = 'active' AND base_generation = ?4;
                """,
                binds: [
                    .text(rulePackHash), .text(engineVersion),
                    .blob(try encoder.encode(snapshot.rules)), .integer(baseGeneration)
                ]
            )
        }
    }

    // Validation and fail-closed cache invalidation share one read boundary.
    // swiftlint:disable:next function_body_length
    func loadReasoningCache(
        rulePackHash: String,
        engineVersion: String
    ) throws -> SQLCipherReasoningCache? {
        let rows = try connection.rows(
            """
            SELECT base_generation, rule_pack_hash, engine_version, rules_json
            FROM reasoning_generations WHERE name = 'active';
            """
        )
        guard let row = rows.first,
              row.count == 4,
              case let .integer(generation) = row[0],
              case let .text(storedHash) = row[1],
              case let .text(storedVersion) = row[2],
              case let .blob(rulesData) = row[3] else {
            throw SQLCipherReasoningError.corruptPayload
        }
        guard storedHash == rulePackHash, storedVersion == engineVersion else {
            try connection.transaction {
                try connection.execute("DELETE FROM reasoning_derived_cache;")
                try connection.execute(
                    """
                    UPDATE reasoning_generations
                    SET rule_pack_hash = '', engine_version = '', rules_json = X'5b5d'
                    WHERE name = 'active';
                    """
                )
            }
            return nil
        }
        let decoder = Self.reasoningDecoder()
        let rules = try decoder.decode([ResearchRule].self, from: rulesData)
        let baseFacts = try loadReasoningFacts(table: "reasoning_base_facts")
        let derivedFacts = try loadReasoningFacts(table: "reasoning_derived_cache")
        let derivationRows = try connection.rows(
            """
            SELECT conclusion_fact_id, rule_id, premise_fact_ids_json
            FROM reasoning_derivations
            ORDER BY conclusion_fact_id, rule_id, premise_fact_ids_json;
            """
        )
        let derivations = try derivationRows.map { row -> ResearchDerivation in
            guard row.count == 3,
                  case let .text(conclusion) = row[0],
                  case let .text(ruleID) = row[1],
                  case let .blob(premisesData) = row[2] else {
                throw SQLCipherReasoningError.corruptPayload
            }
            return ResearchDerivation(
                conclusionFactID: conclusion,
                ruleID: ruleID,
                premiseFactIDs: try decoder.decode([String].self, from: premisesData)
            )
        }
        return SQLCipherReasoningCache(
            baseGeneration: generation,
            rulePackHash: storedHash,
            engineVersion: storedVersion,
            baseFacts: baseFacts,
            derivedFacts: derivedFacts,
            rules: rules,
            derivations: derivations
        )
    }

    func activeReasoningGeneration() throws -> Int64 {
        guard let value = try connection.scalarInteger(
            "SELECT base_generation FROM reasoning_generations WHERE name = 'active';"
        ) else { throw SQLCipherReasoningError.corruptPayload }
        return value
    }

    /// Reads asserted reasoning state independently of the derived-cache
    /// version. This lets owner-reviewed relations survive a rule-pack or
    /// engine upgrade while still enforcing the endpoint's immutable grant.
    func reasoningBaseFacts(authorization: VaultAuthorization) throws -> [ResearchFact] {
        let facts = try loadReasoningFacts(table: "reasoning_base_facts")
        guard facts.allSatisfy({ authorization.permits(
            projectKey: $0.projectKey,
            sensitivity: $0.sensitivity
        ) }) else {
            throw SQLCipherReasoningError.authorizationDenied
        }
        return facts
    }

    func reasoningCacheFactCount() throws -> Int {
        Int(try connection.scalarInteger("SELECT count(*) FROM reasoning_derived_cache;") ?? -1)
    }

    private func loadReasoningFacts(table: String) throws -> [ResearchFact] {
        guard table == "reasoning_base_facts" || table == "reasoning_derived_cache" else {
            throw SQLCipherReasoningError.corruptPayload
        }
        let rows = try connection.rows("SELECT payload FROM " + table + " ORDER BY fact_id;")
        let decoder = Self.reasoningDecoder()
        return try rows.map { row in
            guard let first = row.first, case let .blob(payload) = first else {
                throw SQLCipherReasoningError.corruptPayload
            }
            return try decoder.decode(ResearchFact.self, from: payload)
        }
    }

    private static func reasoningEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func reasoningDecoder() -> JSONDecoder { JSONDecoder() }
}
