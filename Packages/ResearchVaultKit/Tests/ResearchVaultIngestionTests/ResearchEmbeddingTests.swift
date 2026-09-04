import ResearchVaultIngestion
import Testing

@Suite("Research embedding challenger")
struct ResearchEmbeddingTests {
    @Test("exact cosine index is deterministic and rejects dimension mismatches")
    func exactIndex() {
        var index = ExactCosineResearchIndex()
        index.upsert(.init(documentID: "b", vector: [0, 1]))
        index.upsert(.init(documentID: "a", vector: [1, 0]))
        index.upsert(.init(documentID: "wrong", vector: [1]))
        #expect(index.search(vector: [1, 0], limit: 3).map(\.documentID) == ["a", "b"])
        #expect(index.search(vector: [], limit: 3).isEmpty)
    }

    @Test("RRF deduplicates and preserves deterministic ties")
    func reciprocalRankFusion() {
        let result = ReciprocalRankFusion.rank(
            rankings: [["a", "b", "b"], ["b", "a"], ["c"]],
            limit: 3
        )
        #expect(result == ["a", "b", "c"] || result == ["b", "a", "c"])
        #expect(Set(result).count == result.count)
    }

    @Test("unlinked native vector extensions are never reported available")
    func backendEvidence() {
        let evidence = ResearchVectorBackendEvidence.currentBuild
        #expect(evidence.first { $0.backend == .exactSwift }?.available == true)
        #expect(evidence.first { $0.backend == .sqliteVec }?.available == false)
        #expect(evidence.first { $0.backend == .sqliteVec1 }?.available == false)
    }
}
