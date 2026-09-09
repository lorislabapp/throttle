import Darwin
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultSQLCipher

/// Measurement and reporting helpers shared by the benchmark modes.
enum BenchmarkSupport {
    struct RunResult {
        let metrics: RetrievalBenchmarkMetrics
        let rankings: [[String]]
        let wallP50: Double
        let wallP95: Double
        let cpuP50: Double
        let cpuP95: Double
    }

    static func run(
        cases: [RetrievalBenchmarkCase], store: SQLCipherReceiptStore, authorization: VaultAuthorization
    ) async throws -> RunResult {
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
        wallLatencies.sort()
        cpuLatencies.sort()
        return RunResult(
            metrics: metrics, rankings: rankings,
            wallP50: percentile(wallLatencies, 0.50), wallP95: percentile(wallLatencies, 0.95),
            cpuP50: percentile(cpuLatencies, 0.50), cpuP95: percentile(cpuLatencies, 0.95)
        )
    }

    /// The report lists private document identifiers, so it is written beside
    /// the manifest and never printed to the evidence stream.
    static func writeDriftReport(
        _ drift: ResearchVaultCorpusDrift, to url: URL, frozen: String, actual: String
    ) throws {
        let payload: [String: Any] = [
            "frozen_corpus_sha256": frozen, "actual_corpus_sha256": actual,
            "added": drift.added, "removed": drift.removed, "changed": drift.changed
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url, options: .atomic)
    }

    static func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            fail("benchmark failed: unserialisable report", status: 1)
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    static func today() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return sorted[index]
    }

    static func processCPUTimeMilliseconds() -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
            return .infinity
        }
        return Double(value.tv_sec) * 1_000 + Double(value.tv_nsec) / 1_000_000
    }

    static func hostLoadEvidence() -> (oneMinute: Double, activeProcessors: Int) {
        var averages = [Double](repeating: 0, count: 3)
        let count = getloadavg(&averages, Int32(averages.count))
        return (
            oneMinute: count > 0 ? averages[0] : .infinity,
            activeProcessors: max(ProcessInfo.processInfo.activeProcessorCount, 1)
        )
    }

    static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
