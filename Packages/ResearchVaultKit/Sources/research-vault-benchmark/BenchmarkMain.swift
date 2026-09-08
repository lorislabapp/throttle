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
        guard CommandLine.arguments.count == 2 else {
            fail("usage: research-vault-benchmark DEEPSEARSH_ROOT", status: 64)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-benchmark-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let batch = try DeepSearshCatalogImporter(
                root: URL(fileURLWithPath: CommandLine.arguments[1])
            ).load(projectKeys: ["throttle"])
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
            let goldenSet = try ResearchVaultGoldenSetBuilder.build(
                documents: batch.documents,
                catalogSHA256: batch.evidence.catalogSHA256
            )
            let cases = goldenSet.cases
            var rankings: [[String]] = []
            var wallLatencies: [Double] = []
            var cpuLatencies: [Double] = []
            for item in cases {
                let start = ContinuousClock.now
                let cpuStart = processCPUTimeMilliseconds()
                let hits = try await store.searchDocuments(
                    query: item.query, limit: 10, authorization: authorization
                )
                cpuLatencies.append(processCPUTimeMilliseconds() - cpuStart)
                wallLatencies.append(milliseconds(start.duration(to: .now)))
                rankings.append(hits.map(\.documentID))
            }
            let metrics = try RetrievalBenchmarkEvaluator.evaluate(
                cases: cases, rankedDocumentIDs: rankings, cutoff: 10
            )
            let challenger = challengerEvidence(documents: batch.documents, cases: cases)
            let integrity = try await store.verifyIntegrity()
            await store.close()
            wallLatencies.sort()
            cpuLatencies.sort()
            let wallP95 = percentile(wallLatencies, 0.95)
            let cpuP95 = percentile(cpuLatencies, 0.95)
            let host = hostLoadEvidence()
            let wallLatencyValid = host.oneMinute <= Double(host.activeProcessors * 2)
            let passed = passesBaselineGate(metrics: metrics, cpuP95: cpuP95)
            let payload: [String: Any] = [
                "status": passed ? "pass" : "fail",
                "catalog_sha256": batch.evidence.catalogSHA256,
                "corpus_sha256": goldenSet.corpusSHA256,
                "documents": batch.documents.count,
                "chunks": chunkCount,
                "queries": metrics.caseCount,
                "answerable_queries": metrics.answerableCaseCount,
                "abstention_queries": metrics.abstentionCaseCount,
                "golden_set_version": goldenSet.version,
                "golden_set_sha256": goldenSet.caseSetSHA256,
                "k": metrics.cutoff,
                "mean_recall_at_k": metrics.meanRecallAtK,
                "mrr": metrics.meanReciprocalRank,
                "mean_ndcg_at_k": metrics.meanNDCGAtK,
                "abstention_accuracy": metrics.abstentionAccuracy,
                "query_wall_p50_ms": percentile(wallLatencies, 0.50),
                "query_wall_p95_ms": wallP95,
                "query_cpu_p50_ms": percentile(cpuLatencies, 0.50),
                "query_cpu_p95_ms": cpuP95,
                "latency_gate": "process_cpu_p95",
                "wall_latency_valid": wallLatencyValid,
                "host_load_average_1m": host.oneMinute,
                "host_active_processors": host.activeProcessors,
                "import_ms": milliseconds(importDuration),
                "schema_version": integrity.schemaVersion,
                "cipher_version": integrity.cipherVersion,
                "rankings": zip(cases, rankings).map {
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
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            guard passed else { exit(2) }
        } catch {
            fail("benchmark failed: \(error)", status: 1)
        }
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
        let elapsed = milliseconds(start.duration(to: .now))
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

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return sorted[index]
    }

    private static func processCPUTimeMilliseconds() -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
            return .infinity
        }
        return Double(value.tv_sec) * 1_000 + Double(value.tv_nsec) / 1_000_000
    }

    private static func hostLoadEvidence() -> (oneMinute: Double, activeProcessors: Int) {
        var averages = [Double](repeating: 0, count: 3)
        let count = getloadavg(&averages, Int32(averages.count))
        return (
            oneMinute: count > 0 ? averages[0] : .infinity,
            activeProcessors: max(ProcessInfo.processInfo.activeProcessorCount, 1)
        )
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
