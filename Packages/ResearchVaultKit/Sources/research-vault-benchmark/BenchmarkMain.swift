import Darwin
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultSQLCipher

@main
struct BenchmarkMain {
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
                    document, authorization: authorization
                ) { chunkCount += count }
            }
            let importDuration = importStart.duration(to: .now)
            let cases = try benchmarkCases(documents: batch.documents)
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
                cases: cases, rankedDocumentIDs: rankings, k: 5
            )
            let integrity = try await store.verifyIntegrity()
            await store.close()
            wallLatencies.sort()
            cpuLatencies.sort()
            let wallP95 = percentile(wallLatencies, 0.95)
            let cpuP95 = percentile(cpuLatencies, 0.95)
            let host = hostLoadEvidence()
            let wallLatencyValid = host.oneMinute <= Double(host.activeProcessors * 2)
            let passed = metrics.meanRecallAtK >= 1.0
                && metrics.meanReciprocalRank >= 0.80
                && metrics.meanNDCGAtK >= 0.80
                && cpuP95 <= 100
            let payload: [String: Any] = [
                "status": passed ? "pass" : "fail",
                "catalog_sha256": batch.evidence.catalogSHA256,
                "documents": batch.documents.count,
                "chunks": chunkCount,
                "queries": metrics.caseCount,
                "k": metrics.k,
                "mean_recall_at_k": metrics.meanRecallAtK,
                "mrr": metrics.meanReciprocalRank,
                "mean_ndcg_at_k": metrics.meanNDCGAtK,
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
                "rankings": zip(cases, rankings).map { ["query": $0.0.query, "ids": $0.1] },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            guard passed else { exit(2) }
        } catch {
            fail("benchmark failed", status: 1)
        }
    }

    /// Relevance labels bind to stable titles, then resolve to the current
    /// content-addressed catalog ID. Hard-coding IDs makes a legitimate source
    /// update look like a retrieval regression even when the intended document
    /// ranks first; missing or duplicate labels still fail closed.
    private static func benchmarkCases(
        documents: [ResearchDocumentCandidate]
    ) throws -> [RetrievalBenchmarkCase] {
        let specifications = [
            ("Research Vault CheatCode", "Throttle Research Vault × CheatCode — dossier de décision FULL SOTA"),
            ("Throttle Workspaces market architecture", "Throttle Workspaces — marché, produit et architecture SOTA"),
            ("Threat Model Throttle iOS", "Threat Model — Throttle for iOS (ThrottleiOS + ThrottleiOSWidget + ThrottleShared)"),
            ("Network Engineer Report Throttle iOS companion", "App Network Engineer Report — Throttle iOS companion (1.0 build 10)"),
            ("SOTA outils compagnons agents code", "SOTA — outils compagnons agents de code (deep research 2026-07-14)"),
        ]
        return try specifications.map { query, title in
            let matches = documents.filter { $0.title == title }
            guard matches.count == 1, let document = matches.first else {
                throw BenchmarkConfigurationError.missingOrAmbiguousTitle(title)
            }
            return RetrievalBenchmarkCase(
                query: query,
                relevantDocumentIDs: [document.documentID]
            )
        }
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

private enum BenchmarkConfigurationError: Error {
    case missingOrAmbiguousTitle(String)
}
