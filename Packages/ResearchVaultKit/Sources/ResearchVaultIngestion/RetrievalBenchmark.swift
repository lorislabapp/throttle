import Foundation

public struct RetrievalBenchmarkCase: Equatable, Sendable {
    public let query: String
    public let relevantDocumentIDs: Set<String>

    public init(query: String, relevantDocumentIDs: Set<String>) {
        self.query = query
        self.relevantDocumentIDs = relevantDocumentIDs
    }
}

public struct RetrievalCaseMetrics: Equatable, Sendable {
    public let query: String
    public let recallAtK: Double
    public let reciprocalRank: Double
    public let ndcgAtK: Double
}

public struct RetrievalBenchmarkMetrics: Equatable, Sendable {
    public let caseCount: Int
    public let k: Int
    public let meanRecallAtK: Double
    public let meanReciprocalRank: Double
    public let meanNDCGAtK: Double
    public let cases: [RetrievalCaseMetrics]
}

public enum RetrievalBenchmarkError: Error, Equatable, Sendable {
    case invalidK
    case noCases
    case emptyRelevanceSet(String)
    case resultCountMismatch
}

public enum RetrievalBenchmarkEvaluator {
    public static func evaluate(
        cases: [RetrievalBenchmarkCase],
        rankedDocumentIDs: [[String]],
        k: Int
    ) throws -> RetrievalBenchmarkMetrics {
        guard k > 0 else { throw RetrievalBenchmarkError.invalidK }
        guard !cases.isEmpty else { throw RetrievalBenchmarkError.noCases }
        guard cases.count == rankedDocumentIDs.count else {
            throw RetrievalBenchmarkError.resultCountMismatch
        }
        var output: [RetrievalCaseMetrics] = []
        for (item, ranked) in zip(cases, rankedDocumentIDs) {
            guard !item.relevantDocumentIDs.isEmpty else {
                throw RetrievalBenchmarkError.emptyRelevanceSet(item.query)
            }
            var seen = Set<String>()
            let unique = ranked.filter { seen.insert($0).inserted }
            let top = Array(unique.prefix(k))
            let relevantInTop = top.filter(item.relevantDocumentIDs.contains).count
            let recall = Double(relevantInTop) / Double(item.relevantDocumentIDs.count)
            let firstRank = unique.firstIndex(where: item.relevantDocumentIDs.contains)
            let reciprocalRank = firstRank.map { 1.0 / Double($0 + 1) } ?? 0
            let dcg = top.enumerated().reduce(0.0) { result, pair in
                item.relevantDocumentIDs.contains(pair.element)
                    ? result + 1.0 / log2(Double(pair.offset + 2))
                    : result
            }
            let idealCount = min(k, item.relevantDocumentIDs.count)
            let ideal = (0..<idealCount).reduce(0.0) { $0 + 1.0 / log2(Double($1 + 2)) }
            output.append(RetrievalCaseMetrics(
                query: item.query,
                recallAtK: recall,
                reciprocalRank: reciprocalRank,
                ndcgAtK: ideal > 0 ? dcg / ideal : 0
            ))
        }
        let count = Double(output.count)
        return RetrievalBenchmarkMetrics(
            caseCount: output.count,
            k: k,
            meanRecallAtK: output.reduce(0) { $0 + $1.recallAtK } / count,
            meanReciprocalRank: output.reduce(0) { $0 + $1.reciprocalRank } / count,
            meanNDCGAtK: output.reduce(0) { $0 + $1.ndcgAtK } / count,
            cases: output
        )
    }
}
