import CryptoKit
import Foundation
import ResearchVaultModel

// The engine keeps its public data model and evaluator together so the
// deterministic semantics can be audited in one source unit.
// swiftlint:disable file_length

public enum ResearchTerm: Codable, Hashable, Sendable {
    case constant(String)
    case variable(String)
}

public struct ResearchAtom: Codable, Hashable, Sendable {
    public let predicate: String
    public let terms: [ResearchTerm]

    public init(predicate: String, terms: [ResearchTerm]) {
        self.predicate = predicate
        self.terms = terms
    }
}

public struct ResearchRule: Codable, Hashable, Sendable {
    public let id: String
    public let head: ResearchAtom
    public let body: [ResearchAtom]

    public init(id: String, head: ResearchAtom, body: [ResearchAtom]) {
        self.id = id
        self.head = head
        self.body = body
    }
}

public struct ResearchFactEvidence: Codable, Hashable, Sendable, Comparable {
    public let receiptID: String
    public let sourceID: String

    public init(receiptID: String, sourceID: String) {
        self.receiptID = receiptID
        self.sourceID = sourceID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.receiptID != rhs.receiptID { return lhs.receiptID < rhs.receiptID }
        return lhs.sourceID < rhs.sourceID
    }
}

public struct ResearchFact: Codable, Hashable, Sendable {
    public let id: String
    public let predicate: String
    public let arguments: [String]
    public let projectKey: String
    public let sensitivity: ResearchSensitivity
    public let validFrom: Date?
    public let validUntil: Date?
    public let assertedAt: Date
    public let evidence: [ResearchFactEvidence]

    public var evidenceIDs: [String] { Array(Set(evidence.map(\.sourceID))).sorted() }
    public var sourceReceiptIDs: [String] { Array(Set(evidence.map(\.receiptID))).sorted() }

    public init(
        predicate: String,
        arguments: [String],
        projectKey: String,
        sensitivity: ResearchSensitivity,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        assertedAt: Date,
        evidence: [ResearchFactEvidence] = []
    ) {
        self.predicate = predicate
        self.arguments = arguments
        self.projectKey = projectKey
        self.sensitivity = sensitivity
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.assertedAt = assertedAt
        self.evidence = Array(Set(evidence)).sorted()
        self.id = Self.makeID(
            predicate: predicate,
            arguments: arguments,
            projectKey: projectKey,
            validFrom: validFrom,
            validUntil: validUntil
        )
    }

    fileprivate static func makeID(
        predicate: String,
        arguments: [String],
        projectKey: String,
        validFrom: Date?,
        validUntil: Date?
    ) -> String {
        func instant(_ date: Date?) -> String {
            date.map { String($0.timeIntervalSince1970.bitPattern, radix: 16) } ?? "-"
        }
        let fields = [projectKey, predicate] + arguments + [instant(validFrom), instant(validUntil)]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum ResearchReasoningValidationError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidFactID(String)
    case duplicateRuleID(String)
    case emptyRuleBody(String)
    case unsafeHeadVariable(ruleID: String, variable: String)
    case inconsistentArity(predicate: String)
    case predicateRoleConflict(String)
    case invalidValidityInterval(factID: String)
    case resourceLimitExceeded(String)
    case unknownFact(String)
}

public struct ResearchReasoningLimits: Codable, Equatable, Sendable {
    public var maximumBaseFacts: Int
    public var maximumRules: Int
    public var maximumDerivedFacts: Int
    public var maximumIterations: Int
    public var maximumDerivations: Int
    public var maximumProofNodes: Int
    public var maximumProofDepth: Int
    public var maximumRuleBodyAtoms: Int
    public var maximumTermsPerAtom: Int

