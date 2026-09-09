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
    case generatorChanged(expected: String, actual: String)
    case manifestInvalid(String)
    case humanQueriesInvalid(String)
}

public enum ResearchVaultGoldenSetBuilder {
    /// Builds against a frozen manifest: the corpus must match it exactly and
    /// the derived case set must still hash as it did at freeze time, so a
    /// silent change of the query generator cannot pass as the same benchmark.
    public static func build(
        documents: [ResearchDocumentCandidate],
        catalogSHA256: String,
        manifest: ResearchVaultCorpusManifest
    ) throws -> ResearchVaultGoldenSet {
        let set = try build(
            documents: documents, catalogSHA256: catalogSHA256,
            expectedCorpusSHA256: manifest.corpusSHA256
        )
        guard set.caseSetSHA256 == manifest.caseSetSHA256 else {
            throw ResearchVaultGoldenSetError.generatorChanged(
                expected: manifest.caseSetSHA256, actual: set.caseSetSHA256
            )
        }
        return set
    }

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

/// A frozen, private description of the corpus a golden set was built on. It
/// lives outside the repository — document identifiers are private — and only
/// its hashes and counts are ever quoted in committed evidence. A new freeze is
/// a reviewed decision: the drift report names what changed since the last one.
public struct ResearchVaultCorpusManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let documentID: String
        public let plaintextSHA256: String

        public init(documentID: String, plaintextSHA256: String) {
            self.documentID = documentID
            self.plaintextSHA256 = plaintextSHA256
        }
    }

    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let frozenAt: String
    public let goldenSetVersion: String
    public let corpusSHA256: String
    public let caseSetSHA256: String
    public let caseCount: Int
    public let entries: [Entry]

    public init(documents: [ResearchDocumentCandidate], goldenSet: ResearchVaultGoldenSet, frozenAt: String) {
        formatVersion = Self.currentFormatVersion
        self.frozenAt = frozenAt
        goldenSetVersion = goldenSet.version
        corpusSHA256 = goldenSet.corpusSHA256
        caseSetSHA256 = goldenSet.caseSetSHA256
        caseCount = goldenSet.cases.count
        entries = documents.sorted(by: { $0.documentID < $1.documentID }).map {
            Entry(documentID: $0.documentID, plaintextSHA256: $0.plaintextSHA256)
        }
    }

    /// Decodes and re-derives every invariant; a manifest whose entries do not
    /// hash to its own corpus hash is refused rather than trusted.
    public static func load(_ data: Data) throws -> ResearchVaultCorpusManifest {
        let manifest: ResearchVaultCorpusManifest
        do {
            manifest = try JSONDecoder().decode(ResearchVaultCorpusManifest.self, from: data)
        } catch {
            throw ResearchVaultGoldenSetError.manifestInvalid("undecodable")
        }
        guard manifest.formatVersion == currentFormatVersion else {
            throw ResearchVaultGoldenSetError.manifestInvalid("format_version")
        }
        guard !manifest.entries.isEmpty, manifest.caseCount > 0 else {
            throw ResearchVaultGoldenSetError.manifestInvalid("empty")
        }
        let identifiers = manifest.entries.map(\.documentID)
        guard identifiers == identifiers.sorted(), Set(identifiers).count == identifiers.count else {
            throw ResearchVaultGoldenSetError.manifestInvalid("entries_unsorted_or_duplicated")
        }
        guard manifest.entries.allSatisfy({ isHexDigest($0.plaintextSHA256) }),
              isHexDigest(manifest.corpusSHA256), isHexDigest(manifest.caseSetSHA256) else {
            throw ResearchVaultGoldenSetError.manifestInvalid("digest_format")
        }
        guard manifest.recomputedCorpusSHA256 == manifest.corpusSHA256 else {
            throw ResearchVaultGoldenSetError.manifestInvalid("corpus_hash_mismatch")
        }
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Names exactly what differs between the frozen corpus and the live one.
    public func drift(against documents: [ResearchDocumentCandidate]) -> ResearchVaultCorpusDrift {
        let frozen = Dictionary(uniqueKeysWithValues: entries.map { ($0.documentID, $0.plaintextSHA256) })
        var live: [String: String] = [:]
        for document in documents { live[document.documentID] = document.plaintextSHA256 }
        return ResearchVaultCorpusDrift(
            added: live.keys.filter { frozen[$0] == nil }.sorted(),
            removed: frozen.keys.filter { live[$0] == nil }.sorted(),
            changed: live.filter { key, hash in frozen[key].map { $0 != hash } == true }.keys.sorted()
        )
    }

    var recomputedCorpusSHA256: String {
        let canonical = entries.map { $0.documentID + "\u{0}" + $0.plaintextSHA256 }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

public struct ResearchVaultCorpusDrift: Equatable, Sendable {
    public let added: [String]
    public let removed: [String]
    public let changed: [String]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
}

/// Human-written questions with the documents a person judged relevant. Kept
/// private next to the manifest; the derived title set proves plumbing, this
/// set is the only one that can support a quality claim.
public struct ResearchVaultHumanQuerySet: Codable, Equatable, Sendable {
    public struct Case: Codable, Equatable, Sendable {
        public let query: String
        public let relevantDocumentIDs: [String]
        public let expectedAbstention: Bool?

        public init(query: String, relevantDocumentIDs: [String], expectedAbstention: Bool? = nil) {
            self.query = query
            self.relevantDocumentIDs = relevantDocumentIDs
            self.expectedAbstention = expectedAbstention
        }
    }

    public static let currentFormatVersion = 1
    /// Below this many cases the set is reported but never used as a gate.
    public static let minimumGatedCases = 20

    public let formatVersion: Int
    public let cases: [Case]

    public init(cases: [Case]) {
        formatVersion = Self.currentFormatVersion
        self.cases = cases
    }

    /// Validates every case against the live corpus: unknown documents, a
    /// relevance set on an abstention case, blank or duplicated questions and
    /// questions that merely repeat a document title are refused.
    public static func load(
        _ data: Data, documents: [ResearchDocumentCandidate]
    ) throws -> [RetrievalBenchmarkCase] {
        let set: ResearchVaultHumanQuerySet
        do {
            set = try JSONDecoder().decode(ResearchVaultHumanQuerySet.self, from: data)
        } catch {
            throw ResearchVaultGoldenSetError.humanQueriesInvalid("undecodable")
        }
        guard set.formatVersion == currentFormatVersion else {
            throw ResearchVaultGoldenSetError.humanQueriesInvalid("format_version")
        }
        let known = Set(documents.map(\.documentID))
        let titles = Set(documents.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seen = Set<String>()
        return try set.cases.map { item in
            let query = item.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw ResearchVaultGoldenSetError.humanQueriesInvalid("blank_query") }
            guard seen.insert(query.lowercased()).inserted else {
                throw ResearchVaultGoldenSetError.humanQueriesInvalid("duplicate_query")
            }
            guard !titles.contains(query.lowercased()) else {
                throw ResearchVaultGoldenSetError.humanQueriesInvalid("query_is_a_document_title")
            }
            let relevant = Set(item.relevantDocumentIDs)
            guard relevant.isSubset(of: known) else {
                throw ResearchVaultGoldenSetError.humanQueriesInvalid("unknown_document")
            }
            let abstention = item.expectedAbstention ?? relevant.isEmpty
            guard abstention == relevant.isEmpty else {
                throw ResearchVaultGoldenSetError.humanQueriesInvalid("abstention_with_relevant_documents")
            }
            return RetrievalBenchmarkCase(query: query, relevantDocumentIDs: relevant, expectedAbstention: abstention)
        }
    }
}
