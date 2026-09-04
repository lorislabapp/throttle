import Foundation
import ResearchVaultModel
import ResearchVaultReasoning
import Testing

@Suite("Research Vault reasoning golden corpus")
struct ResearchVaultReasoningGoldenTests {
    @Test("versioned positive Datalog fixtures match exactly")
    func goldenCorpus() throws {
        let url = try #require(Bundle.module.url(
            forResource: "positive-datalog-golden",
            withExtension: "json"
        ))
        let corpus = try JSONDecoder().decode(GoldenCorpus.self, from: Data(contentsOf: url))
        #expect(corpus.schemaVersion == 1)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for testCase in corpus.cases {
            let baseFacts = testCase.facts.map { fixture in
                ResearchFact(
                    predicate: fixture.predicate,
                    arguments: fixture.arguments,
                    projectKey: "golden",
                    sensitivity: .internal,
                    assertedAt: date
                )
            }
            let rules = testCase.rules.map { fixture in
                ResearchRule(
                    id: fixture.id,
                    head: fixture.head.atom,
                    body: fixture.body.map(\.atom)
                )
            }
            let snapshot = try ResearchReasoningEngine().evaluate(baseFacts: baseFacts, rules: rules)
            let derived = snapshot.facts
                .filter { !snapshot.baseFactIDs.contains($0.id) }
                .map { "\($0.predicate)(\($0.arguments.joined(separator: ",")))" }
                .sorted()
            #expect(derived == testCase.expectedDerived.sorted(), Comment(rawValue: testCase.name))
        }
    }
}

private struct GoldenCorpus: Decodable {
    let schemaVersion: Int
    let cases: [GoldenCase]
}

private struct GoldenCase: Decodable {
    let name: String
    let facts: [GoldenFact]
    let rules: [GoldenRule]
    let expectedDerived: [String]
}

private struct GoldenFact: Decodable {
    let predicate: String
    let arguments: [String]
}

private struct GoldenRule: Decodable {
    let id: String
    let head: GoldenAtom
    let body: [GoldenAtom]
}

private struct GoldenAtom: Decodable {
    let predicate: String
    let terms: [String]

    var atom: ResearchAtom {
        ResearchAtom(predicate: predicate, terms: terms.map { value in
            value.hasPrefix("$") ? .variable(String(value.dropFirst())) : .constant(value)
        })
    }
}
