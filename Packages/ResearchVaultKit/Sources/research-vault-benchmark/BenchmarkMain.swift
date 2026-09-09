import Darwin
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultSQLCipher

@main
struct BenchmarkMain {
    // The executable keeps its ordered evidence lifecycle in one scope so the
    // encrypted temporary store is always closed before the process exits.
    // swiftlint:disable:next function_body_length
    static func main() async {
        let options: BenchmarkOptions
        do {
            options = try BenchmarkOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            BenchmarkSupport.fail("usage: research-vault-benchmark DEEPSEARSH_ROOT [--manifest PATH | --freeze PATH]"
                 + " [--human-queries PATH]\n\(error)", status: 64)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-benchmark-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let batch = try DeepSearshCatalogImporter(root: options.root).load(projectKeys: ["throttle"])
            let corpusSHA256 = ResearchVaultGoldenSetBuilder.corpusSHA256(documents: batch.documents)
            let (goldenSet, reference) = try resolveReference(
                options.reference, batch: batch, corpusSHA256: corpusSHA256
            )
            let humanCases = try options.humanQueries.map {
                try ResearchVaultHumanQuerySet.load(Data(contentsOf: $0), documents: batch.documents)
            } ?? []
            let store = try SQLCipherReceiptStore(
                databaseURL: temporary.appendingPathComponent("benchmark.ccsql"),
                key: Data(repeating: 0x42, count: 32)
            )
            let authorization = VaultAuthorization(
                projectKeys: ["throttle"], maximumSensitivity: .internal
            )
            let importStart = ContinuousClock.now
            var chunkCount = 0
            for document in batch.documents {
                if case let .inserted(count) = try await store.importDocument(
                    document, authorization: authorization, reviewState: .approved
                ) { chunkCount += count }
            }
            let importDuration = importStart.duration(to: .now)
            let cases = goldenSet.cases
            let derived = try await BenchmarkSupport.run(cases: cases, store: store, authorization: authorization)
            let human = humanCases.isEmpty
                ? nil : try await BenchmarkSupport.run(cases: humanCases, store: store, authorization: authorization)
            let challenger = challengerEvidence(documents: batch.documents, cases: cases)
            let integrity = try await store.verifyIntegrity()
            await store.close()
            let host = BenchmarkSupport.hostLoadEvidence()
            let wallLatencyValid = host.oneMinute <= Double(host.activeProcessors * 2)
            let derivedPassed = passesBaselineGate(metrics: derived.metrics, cpuP95: derived.cpuP95)
            // The derived title set only proves the plumbing. Once enough human
            // questions exist they become a gate of their own; fewer are reported
            // but can neither pass nor fail the run.
            let humanGated = (human?.metrics.caseCount ?? 0) >= ResearchVaultHumanQuerySet.minimumGatedCases
            let humanPassed = human.map { passesBaselineGate(metrics: $0.metrics, cpuP95: $0.cpuP95) } ?? true
            let passed = derivedPassed && (!humanGated || humanPassed)
            var payload: [String: Any] = [
                "status": passed ? "pass" : "fail",
                "quality_claim": humanGated ? "human_queries" : "derived_titles_only",
                "reference": reference,
                "catalog_sha256": batch.evidence.catalogSHA256,
                "corpus_sha256": goldenSet.corpusSHA256,
                "documents": batch.documents.count,
                "chunks": chunkCount,
                "queries": derived.metrics.caseCount,
                "answerable_queries": derived.metrics.answerableCaseCount,
                "abstention_queries": derived.metrics.abstentionCaseCount,
                "golden_set_version": goldenSet.version,
                "golden_set_sha256": goldenSet.caseSetSHA256,
                "k": derived.metrics.cutoff,
                "mean_recall_at_k": derived.metrics.meanRecallAtK,
                "mrr": derived.metrics.meanReciprocalRank,
                "mean_ndcg_at_k": derived.metrics.meanNDCGAtK,
                "abstention_accuracy": derived.metrics.abstentionAccuracy,
                "query_wall_p50_ms": derived.wallP50,
                "query_wall_p95_ms": derived.wallP95,
                "query_cpu_p50_ms": derived.cpuP50,
                "query_cpu_p95_ms": derived.cpuP95,
                "latency_gate": "process_cpu_p95",
                "wall_latency_valid": wallLatencyValid,
                "host_load_average_1m": host.oneMinute,
                "host_active_processors": host.activeProcessors,
                "import_ms": BenchmarkSupport.milliseconds(importDuration),
                "schema_version": integrity.schemaVersion,
                "cipher_version": integrity.cipherVersion,
                "rankings": zip(cases, derived.rankings).map {
                    [
                        "query": $0.0.query,
                        "expected_ids": $0.0.relevantDocumentIDs.sorted(),
                        "expected_abstention": $0.0.expectedAbstention,
                        "ids": $0.1
                    ] as [String: Any]
                },
                "challenger": challenger,
                "production_retriever": "fts5-bm25-v1"
            ]
            if let human {
                payload["human"] = [
                    "cases": human.metrics.caseCount,
                    "answerable_queries": human.metrics.answerableCaseCount,
                    "abstention_queries": human.metrics.abstentionCaseCount,
                    "gated": humanGated,
                    "minimum_gated_cases": ResearchVaultHumanQuerySet.minimumGatedCases,
                    "passed": humanPassed,
                    "mean_recall_at_k": human.metrics.meanRecallAtK,
                    "mrr": human.metrics.meanReciprocalRank,
                    "mean_ndcg_at_k": human.metrics.meanNDCGAtK,
                    "abstention_accuracy": human.metrics.abstentionAccuracy,
                    "query_cpu_p95_ms": human.cpuP95
                ] as [String: Any]
            } else {
                payload["human"] = ["cases": 0, "gated": false] as [String: Any]
            }
            BenchmarkSupport.emit(payload)
            guard passed else { exit(2) }
        } catch {
            BenchmarkSupport.fail("benchmark failed: \(error)", status: 1)
        }
    }

