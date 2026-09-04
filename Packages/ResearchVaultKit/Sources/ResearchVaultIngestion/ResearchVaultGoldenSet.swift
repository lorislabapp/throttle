import CryptoKit
import Foundation

public struct ResearchVaultGoldenSet: Equatable, Sendable {
    public static let version = "2026-08-31.1"
    public static let expectedCorpusSHA256 =
        "e8ac68ed3a117328fe0bb16d84bcd7626df809e316164d60cca562c6c4758d4f"
    public static let minimumCaseCount = 200

    public let version: String
    public let catalogSHA256: String
    public let corpusSHA256: String
    public let cases: [RetrievalBenchmarkCase]
    public let caseSetSHA256: String
}

public enum ResearchVaultGoldenSetError: Error, Equatable, Sendable {
    case corpusDrift(expected: String, actual: String)
    case insufficientCases(Int)
}

public enum ResearchVaultGoldenSetBuilder {
    public static func build(
        documents: [ResearchDocumentCandidate],
        catalogSHA256: String,
        expectedCorpusSHA256: String = ResearchVaultGoldenSet.expectedCorpusSHA256
    ) throws -> ResearchVaultGoldenSet {
        let corpusSHA256 = corpusSHA256(documents: documents)
        guard corpusSHA256 == expectedCorpusSHA256 else {
            throw ResearchVaultGoldenSetError.corpusDrift(
                expected: expectedCorpusSHA256,
                actual: corpusSHA256
            )
        }
        let titleCounts = Dictionary(grouping: documents, by: \.title).mapValues(\.count)
        var cases: [RetrievalBenchmarkCase] = []
        for document in documents.sorted(by: { $0.documentID < $1.documentID })
            where titleCounts[document.title] == 1 {
            for query in queries(for: document) {
                cases.append(.init(query: query, relevantDocumentIDs: [document.documentID]))
            }
        }
        cases += abstentionQueries.map {
            RetrievalBenchmarkCase(query: $0, relevantDocumentIDs: [], expectedAbstention: true)
        }
        guard cases.count >= ResearchVaultGoldenSet.minimumCaseCount else {
            throw ResearchVaultGoldenSetError.insufficientCases(cases.count)
        }
        let canonical = cases.map { item in
            item.query + "\u{0}" + item.relevantDocumentIDs.sorted().joined(separator: ",")
                + "\u{0}" + String(item.expectedAbstention)
        }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ResearchVaultGoldenSet(
            version: ResearchVaultGoldenSet.version,
            catalogSHA256: catalogSHA256,
            corpusSHA256: corpusSHA256,
            cases: cases,
            caseSetSHA256: hash
        )
    }

    public static func corpusSHA256(documents: [ResearchDocumentCandidate]) -> String {
        let canonical = documents.sorted(by: { $0.documentID < $1.documentID }).map {
            $0.documentID + "\u{0}" + $0.plaintextSHA256
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func queries(for document: ResearchDocumentCandidate) -> [String] {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = title.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let headings = document.content.split(separator: "\n").compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("#") else { return nil }
            let heading = value.drop(while: { $0 == "#" || $0 == " " })
            return heading.count >= 8 ? String(heading.prefix(180)) : nil
        }
        var candidates = [
            title,
            normalized,
            "evidence about " + title,
            "preuves concernant " + title,
            title + " " + (headings.first ?? "primary evidence"),
            title + " " + (headings.dropFirst().first ?? "supporting evidence")
        ]
        var seen = Set<String>()
        candidates = candidates.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        while candidates.count < 6 {
            candidates.append("research source " + String(candidates.count + 1) + " " + title)
        }
        return Array(candidates.prefix(6))
    }

    private static let abstentionQueries = [
        "zqxvquantumbanana9999",
        "wprtintrouvablewarp7788",
        "klyxpayrollphantom6633",
        "vbnmbiometricabsent5522",
        "qazxpost2035fiction4411",
        "plmokncveinvented3300",
        "ijuhmedicalghost2299",
        "ygtfbanksecret1188",
        "rfvbacquisitionvoid0077",
        "edcsatelliteimaginary9966"
    ]
}