    public init(
        maximumBaseFacts: Int = 10_000,
        maximumRules: Int = 1_000,
        maximumDerivedFacts: Int = 50_000,
        maximumIterations: Int = 128,
        maximumDerivations: Int = 200_000,
        maximumProofNodes: Int = 2_000,
        maximumProofDepth: Int = 64,
        maximumRuleBodyAtoms: Int = 32,
        maximumTermsPerAtom: Int = 16
    ) {
        self.maximumBaseFacts = maximumBaseFacts
        self.maximumRules = maximumRules
        self.maximumDerivedFacts = maximumDerivedFacts
        self.maximumIterations = maximumIterations
        self.maximumDerivations = maximumDerivations
        self.maximumProofNodes = maximumProofNodes
        self.maximumProofDepth = maximumProofDepth
        self.maximumRuleBodyAtoms = maximumRuleBodyAtoms
        self.maximumTermsPerAtom = maximumTermsPerAtom
    }
}

public struct ResearchDerivation: Codable, Hashable, Sendable {
    public let conclusionFactID: String
    public let ruleID: String
    public let premiseFactIDs: [String]

    public init(conclusionFactID: String, ruleID: String, premiseFactIDs: [String]) {
        self.conclusionFactID = conclusionFactID
        self.ruleID = ruleID
        self.premiseFactIDs = premiseFactIDs
    }
}

public struct ResearchReasoningSnapshot: Sendable {
    public let facts: [ResearchFact]
    public let baseFactIDs: Set<String>
    public let derivations: [ResearchDerivation]
    public let iterations: Int
    public let baseFacts: [ResearchFact]
    public let rules: [ResearchRule]

    public func fact(id: String) -> ResearchFact? {
        facts.first { $0.id == id }
    }

    public func facts(predicate: String, projectKey: String? = nil) -> [ResearchFact] {
        facts.filter { fact in
            fact.predicate == predicate && (projectKey == nil || fact.projectKey == projectKey)
        }
    }
}

public struct ResearchProof: Sendable, Equatable {
    public let rootFactID: String
    public let facts: [ResearchFact]
    public let derivations: [ResearchDerivation]
    public let truncated: Bool
}

public struct ResearchReasoningDelta: Sendable, Equatable {
    public let removedFactIDs: [String]
    public let addedFactIDs: [String]
    public let updatedFactIDs: [String]
}

public struct ResearchRebuildResult: Sendable {
    public let snapshot: ResearchReasoningSnapshot
    public let delta: ResearchReasoningDelta
}

// swiftlint:disable:next type_body_length
public struct ResearchReasoningEngine: Sendable {
    public let limits: ResearchReasoningLimits

    public init(limits: ResearchReasoningLimits = .init()) {
        self.limits = limits
    }

    // Fixed-point evaluation is intentionally linear here; splitting the loop
    // would obscure its bounded termination and cancellation checks.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func evaluate(
        baseFacts: [ResearchFact],
        rules: [ResearchRule]
    ) throws -> ResearchReasoningSnapshot {
        try Task<Never, Never>.checkCancellation()
        guard baseFacts.count <= limits.maximumBaseFacts else {
            throw ResearchReasoningValidationError.resourceLimitExceeded("baseFacts")
        }
        guard rules.count <= limits.maximumRules else {
            throw ResearchReasoningValidationError.resourceLimitExceeded("rules")
        }
        try validate(baseFacts: baseFacts, rules: rules)

        var factsByID: [String: ResearchFact] = [:]
        for (index, fact) in baseFacts.sorted(by: Self.factOrder).enumerated() {
            if index.isMultiple(of: 256) { try Task<Never, Never>.checkCancellation() }
            factsByID[fact.id] = merge(factsByID[fact.id], fact)
        }
        let baseFactIDs = Set(factsByID.keys)
        var derivationSet = Set<ResearchDerivation>()
        var iterations = 0

        while true {
            try Task<Never, Never>.checkCancellation()
            guard iterations < limits.maximumIterations else {
                throw ResearchReasoningValidationError.resourceLimitExceeded("iterations")
            }
            iterations += 1
            var changed = false
            let available = factsByID.values.sorted(by: Self.factOrder)

            for rule in rules.sorted(by: { $0.id < $1.id }) {
                for match in try matches(rule: rule, facts: available) {
                    guard let derived = derive(rule: rule, match: match) else { continue }
                    let withinDerivedLimit = factsByID.count - baseFactIDs.count < limits.maximumDerivedFacts
                    guard baseFactIDs.contains(derived.id)
                            || withinDerivedLimit
                            || factsByID[derived.id] != nil else {
                        throw ResearchReasoningValidationError.resourceLimitExceeded("derivedFacts")
                    }
                    let merged = merge(factsByID[derived.id], derived)
                    if factsByID[derived.id] != merged {
                        factsByID[derived.id] = merged
                        changed = true
                    }
                    let derivation = ResearchDerivation(
                        conclusionFactID: derived.id,
                        ruleID: rule.id,
                        premiseFactIDs: match.premises.map(\.id)
                    )
                    derivationSet.insert(derivation)
                    guard derivationSet.count <= limits.maximumDerivations else {
                        throw ResearchReasoningValidationError.resourceLimitExceeded("derivations")
                    }
                }
            }
            if !changed { break }
        }

        return ResearchReasoningSnapshot(
            facts: factsByID.values.sorted(by: Self.factOrder),
            baseFactIDs: baseFactIDs,
            derivations: derivationSet.sorted(by: Self.derivationOrder),
            iterations: iterations,
            baseFacts: baseFacts,
            rules: rules
        )
    }

