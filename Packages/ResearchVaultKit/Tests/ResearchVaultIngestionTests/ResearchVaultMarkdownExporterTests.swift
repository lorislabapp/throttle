import Foundation
import ResearchVaultModel
import ResearchVaultIngestion
import Testing

@Suite("Research Vault Markdown exporter")
struct ResearchVaultMarkdownExporterTests {
    @Test("export is deterministic and carries complete provenance")
    func exportIsDeterministicAndCarriesProvenance() throws {
        let sourceID = "source-export"
        let receipt = try ResearchReceipt.seal(
            receiptID: "30000000-0000-4000-8000-000000000001",
            sessionID: "export-test",
            agentID: "test-agent",
            projectKey: "throttle",
            question: "What should be exported?",
            findings: [
                ResearchFinding(
                    claim: "exported claim",
                    status: .open,
                    evidenceIDs: [sourceID]
                ),
            ],
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: "evidence/export.md",
                    observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                    sha256: String(repeating: "b", count: 64)
                ),
            ],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )

        let first = ResearchVaultMarkdownExporter.export([receipt])
        let second = ResearchVaultMarkdownExporter.export([receipt])
        #expect(first == second)
        #expect(first.count == 1)
        #expect(first[0].filename.contains(receipt.receiptID))
        #expect(first[0].content.contains("receipt_id:"))
        #expect(first[0].content.contains("sha256:"))
        #expect(first[0].content.contains("status: \"open\""))
        #expect(first[0].content.contains("exported claim"))
        #expect(first[0].content.contains(sourceID))
    }
}
