import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import Testing

@Suite("Frozen corpus manifest and human query set")
struct ResearchVaultCorpusManifestTests {
    private func documents(_ range: Range<Int>, salt: String = "") -> [ResearchDocumentCandidate] {
        range.map { index in
            let content = "# Topic \(index) primary evidence\(salt)\n\n# Decision \(index) details\n\nBody"
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
    }

    private func freeze(_ documents: [ResearchDocumentCandidate]) throws -> ResearchVaultCorpusManifest {
        let set = try ResearchVaultGoldenSetBuilder.build(
            documents: documents, catalogSHA256: "catalog",
            expectedCorpusSHA256: ResearchVaultGoldenSetBuilder.corpusSHA256(documents: documents)
        )
        return ResearchVaultCorpusManifest(documents: documents, goldenSet: set, frozenAt: "2026-09-09")
    }

    @Test("round-trips, binds the golden set to the frozen corpus and names every drift")
    func manifestContract() throws {
        let frozen = documents(0 ..< 34)
        let manifest = try freeze(frozen)
        let reloaded = try ResearchVaultCorpusManifest.load(try manifest.encoded())
        #expect(reloaded == manifest)
        #expect(reloaded.entries.count == 34)
        #expect(reloaded.drift(against: frozen).isEmpty)
        let bound = try ResearchVaultGoldenSetBuilder.build(documents: frozen, catalogSHA256: "c", manifest: reloaded)
        #expect(bound.caseSetSHA256 == manifest.caseSetSHA256)

        // One document rewritten, one removed, one added: each is named, none is hidden.
        var live = documents(1 ..< 34) + documents(34 ..< 35)
        live[0] = documents(1 ..< 2, salt: " rewritten")[0]
        let drift = reloaded.drift(against: live)
        #expect(drift.added == ["doc-34"])
        #expect(drift.removed == ["doc-0"])
        #expect(drift.changed == ["doc-1"])
        #expect(throws: ResearchVaultGoldenSetError.self) {
            try ResearchVaultGoldenSetBuilder.build(documents: live, catalogSHA256: "c", manifest: reloaded)
        }
    }

    @Test("refuses a manifest whose invariants do not hold")
    func manifestValidation() throws {
        let manifest = try freeze(documents(0 ..< 34))
        var object = try #require(JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])
        func load(_ mutate: (inout [String: Any]) -> Void) -> ResearchVaultGoldenSetError? {
            var copy = object
            mutate(&copy)
            do {
                _ = try ResearchVaultCorpusManifest.load(try JSONSerialization.data(withJSONObject: copy))
                return nil
            } catch let error as ResearchVaultGoldenSetError {
                return error
            } catch {
                return .manifestInvalid("unexpected")
            }
        }
        #expect(load { _ in } == nil)
        #expect(load { $0["formatVersion"] = 2 } == .manifestInvalid("format_version"))
        let zeroes = String(repeating: "0", count: 64)
        #expect(load { $0["corpusSHA256"] = zeroes } == .manifestInvalid("corpus_hash_mismatch"))
        #expect(load { $0["caseSetSHA256"] = "short" } == .manifestInvalid("digest_format"))
        #expect(load { $0["entries"] = [] } == .manifestInvalid("empty"))
        #expect(load {
            var entries = $0["entries"] as? [[String: Any]] ?? []
            entries.reverse()
            $0["entries"] = entries
        } == .manifestInvalid("entries_unsorted_or_duplicated"))
        #expect(load { $0["entries"] = "not a list" } == .manifestInvalid("undecodable"))
        object["entries"] = nil
        #expect(load { _ in } == .manifestInvalid("undecodable"))
    }

    @Test("a changed query generator cannot pass as the frozen golden set")
    func generatorChange() throws {
        let frozen = documents(0 ..< 34)
        let manifest = try freeze(frozen)
        let forged = try ResearchVaultCorpusManifest.load(try JSONEncoder().encode(
            ResearchVaultCorpusManifestFixture.withCaseSet(manifest, caseSetSHA256: String(repeating: "a", count: 64))
        ))
        #expect(throws: ResearchVaultGoldenSetError.generatorChanged(
            expected: String(repeating: "a", count: 64), actual: manifest.caseSetSHA256
        )) {
            try ResearchVaultGoldenSetBuilder.build(documents: frozen, catalogSHA256: "c", manifest: forged)
        }
    }

    @Test("human questions are validated against the live corpus and never copy a title")
    func humanQueries() throws {
        let corpus = documents(0 ..< 3)
        func load(_ cases: [[String: Any]]) throws -> [RetrievalBenchmarkCase] {
            let payload: [String: Any] = ["formatVersion": 1, "cases": cases]
            return try ResearchVaultHumanQuerySet.load(
                JSONSerialization.data(withJSONObject: payload), documents: corpus
            )
        }
        let valid = try load([
            ["query": "where did we decide the retention period?", "relevantDocumentIDs": ["doc-1", "doc-2"]],
            ["query": "anything about payroll in 2031?", "relevantDocumentIDs": []]
        ])
        #expect(valid.count == 2)
        #expect(valid[0].relevantDocumentIDs == ["doc-1", "doc-2"] && valid[0].expectedAbstention == false)
        #expect(valid[1].expectedAbstention == true)
        func failure(_ cases: [[String: Any]]) -> ResearchVaultGoldenSetError? {
            do { _ = try load(cases) } catch let error as ResearchVaultGoldenSetError {
                return error
            } catch { return nil }
            return nil
        }
        #expect(failure([["query": "  ", "relevantDocumentIDs": ["doc-1"]]]) == .humanQueriesInvalid("blank_query"))
        let duplicated: [[String: Any]] = [["query": "q", "relevantDocumentIDs": ["doc-1"]],
                                           ["query": "Q ", "relevantDocumentIDs": ["doc-2"]]]
        #expect(failure(duplicated) == .humanQueriesInvalid("duplicate_query"))
        #expect(failure([["query": "Unique Research Title 1", "relevantDocumentIDs": ["doc-1"]]])
                == .humanQueriesInvalid("query_is_a_document_title"))
        #expect(failure([["query": "q", "relevantDocumentIDs": ["doc-9"]]]) == .humanQueriesInvalid("unknown_document"))
        #expect(failure([["query": "q", "relevantDocumentIDs": ["doc-1"], "expectedAbstention": true]])
                == .humanQueriesInvalid("abstention_with_relevant_documents"))
        #expect(failure([["query": "q"]]) == .humanQueriesInvalid("undecodable"))
    }
}

/// Test-only forgery helper: re-encodes a manifest with a different case-set hash
/// while keeping the entries and corpus hash valid.
enum ResearchVaultCorpusManifestFixture {
    static func withCaseSet(_ manifest: ResearchVaultCorpusManifest, caseSetSHA256: String) -> [String: AnyCodable] {
        [
            "formatVersion": .init(manifest.formatVersion), "frozenAt": .init(manifest.frozenAt),
            "goldenSetVersion": .init(manifest.goldenSetVersion), "corpusSHA256": .init(manifest.corpusSHA256),
            "caseSetSHA256": .init(caseSetSHA256), "caseCount": .init(manifest.caseCount),
            "entries": .init(manifest.entries.map {
                ["documentID": $0.documentID, "plaintextSHA256": $0.plaintextSHA256]
            })
        ]
    }
}

struct AnyCodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let value as Int: try container.encode(value)
        case let value as String: try container.encode(value)
        case let value as [[String: String]]: try container.encode(value)
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "unsupported"))
        }
    }
}