    public func why(factID: String, in snapshot: ResearchReasoningSnapshot) throws -> ResearchProof {
        guard snapshot.fact(id: factID) != nil else {
            throw ResearchReasoningValidationError.unknownFact(factID)
        }
        let derivationsByConclusion = Dictionary(grouping: snapshot.derivations, by: \.conclusionFactID)
        let factsByID = Dictionary(uniqueKeysWithValues: snapshot.facts.map { ($0.id, $0) })
        var visited = Set<String>()
        var includedDerivations = Set<ResearchDerivation>()
        var truncated = false

        func visit(_ currentID: String, depth: Int) {
            guard depth <= limits.maximumProofDepth, visited.count < limits.maximumProofNodes else {
                truncated = true
                return
            }
            guard visited.insert(currentID).inserted else { return }
            for derivation in derivationsByConclusion[currentID, default: []] {
                guard includedDerivations.count < limits.maximumProofNodes else {
                    truncated = true
                    break
                }
                includedDerivations.insert(derivation)
                for premiseID in derivation.premiseFactIDs {
                    visit(premiseID, depth: depth + 1)
                }
            }
        }
        visit(factID, depth: 0)

        return ResearchProof(
            rootFactID: factID,
            facts: visited.compactMap { factsByID[$0] }.sorted(by: Self.factOrder),
            derivations: includedDerivations.sorted(by: Self.derivationOrder),
            truncated: truncated
        )
    }

    public func rebuild(
        _ snapshot: ResearchReasoningSnapshot,
        removingBaseFactIDs removedIDs: Set<String>
    ) throws -> ResearchRebuildResult {
        let retained = snapshot.baseFacts.filter { !removedIDs.contains($0.id) }
        let rebuilt = try evaluate(baseFacts: retained, rules: snapshot.rules)
        return ResearchRebuildResult(
            snapshot: rebuilt,
            delta: whatChanged(from: snapshot, to: rebuilt)
        )
    }

    public func whatChanged(
        from old: ResearchReasoningSnapshot,
        to new: ResearchReasoningSnapshot
    ) -> ResearchReasoningDelta {
        let oldFacts = Dictionary(uniqueKeysWithValues: old.facts.map { ($0.id, $0) })
        let newFacts = Dictionary(uniqueKeysWithValues: new.facts.map { ($0.id, $0) })
        let oldIDs = Set(oldFacts.keys)
        let newIDs = Set(newFacts.keys)
        let sharedIDs = oldIDs.intersection(newIDs)
        return ResearchReasoningDelta(
            removedFactIDs: oldIDs.subtracting(newIDs).sorted(),
            addedFactIDs: newIDs.subtracting(oldIDs).sorted(),
            updatedFactIDs: sharedIDs.filter { oldFacts[$0] != newFacts[$0] }.sorted()
        )
    }

