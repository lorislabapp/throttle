import ResearchVaultIngestion
import Testing

@Suite("Research document chunker")
struct ResearchDocumentChunkerTests {
    @Test("is deterministic, bounded and carries headings")
    func deterministicMarkdownChunks() throws {
        let markdown = "# Alpha\n\n" + String(repeating: "first evidence sentence. ", count: 40)
            + "\n\n## Beta\n\n" + String(repeating: "second fact. ", count: 40)
        let chunker = try ResearchDocumentChunker(targetCharacters: 400, overlapCharacters: 60)
        let first = chunker.chunks(for: markdown)
        let second = chunker.chunks(for: markdown)
        #expect(first == second)
        #expect(first.count > 2)
        #expect(first.first?.heading == "Alpha")
        #expect(first.contains { $0.heading == "Beta" })
        #expect(first.allSatisfy { !$0.content.isEmpty && $0.approximateTokenCount > 0 })
    }

    @Test("empty Markdown produces no chunk")
    func empty() throws {
        #expect(try ResearchDocumentChunker().chunks(for: "\n\n").isEmpty)
    }

    @Test("rejects invalid configuration without trapping")
    func invalidConfiguration() {
        #expect(throws: ResearchDocumentChunkerError.targetTooSmall) {
            try ResearchDocumentChunker(targetCharacters: 10)
        }
        #expect(throws: ResearchDocumentChunkerError.invalidOverlap) {
            try ResearchDocumentChunker(targetCharacters: 400, overlapCharacters: 200)
        }
    }
}
