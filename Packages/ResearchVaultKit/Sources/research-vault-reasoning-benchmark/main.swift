import Darwin
import Foundation
import ResearchVaultModel
import ResearchVaultReasoning

private struct BenchmarkResult: Codable {
    let status: String
    let scenario: String
    let factCount: Int
    let repetitions: Int
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let budgetMilliseconds: Double
    let outputFacts: Int
}

@main
struct ResearchVaultReasoningBenchmarkMain {
    // This executable intentionally keeps setup, warmup, sampling, and JSON
    // emission in one auditable benchmark transaction.
    // swiftlint:disable:next function_body_length
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        let factCount = arguments.first.flatMap(Int.init) ?? 1_000
        let repetitions = arguments.dropFirst().first.flatMap(Int.init) ?? 5
        let budgets = [1_000: 1_000.0, 10_000: 5_000.0, 100_000: 60_000.0]
        guard let budget = budgets[factCount], (3 ... 9).contains(repetitions) else {
            throw ResearchReasoningValidationError.resourceLimitExceeded("benchmarkArguments")
        }

        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let facts = (0 ..< factCount).map { index in
            ResearchFact(
                predicate: "dependsOn",
                arguments: ["claim-\(index)", "claim-\((index + 1) % factCount)"],
                projectKey: "benchmark",
                sensitivity: .internal,
                assertedAt: instant
            )
        }
        let rules = [ResearchRule(
            id: "impact-direct",
            head: ResearchAtom(
                predicate: "impacted",
                terms: [.variable("subject"), .variable("object")]
            ),
            body: [ResearchAtom(
                predicate: "dependsOn",
                terms: [.variable("subject"), .variable("object")]
            )]
        )]
        let engine = ResearchReasoningEngine(limits: ResearchReasoningLimits(
            maximumBaseFacts: factCount,
            maximumRules: 8,
            maximumDerivedFacts: factCount,
            maximumIterations: 8,
            maximumDerivations: factCount,
            maximumProofNodes: 2_000,
            maximumProofDepth: 64,
            maximumRuleBodyAtoms: 4,
            maximumTermsPerAtom: 4
        ))

        _ = try engine.evaluate(baseFacts: facts, rules: rules)
        var samples: [Double] = []
        var outputFacts = 0
        for _ in 0 ..< repetitions {
            let start = ContinuousClock.now
            let snapshot = try engine.evaluate(baseFacts: facts, rules: rules)
            let elapsed = start.duration(to: .now)
            samples.append(milliseconds(elapsed))
            outputFacts = snapshot.facts.count
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        let result = BenchmarkResult(
            status: p95 <= budget ? "pass" : "fail",
            scenario: "full-rebuild-one-hop",
            factCount: factCount,
            repetitions: repetitions,
            samplesMilliseconds: samples,
            medianMilliseconds: median,
            p95Milliseconds: p95,
            budgetMilliseconds: budget,
            outputFacts: outputFacts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(result))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if result.status != "pass" { Darwin.exit(1) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
