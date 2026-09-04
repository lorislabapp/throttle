import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import Testing

@Suite("Versioned Research Vault golden set")
struct ResearchVaultGoldenSetTests {
    @Test("is deterministic, drift-pinned and refuses a too-small corpus")
    func contract() throws {
        let documents = (0 ..< 34).map { index in
            let content = "# Topic \(index) primary evidence\n\n# Decision \(index) details\n\nBody"
            let data = Data(content.utf8)
            return ResearchDocumentCandidate(
                documentID: "doc-\(index)", title: "Unique Research Title \(index)",
                projectKey: "throttle", category: "test", libraryPath: "library/\(index).md",
                origins: ["/source/\(index)"], content: content,
                plaintextSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                byteCount: data.count, modifiedAt: Date(timeIntervalSince1970: Double(index)),
                sensitivity: .internal
            )
        }
        let corpusSHA = ResearchVaultGoldenSetBuilder.corpusSHA256(documents: documents)
        let first = try ResearchVaultGoldenSetBuilder.build(
            documents: documents, catalogSHA256: "catalog-a", expectedCorpusSHA256: corpusSHA
        )
        let second = try ResearchVaultGoldenSetBuilder.build(
            documents: documents, catalogSHA256: "catalog-b", expectedCorpusSHA256: corpusSHA
        )
        #expect(first.cases == second.cases)
        #expect(first.corpusSHA256 == second.corpusSHA256)
        #expect(first.catalogSHA256 != second.catalogSHA256)
        #expect(first.cases.count >= 200)
        #expect(first.caseSetSHA256.count == 64)
        #expect(throws: ResearchVaultGoldenSetError.corpusDrift(
            expected: "changed", actual: corpusSHA
        )) {
            try ResearchVaultGoldenSetBuilder.build(
                documents: documents, catalogSHA256: "catalog", expectedCorpusSHA256: "changed"
            )
        }
    }
}
