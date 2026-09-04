import ResearchVaultIngestion
import Testing

@Suite("Retrieval benchmark metrics")
struct RetrievalBenchmarkTests {
    @Test("computes Recall, reciprocal rank and nDCG with duplicate suppression")
    func metrics() throws {
        let cases = [
            RetrievalBenchmarkCase(query: "one", relevantDocumentIDs: ["a", "b"]),
            RetrievalBenchmarkCase(query: "two", relevantDocumentIDs: ["z"])
        ]
        let result = try RetrievalBenchmarkEvaluator.evaluate(
            cases: cases,
            rankedDocumentIDs: [["x", "a", "a", "b"], ["z"]],
            cutoff: 3
        )
        #expect(result.caseCount == 2)
        #expect(result.cases[0].recallAtK == 1)
        #expect(result.cases[0].reciprocalRank == 0.5)
        #expect(result.cases[1].ndcgAtK == 1)
        #expect(result.meanRecallAtK == 1)
    }

    @Test("rejects invalid benchmark definitions")
    func invalid() {
        #expect(throws: RetrievalBenchmarkError.noCases) {
            try RetrievalBenchmarkEvaluator.evaluate(cases: [], rankedDocumentIDs: [], cutoff: 5)
        }
        #expect(throws: RetrievalBenchmarkError.invalidK) {
            try RetrievalBenchmarkEvaluator.evaluate(
                cases: [RetrievalBenchmarkCase(query: "q", relevantDocumentIDs: ["x"])],
                rankedDocumentIDs: [["x"]],
                cutoff: 0
            )
        }
        #expect(throws: RetrievalBenchmarkError.invalidRelevanceSet("q")) {
            try RetrievalBenchmarkEvaluator.evaluate(
                cases: [.init(query: "q", relevantDocumentIDs: [])],
                rankedDocumentIDs: [[]],
                cutoff: 5
            )
        }
    }

    @Test("scores explicit abstention separately")
    func abstention() throws {
        let result = try RetrievalBenchmarkEvaluator.evaluate(
            cases: [.init(query: "absent", relevantDocumentIDs: [], expectedAbstention: true)],
            rankedDocumentIDs: [[]],
            cutoff: 5
        )
        #expect(result.abstentionAccuracy == 1)
        #expect(result.meanRecallAtK == 1)
    }
}