    /// Resolves the golden set from the chosen reference. A drifted corpus under
    /// a manifest ends the process here with a named report; a freeze writes the
    /// new manifest and, when one existed, the drift beside it.
    private static func resolveReference(
        _ mode: BenchmarkOptions.Reference, batch: DeepSearshImportBatch, corpusSHA256: String
    ) throws -> (ResearchVaultGoldenSet, [String: Any]) {
        var reference: [String: Any] = ["mode": "source_pinned",
                                        "expected_corpus_sha256": ResearchVaultGoldenSet.expectedCorpusSHA256]
        let goldenSet: ResearchVaultGoldenSet
        switch mode {
        case .manifest(let url):
            // A drifted corpus is refused with a concrete report: which documents
            // were added, removed or rewritten since the freeze. That report is
            // what a reviewer reads before authorising the next freeze.
            let manifest = try ResearchVaultCorpusManifest.load(Data(contentsOf: url))
            let drift = manifest.drift(against: batch.documents)
            reference = ["mode": "manifest", "path": url.path, "frozen_at": manifest.frozenAt,
                         "expected_corpus_sha256": manifest.corpusSHA256,
                         "frozen_documents": manifest.entries.count, "frozen_cases": manifest.caseCount]
            if !drift.isEmpty || manifest.corpusSHA256 != corpusSHA256 {
                let report = url.deletingPathExtension().appendingPathExtension("drift.json")
                try BenchmarkSupport.writeDriftReport(
                    drift, to: report, frozen: manifest.corpusSHA256, actual: corpusSHA256
                )
                BenchmarkSupport.emit(["status": "refused", "reason": "corpus_drift", "reference": reference,
                      "actual_corpus_sha256": corpusSHA256, "documents": batch.documents.count,
                      "drift": ["added": drift.added.count, "removed": drift.removed.count,
                                "changed": drift.changed.count, "report": report.path]])
                exit(2)
            }
            goldenSet = try ResearchVaultGoldenSetBuilder.build(
                documents: batch.documents, catalogSHA256: batch.evidence.catalogSHA256, manifest: manifest
            )
        case .freeze(let url):
            (goldenSet, reference) = try freeze(at: url, batch: batch, corpusSHA256: corpusSHA256)
        case .sourcePinned:
            goldenSet = try ResearchVaultGoldenSetBuilder.build(
                documents: batch.documents, catalogSHA256: batch.evidence.catalogSHA256
            )
        }
        return (goldenSet, reference)
    }