    public func impactedFacts(
        in snapshot: ResearchReasoningSnapshot,
        removingBaseFactIDs removedIDs: Set<String>
    ) throws -> [ResearchFact] {
        let rebuilt = try rebuild(snapshot, removingBaseFactIDs: removedIDs)
        let impactedIDs = Set(rebuilt.delta.removedFactIDs + rebuilt.delta.updatedFactIDs)
        return snapshot.facts.filter { impactedIDs.contains($0.id) }.sorted(by: Self.factOrder)
    }

    // Validation deliberately reports precise fail-closed errors in one pass.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func validate(baseFacts: [ResearchFact], rules: [ResearchRule]) throws {
        var arities: [String: Int] = [:]
        for fact in baseFacts {
            guard fact.id == ResearchFact.makeID(
                predicate: fact.predicate,
                arguments: fact.arguments,
                projectKey: fact.projectKey,
                validFrom: fact.validFrom,
                validUntil: fact.validUntil
            ) else {
                throw ResearchReasoningValidationError.invalidFactID(fact.id)
            }
            try validateIdentifier(fact.predicate)
            guard fact.projectKey.range(
                of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
                options: .regularExpression
            ) != nil else {
                throw ResearchReasoningValidationError.invalidIdentifier(fact.projectKey)
            }
            for argument in fact.arguments {
                guard !argument.isEmpty, argument.utf8.count <= 4_096 else {
                    throw ResearchReasoningValidationError.invalidIdentifier(argument)
                }
            }
            guard fact.arguments.count <= limits.maximumTermsPerAtom else {
                throw ResearchReasoningValidationError.resourceLimitExceeded("termsPerAtom")
            }
            guard Self.hasValidInterval(from: fact.validFrom, until: fact.validUntil) else {
                throw ResearchReasoningValidationError.invalidValidityInterval(factID: fact.id)
            }
            try registerArity(predicate: fact.predicate, arity: fact.arguments.count, into: &arities)
        }
        var ruleIDs = Set<String>()
        let basePredicates = Set(baseFacts.map(\.predicate))
        for rule in rules {
            try validateIdentifier(rule.id)
            guard ruleIDs.insert(rule.id).inserted else {
                throw ResearchReasoningValidationError.duplicateRuleID(rule.id)
            }
            guard !rule.body.isEmpty else {
                throw ResearchReasoningValidationError.emptyRuleBody(rule.id)
            }
            guard !basePredicates.contains(rule.head.predicate) else {
                throw ResearchReasoningValidationError.predicateRoleConflict(rule.head.predicate)
            }
            guard rule.body.count <= limits.maximumRuleBodyAtoms else {
                throw ResearchReasoningValidationError.resourceLimitExceeded("ruleBodyAtoms")
            }
            let bound = Set(rule.body.flatMap(\.terms).compactMap { term -> String? in
                guard case let .variable(name) = term else { return nil }
                return name
            })
            for atom in [rule.head] + rule.body {
                try validateIdentifier(atom.predicate)
                guard atom.terms.count <= limits.maximumTermsPerAtom else {
                    throw ResearchReasoningValidationError.resourceLimitExceeded("termsPerAtom")
                }
                try registerArity(predicate: atom.predicate, arity: atom.terms.count, into: &arities)
                for term in atom.terms {
                    switch term {
                    case let .variable(name): try validateIdentifier(name)
                    case let .constant(value):
                        guard !value.isEmpty, value.utf8.count <= 4_096 else {
                            throw ResearchReasoningValidationError.invalidIdentifier(value)
                        }
                    }
                }
            }
            for case let .variable(variable) in rule.head.terms where !bound.contains(variable) {
                throw ResearchReasoningValidationError.unsafeHeadVariable(ruleID: rule.id, variable: variable)
            }
        }
    }

    private func validateIdentifier(_ value: String) throws {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw ResearchReasoningValidationError.invalidIdentifier(value)
        }
    }

    private func registerArity(predicate: String, arity: Int, into arities: inout [String: Int]) throws {
        if let existing = arities[predicate], existing != arity {
            throw ResearchReasoningValidationError.inconsistentArity(predicate: predicate)
        }
        arities[predicate] = arity
    }

    private struct Match {
        var bindings: [String: String]
        var premises: [ResearchFact]
    }

    // The bounded join loop is kept explicit to make cardinality checks visible.
    // swiftlint:disable:next cyclomatic_complexity
    private func matches(rule: ResearchRule, facts: [ResearchFact]) throws -> [Match] {
        var partials = [Match(bindings: [:], premises: [])]
        for atom in rule.body {
            var next: [Match] = []
            let candidates = facts.filter { $0.predicate == atom.predicate && $0.arguments.count == atom.terms.count }
            for partial in partials {
                for (index, candidate) in candidates.enumerated() {
                    if index.isMultiple(of: 256) { try Task<Never, Never>.checkCancellation() }
                    if let project = partial.premises.first?.projectKey, project != candidate.projectKey { continue }
                    var bindings = partial.bindings
                    var compatible = true
                    for (term, value) in zip(atom.terms, candidate.arguments) {
                        switch term {
                        case let .constant(constant): compatible = compatible && constant == value
                        case let .variable(variable):
                            if let bound = bindings[variable] {
                                compatible = compatible && bound == value
                            } else {
                                bindings[variable] = value
                            }
                        }
                    }
                    if compatible {
                        next.append(Match(bindings: bindings, premises: partial.premises + [candidate]))
                        guard next.count <= limits.maximumDerivations else {
                            throw ResearchReasoningValidationError.resourceLimitExceeded("matches")
                        }
                    }
                }
            }
            partials = next
        }
        return partials
    }

    private func derive(rule: ResearchRule, match: Match) -> ResearchFact? {
        guard let first = match.premises.first else { return nil }
        let arguments = rule.head.terms.compactMap { term -> String? in
            switch term {
            case let .constant(value): value
            case let .variable(name): match.bindings[name]
            }
        }
        guard arguments.count == rule.head.terms.count else { return nil }
        let from = match.premises.compactMap(\.validFrom).max()
        let until = match.premises.compactMap(\.validUntil).min()
        if let from, let until, from > until { return nil }
        return ResearchFact(
            predicate: rule.head.predicate,
            arguments: arguments,
            projectKey: first.projectKey,
            sensitivity: match.premises.map(\.sensitivity).max() ?? first.sensitivity,
            validFrom: from,
            validUntil: until,
            assertedAt: match.premises.map(\.assertedAt).max() ?? first.assertedAt,
            evidence: match.premises.flatMap(\.evidence)
        )
    }

    private func merge(_ old: ResearchFact?, _ new: ResearchFact) -> ResearchFact {
        guard let old else { return new }
        return ResearchFact(
            predicate: new.predicate,
            arguments: new.arguments,
            projectKey: new.projectKey,
            sensitivity: max(old.sensitivity, new.sensitivity),
            validFrom: new.validFrom,
            validUntil: new.validUntil,
            assertedAt: max(old.assertedAt, new.assertedAt),
            evidence: old.evidence + new.evidence
        )
    }

    private static func factOrder(_ lhs: ResearchFact, _ rhs: ResearchFact) -> Bool {
        let left = [lhs.projectKey, lhs.predicate] + lhs.arguments + [lhs.id]
        let right = [rhs.projectKey, rhs.predicate] + rhs.arguments + [rhs.id]
        return left.lexicographicallyPrecedes(right)
    }

    private static func derivationOrder(_ lhs: ResearchDerivation, _ rhs: ResearchDerivation) -> Bool {
        let left = [lhs.conclusionFactID, lhs.ruleID] + lhs.premiseFactIDs
        let right = [rhs.conclusionFactID, rhs.ruleID] + rhs.premiseFactIDs
        return left.lexicographicallyPrecedes(right)
    }

    private static func hasValidInterval(from: Date?, until: Date?) -> Bool {
        guard let from, let until else { return true }
        return from <= until
    }
}

// swiftlint:enable file_length
