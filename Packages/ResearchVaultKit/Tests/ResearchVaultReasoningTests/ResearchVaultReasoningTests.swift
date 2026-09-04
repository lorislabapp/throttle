import Foundation
import ResearchVaultModel
import ResearchVaultReasoning
import Testing

@Suite("Research Vault symbolic reasoning")
struct ResearchVaultReasoningTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("positive rules reach a deterministic fixed point")
    func transitiveClosure() throws {
        let engine = ResearchReasoningEngine()
        let facts = [
            fact("parent", ["ada", "bea"], evidence: "e1"),
            fact("parent", ["bea", "cy"], evidence: "e2")
        ]
        let rules = [
            rule("ancestor.base", head: atom("ancestor", [.variable("x"), .variable("y")]), body: [
                atom("parent", [.variable("x"), .variable("y")])
            ]),
            rule("ancestor.step", head: atom("ancestor", [.variable("x"), .variable("z")]), body: [
                atom("ancestor", [.variable("x"), .variable("y")]),
                atom("parent", [.variable("y"), .variable("z")])
            ])
        ]

        let first = try engine.evaluate(baseFacts: facts, rules: rules)
        let second = try engine.evaluate(baseFacts: facts.reversed(), rules: rules.reversed())
        #expect(first.facts.map(\.id) == second.facts.map(\.id))
        #expect(first.facts(predicate: "ancestor").map(\.arguments) == [
            ["ada", "bea"], ["ada", "cy"], ["bea", "cy"]
        ])
    }

    @Test("joins never cross project boundaries")
    func projectIsolation() throws {
        let facts = [
            fact("left", ["shared"], project: "alpha"),
            fact("right", ["shared"], project: "beta")
        ]
        let join = rule("join", head: atom("joined", [.variable("x")]), body: [
            atom("left", [.variable("x")]), atom("right", [.variable("x")])
        ])
        let snapshot = try ResearchReasoningEngine().evaluate(baseFacts: facts, rules: [join])
        #expect(snapshot.facts(predicate: "joined").isEmpty)
    }

    @Test("derived metadata is conservative and time intervals intersect")
    func metadataPropagation() throws {
        let start = now.addingTimeInterval(-100)
        let middle = now.addingTimeInterval(-50)
        let end = now.addingTimeInterval(100)
        let facts = [
            ResearchFact(
                predicate: "a", arguments: ["x"], projectKey: "throttle",
                sensitivity: .internal, validFrom: start, validUntil: end,
                assertedAt: start, evidence: [.init(receiptID: "r1", sourceID: "e1")]
            ),
            ResearchFact(
                predicate: "b", arguments: ["x"], projectKey: "throttle",
                sensitivity: .restricted, validFrom: middle, validUntil: nil,
                assertedAt: middle, evidence: [.init(receiptID: "r2", sourceID: "e2")]
            )
        ]
        let rule = rule("combine", head: atom("c", [.variable("x")]), body: [
            atom("a", [.variable("x")]), atom("b", [.variable("x")])
        ])
        let snapshot = try ResearchReasoningEngine().evaluate(baseFacts: facts, rules: [rule])
        let derived = try #require(snapshot.facts(predicate: "c").first)
        #expect(derived.sensitivity == .restricted)
        #expect(derived.validFrom == middle)
        #expect(derived.validUntil == end)
        #expect(derived.evidenceIDs == ["e1", "e2"])
        #expect(derived.sourceReceiptIDs == ["r1", "r2"])
    }

    @Test("alternative proofs are retained and bounded why traverses them")
    func alternativeProofs() throws {
        let seed = fact("seed", ["x"])
        let rules = [
            rule("path.a", head: atom("result", [.variable("x")]), body: [atom("seed", [.variable("x")])]),
            rule("path.b", head: atom("result", [.variable("x")]), body: [atom("seed", [.variable("x")])])
        ]
        let engine = ResearchReasoningEngine()
        let snapshot = try engine.evaluate(baseFacts: [seed], rules: rules)
        let result = try #require(snapshot.facts(predicate: "result").first)
        let proof = try engine.why(factID: result.id, in: snapshot)
        #expect(proof.facts.map(\.id).contains(seed.id))
        #expect(proof.derivations.map(\.ruleID) == ["path.a", "path.b"])
        #expect(!proof.truncated)
    }

    @Test("full rebuild retracts unsupported consequences")
    func retraction() throws {
        let firstEdge = fact("edge", ["a", "b"])
        let secondEdge = fact("edge", ["b", "c"])
        let rule = rule("path", head: atom("path", [.variable("x"), .variable("y")]), body: [
            atom("edge", [.variable("x"), .variable("y")])
        ])
        let engine = ResearchReasoningEngine()
        let initial = try engine.evaluate(baseFacts: [firstEdge, secondEdge], rules: [rule])
        let rebuilt = try engine.rebuild(initial, removingBaseFactIDs: [firstEdge.id])
        #expect(rebuilt.snapshot.facts(predicate: "path").map(\.arguments) == [["b", "c"]])
        #expect(rebuilt.delta.removedFactIDs.count == 2)
        #expect(rebuilt.delta.addedFactIDs.isEmpty)
        #expect(rebuilt.delta.updatedFactIDs.isEmpty)
        let impacted = try engine.impactedFacts(in: initial, removingBaseFactIDs: [firstEdge.id])
        #expect(Set(impacted.map(\.id)) == Set(rebuilt.delta.removedFactIDs))
    }

    @Test("what changed reports conservative metadata updates")
    func metadataChangeSet() throws {
        let publicSeed = ResearchFact(
            predicate: "seed", arguments: ["x"], projectKey: "throttle",
            sensitivity: .public, assertedAt: now,
            evidence: [.init(receiptID: "r1", sourceID: "e1")]
        )
        let restrictedSeed = ResearchFact(
            predicate: "seed", arguments: ["x"], projectKey: "throttle",
            sensitivity: .restricted, assertedAt: now,
            evidence: [.init(receiptID: "r2", sourceID: "e2")]
        )
        let rule = rule("derive", head: atom("result", [.variable("x")]), body: [atom("seed", [.variable("x")])])
        let engine = ResearchReasoningEngine()
        let before = try engine.evaluate(baseFacts: [publicSeed], rules: [rule])
        let after = try engine.evaluate(baseFacts: [publicSeed, restrictedSeed], rules: [rule])
        let delta = engine.whatChanged(from: before, to: after)
        #expect(delta.removedFactIDs.isEmpty)
        #expect(delta.addedFactIDs.isEmpty)
        #expect(delta.updatedFactIDs.count == 2)
    }

    @Test("unsafe rules and inconsistent arity fail closed")
    func invalidRulesRejected() throws {
        let unsafe = rule("unsafe", head: atom("out", [.variable("unbound")]), body: [
            atom("seed", [.variable("x")])
        ])
        #expect(throws: ResearchReasoningValidationError.unsafeHeadVariable(ruleID: "unsafe", variable: "unbound")) {
            try ResearchReasoningEngine().evaluate(baseFacts: [fact("seed", ["x"])], rules: [unsafe])
        }
        let arityMismatch = rule("arity", head: atom("out", [.variable("x")]), body: [
            atom("seed", [.variable("x"), .constant("extra")])
        ])
        #expect(throws: ResearchReasoningValidationError.inconsistentArity(predicate: "seed")) {
            try ResearchReasoningEngine().evaluate(baseFacts: [fact("seed", ["x"])], rules: [arityMismatch])
        }
    }

    @Test("duplicate rule identities fail closed")
    func duplicateRulesRejected() {
        let first = rule("same", head: atom("a", [.variable("x")]), body: [atom("seed", [.variable("x")])])
        let second = rule("same", head: atom("b", [.variable("x")]), body: [atom("seed", [.variable("x")])])
        #expect(throws: ResearchReasoningValidationError.duplicateRuleID("same")) {
            try ResearchReasoningEngine().evaluate(baseFacts: [fact("seed", ["x"])], rules: [first, second])
        }
    }

    @Test("base and derived predicate roles cannot be mixed")
    func predicateRolesAreDisjoint() {
        let conflicting = rule(
            "conflict",
            head: atom("seed", [.variable("x")]),
            body: [atom("input", [.variable("x")])]
        )
        #expect(throws: ResearchReasoningValidationError.predicateRoleConflict("seed")) {
            try ResearchReasoningEngine().evaluate(
                baseFacts: [fact("seed", ["x"]), fact("input", ["x"])],
                rules: [conflicting]
            )
        }
    }

    @Test("proof traversal reports truncation at its bound")
    func boundedProof() throws {
        let seed = fact("seed", ["x"])
        let rules = [
            rule("one", head: atom("middle", [.variable("x")]), body: [atom("seed", [.variable("x")])]),
            rule("two", head: atom("result", [.variable("x")]), body: [atom("middle", [.variable("x")])])
        ]
        let engine = ResearchReasoningEngine(limits: .init(maximumProofDepth: 0))
        let snapshot = try engine.evaluate(baseFacts: [seed], rules: rules)
        let result = try #require(snapshot.facts(predicate: "result").first)
        let proof = try engine.why(factID: result.id, in: snapshot)
        #expect(proof.truncated)
        #expect(proof.facts.map(\.id) == [result.id])
    }

    @Test("cycles without a seed terminate without inventing facts")
    func unseededCycle() throws {
        let rules = [
            rule("a-to-b", head: atom("b", [.variable("x")]), body: [atom("a", [.variable("x")])]),
            rule("b-to-a", head: atom("a", [.variable("x")]), body: [atom("b", [.variable("x")])])
        ]
        let snapshot = try ResearchReasoningEngine().evaluate(baseFacts: [], rules: rules)
        #expect(snapshot.facts.isEmpty)
        #expect(snapshot.iterations == 1)
    }

    @Test("resource caps fail closed")
    func limits() {
        let engine = ResearchReasoningEngine(limits: .init(maximumBaseFacts: 0))
        #expect(throws: ResearchReasoningValidationError.resourceLimitExceeded("baseFacts")) {
            try engine.evaluate(baseFacts: [fact("seed", ["x"])], rules: [])
        }
    }

    @Test("pre-cancelled evaluation stops before accepting work")
    func cancellation() async {
        let engine = ResearchReasoningEngine()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try engine.evaluate(baseFacts: [fact("seed", ["x"])], rules: [])
        }
        do {
            _ = try await task.value
            Issue.record("cancelled evaluation unexpectedly completed")
        } catch is CancellationError {
            // Expected fail-closed cancellation.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
    }

    @Test("join cardinality cap fails closed")
    func matchCardinalityLimit() {
        let facts = (0 ..< 4).map { fact("edge", ["a", "v\($0)"]) }
            + (0 ..< 4).map { fact("edge", ["v\($0)", "z"]) }
        let transitive = rule(
            "join",
            head: atom("path", [.variable("x"), .variable("z")]),
            body: [
                atom("edge", [.variable("x"), .variable("y")]),
                atom("edge", [.variable("y"), .variable("z")])
            ]
        )
        let engine = ResearchReasoningEngine(limits: .init(maximumDerivations: 2))
        #expect(throws: ResearchReasoningValidationError.resourceLimitExceeded("matches")) {
            try engine.evaluate(baseFacts: facts, rules: [transitive])
        }
    }

    private func fact(
        _ predicate: String,
        _ arguments: [String],
        project: String = "throttle",
        evidence: String? = nil
    ) -> ResearchFact {
        ResearchFact(
            predicate: predicate,
            arguments: arguments,
            projectKey: project,
            sensitivity: .internal,
            assertedAt: now,
            evidence: evidence.map { [.init(receiptID: "receipt-" + $0, sourceID: $0)] } ?? []
        )
    }

    private func atom(_ predicate: String, _ terms: [ResearchTerm]) -> ResearchAtom {
        ResearchAtom(predicate: predicate, terms: terms)
    }

    private func rule(_ id: String, head: ResearchAtom, body: [ResearchAtom]) -> ResearchRule {
        ResearchRule(id: id, head: head, body: body)
    }
}