    /// Writes a new manifest for the live corpus; never silently, since a
    /// previous manifest is diffed and the drift written beside the new one.
    private static func freeze(
        at url: URL, batch: DeepSearshImportBatch, corpusSHA256: String
    ) throws -> (ResearchVaultGoldenSet, [String: Any]) {
        // Freezing never overwrites silently: the previous manifest, when
        // present, is diffed and the drift written beside the new one.
        let goldenSet = try ResearchVaultGoldenSetBuilder.build(
            documents: batch.documents, catalogSHA256: batch.evidence.catalogSHA256,
            expectedCorpusSHA256: corpusSHA256
        )
        let manifest = ResearchVaultCorpusManifest(
            documents: batch.documents, goldenSet: goldenSet, frozenAt: BenchmarkSupport.today()
        )
        let matchesPin = corpusSHA256 == ResearchVaultGoldenSet.expectedCorpusSHA256
        var freeze: [String: Any] = ["path": url.path, "frozen_at": manifest.frozenAt,
                                     "matches_source_pin": matchesPin]
        if let previousData = try? Data(contentsOf: url) {
            let previous = try ResearchVaultCorpusManifest.load(previousData)
            let drift = previous.drift(against: batch.documents)
            let report = url.deletingPathExtension().appendingPathExtension("drift.json")
            try BenchmarkSupport.writeDriftReport(
                drift, to: report, frozen: previous.corpusSHA256, actual: corpusSHA256
            )
            freeze["previous_corpus_sha256"] = previous.corpusSHA256
            freeze["previous_frozen_at"] = previous.frozenAt
            freeze["drift"] = ["added": drift.added.count, "removed": drift.removed.count,
                               "changed": drift.changed.count, "report": report.path]
        } else {
            freeze["previous"] = "none"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try manifest.encoded().write(to: url, options: .atomic)
        return (goldenSet, ["mode": "freeze", "freeze": freeze, "expected_corpus_sha256": corpusSHA256])
    }

    private static func challengerEvidence(
        documents: [ResearchDocumentCandidate],
        cases: [RetrievalBenchmarkCase]
    ) -> [String: Any] {
        let provider = NLEmbeddingResearchProvider(language: .english)
        guard provider.dimension > 0 else {
            return ["status": "unavailable", "provider": provider.identifier, "promoted": false]
        }
        var index = ExactCosineResearchIndex()
        for document in documents {
            let text = document.title + "\n" + String(document.content.prefix(8_192))
            guard let vector = provider.embed(text) else { continue }
            index.upsert(.init(documentID: document.documentID, vector: vector))
        }
        let start = ContinuousClock.now
        let denseRankings = cases.map { item -> [String] in
            guard let vector = provider.embed(item.query) else { return [] }
            let hits = index.search(vector: vector, limit: 10)
            if item.expectedAbstention, hits.first.map({ $0.score < 0.65 }) != false { return [] }
            return hits.map(\.documentID)
        }
        let elapsed = BenchmarkSupport.milliseconds(start.duration(to: .now))
        guard let metrics = try? RetrievalBenchmarkEvaluator.evaluate(
            cases: cases,
            rankedDocumentIDs: denseRankings,
            cutoff: 10
        ) else {
            return ["status": "evaluation_failed", "provider": provider.identifier, "promoted": false]
        }
        return [
            "status": "measured_not_promoted",
            "provider": provider.identifier,
            "backend": ResearchVectorBackend.exactSwift.rawValue,
            "documents": index.count,
            "answerable_queries": metrics.answerableCaseCount,
            "abstention_queries": metrics.abstentionCaseCount,
            "mean_recall_at_k": metrics.meanRecallAtK,
            "mrr": metrics.meanReciprocalRank,
            "mean_ndcg_at_k": metrics.meanNDCGAtK,
            "abstention_accuracy": metrics.abstentionAccuracy,
            "total_query_wall_ms": elapsed,
            "citation_packet_verified": false,
            "promoted": false,
            "promotion_reason": "challenger citations and product budgets are not yet proven"
        ]
    }

    private static func passesBaselineGate(
        metrics: RetrievalBenchmarkMetrics,
        cpuP95: Double
    ) -> Bool {
        metrics.answerableCaseCount > 0 && metrics.abstentionCaseCount > 0
            && metrics.meanRecallAtK >= 0.95
            && metrics.meanReciprocalRank >= 0.80
            && metrics.meanNDCGAtK >= 0.80
            && metrics.abstentionAccuracy >= 0.99
            && cpuP95.isFinite && cpuP95 >= 0 && cpuP95 <= 100
    }
}
