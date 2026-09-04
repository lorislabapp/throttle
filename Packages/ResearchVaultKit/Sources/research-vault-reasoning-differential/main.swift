import Foundation
import ResearchVaultModel
import ResearchVaultReasoning

private struct Generator {
    var state: UInt64

    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}

@main
struct ResearchVaultReasoningDifferentialMain {
    static func main() throws {
        let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 10_000
        guard (1...100_000).contains(count) else {
            throw ResearchReasoningValidationError.resourceLimitExceeded("programCount")
        }
        var generator = Generator(state: 0x5448_524f_5454_4c45)
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        for programIndex in 0..<count {
            var facts: [ResearchFact] = []
            for _ in 0..<12 {
                facts.append(ResearchFact(
                    predicate: "p\(generator.next(3))",
                    arguments: ["c\(generator.next(8))"],
                    projectKey: "oracle",
                    sensitivity: .public,
                    assertedAt: instant
                ))
            }
            var rules: [ResearchRule] = []
            for ruleIndex in 0..<8 {
                let head = 3 + generator.next(3)
                let left = generator.next(6)
                let hasSecond = generator.next(2) == 1
                let right = generator.next(6)
                var body = [ResearchAtom(predicate: "p\(left)", terms: [.variable("x")])]
                if hasSecond {
                    body.append(ResearchAtom(predicate: "p\(right)", terms: [.variable("x")]))
                }
                rules.append(ResearchRule(
                    id: "r\(ruleIndex)",
                    head: ResearchAtom(predicate: "p\(head)", terms: [.variable("x")]),
                    body: body
                ))
            }
            let snapshot = try ResearchReasoningEngine().evaluate(baseFacts: facts, rules: rules)
            let canonical = snapshot.facts.map { "\($0.predicate)(\($0.arguments[0]))" }.sorted()
            print("\(programIndex):\(canonical.joined(separator: ","))")
        }
    }
}
