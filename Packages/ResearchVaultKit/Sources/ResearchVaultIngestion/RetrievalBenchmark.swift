import Foundation

public struct RetrievalBenchmarkCase: Equatable, Sendable {
    public let query: String
    public let relevantDocumentIDs: Set<String>
    public let expectedAbstention: Bool

    public init(
        query: String,
        relevantDocumentIDs: Set<String>,
        expectedAbstention: Bool = false
    ) {
        self.query = query
        self.relevantDocumentIDs = relevantDocumentIDs
        self.expectedAbstention = expectedAbstention
    }
}

public struct RetrievalCaseMetrics: Equatable, Sendable {
    public let query: String
    public let recallAtK: Double
    public let reciprocalRank: Double
    public let ndcgAtK: Double
    public let abstentionCorrect: Bool?
}

public struct RetrievalBenchmarkMetrics: Equatable, Sendable {
    public let caseCount: Int
    public let cutoff: Int
    public let meanRecallAtK: Double
    public let meanReciprocalRank: Double
    public let meanNDCGAtK: Double
    public let abstentionAccuracy: Double
    public let cases: [RetrievalCaseMetrics]
}

public enum RetrievalBenchmarkError: Error, Equatable, Sendable {
    case invalidK
    case noCases
    case invalidRelevanceSet(String)
    case resultCountMismatch
}

public enum RetrievalBenchmarkEvaluator {
    public static func evaluate(
        cases: [RetrievalBenchmarkCase],
        rankedDocumentIDs: [[String]],
        cutoff: Int
    ) throws -> RetrievalBenchmarkMetrics {
        guard cutoff > 0 else { throw RetrievalBenchmarkError.invalidK }
        guard !cases.isEmpty else { throw RetrievalBenchmarkError.noCases }
        guard cases.count == rankedDocumentIDs.count else {
            throw RetrievalBenchmarkError.resultCountMismatch
        }
        var output: [RetrievalCaseMetrics] = []
        for (item, ranked) in zip(cases, rankedDocumentIDs) {
            output.append(try metrics(for: item, ranked: ranked, cutoff: cutoff))
        }
        let count = Double(output.count)
        let abstentions = output.compactMap(\.abstentionCorrect)
        return RetrievalBenchmarkMetrics(
            caseCount: output.count,
            cutoff: cutoff,
            meanRecallAtK: output.reduce(0) { $0 + $1.recallAtK } / count,
            meanReciprocalRank: output.reduce(0) { $0 + $1.reciprocalRank } / count,
            meanNDCGAtK: output.reduce(0) { $0 + $1.ndcgAtK } / count,
            abstentionAccuracy: abstentions.isEmpty
                ? 1
                : Double(abstentions.count(where: { $0 })) / Double(abstentions.count),
            cases: output
        )
    }

    private static func metrics(
        for item: RetrievalBenchmarkCase,
        ranked: [String],
        cutoff: Int
    ) throws -> RetrievalCaseMetrics {
        guard item.expectedAbstention != !item.relevantDocumentIDs.isEmpty else {
            throw RetrievalBenchmarkError.invalidRelevanceSet(item.query)
        }
        var seen = Set<String>()
        let unique = ranked.filter { seen.insert($0).inserted }
        if item.expectedAbstention {
            let correct = unique.isEmpty
            return RetrievalCaseMetrics(
                query: item.query,
                recallAtK: correct ? 1 : 0,
                reciprocalRank: correct ? 1 : 0,
                ndcgAtK: correct ? 1 : 0,
                abstentionCorrect: correct
            )
        }
        let top = Array(unique.prefix(cutoff))
        let relevantInTop = top.filter(item.relevantDocumentIDs.contains).count
        let recall = Double(relevantInTop) / Double(item.relevantDocumentIDs.count)
        let firstRank = unique.firstIndex(where: item.relevantDocumentIDs.contains)
        let reciprocalRank = firstRank.map { 1.0 / Double($0 + 1) } ?? 0
        let dcg = top.enumerated().reduce(0.0) { result, pair in
            item.relevantDocumentIDs.contains(pair.element)
                ? result + 1.0 / log2(Double(pair.offset + 2))
                : result
        }
        let idealCount = min(cutoff, item.relevantDocumentIDs.count)
        let ideal = (0..<idealCount).reduce(0.0) { $0 + 1.0 / log2(Double($1 + 2)) }
        return RetrievalCaseMetrics(
            query: item.query,
            recallAtK: recall,
            reciprocalRank: reciprocalRank,
            ndcgAtK: ideal > 0 ? dcg / ideal : 0,
            abstentionCorrect: nil
        )
    }
}
