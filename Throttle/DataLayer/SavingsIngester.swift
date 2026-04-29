import Foundation
import GRDB
import OSLog

/// Reads the JSONL log written by Throttle's tokopt hooks and ingests it
/// into the `tokopt_savings` table.
///
/// Log path: `~/Library/Application Support/Throttle/savings.jsonl`
/// Each line: `{"ts": <unix_seconds>, "hook": <string>, "baseline_bytes": <int>, "actual_bytes": <int>}`
///
/// Uses `file_state` to track the last byte offset read, so each line is
/// ingested exactly once across app restarts. Tail-only — never re-reads
/// historical data.
@MainActor
final class SavingsIngester {
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "SavingsIngester")
    private let database: any DatabaseWriter
    private var pollTask: Task<Void, Never>?

    static let logFileURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Throttle").appendingPathComponent("savings.jsonl")
    }()

    /// Fired on the main actor whenever the ingester appends one or more
    /// new rows to `tokopt_savings`. Wired by AppDelegate to trigger
    /// `AppState.refresh()` so the savings hero card updates immediately
    /// instead of waiting for a Claude Code session-file change.
    var onIngest: (() -> Void)?

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // Initial sweep on startup.
            await self?.ingestNewLines()
            while !Task.isCancelled {
                // 60s cadence — savings.jsonl grows slowly (a few lines/day).
                try? await Task.sleep(for: .seconds(60))
                await self?.ingestNewLines()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Ingest any lines appended since the last call. Idempotent.
    func ingestNewLines() async {
        let url = Self.logFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return }
        let path = url.path

        var inserted = 0
        do {
            inserted = (try await Task.detached { [database] in
                try database.write { db in
                    let last = try DatabaseQueries.fileState(in: db, path: path)
                    let lastOffset = last?.lastOffset ?? 0
                    if size <= lastOffset { return 0 }

                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(lastOffset))
                    let chunk = handle.readDataToEndOfFile()
                    let text = String(decoding: chunk, as: UTF8.self)
                    let decoder = JSONDecoder()
                    var count = 0
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        guard let data = line.data(using: .utf8),
                              let json = try? decoder.decode(WireRow.self, from: data) else { continue }
                        var row = TokoptSavingsRow(
                            id: nil,
                            timestamp: json.ts,
                            hook: json.hook,
                            baselineBytes: json.baseline_bytes,
                            actualBytes: json.actual_bytes
                        )
                        try row.insert(db)
                        count += 1
                    }
                    let mtime: Int64 = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
                        .map { Int64($0.timeIntervalSince1970) } ?? Int64(Date().timeIntervalSince1970)
                    try DatabaseQueries.upsertFileState(in: db, path: path, offset: size, mtime: mtime)
                    return count
                }
            }.value)
        } catch {
            logger.error("savings.jsonl ingest failed: \(error.localizedDescription)")
        }
        if inserted > 0 {
            logger.info("Ingested \(inserted, privacy: .public) savings record(s) — notifying UI")
            onIngest?()
        }
    }

    private struct WireRow: Decodable {
        let ts: Int64
        let hook: String
        let baseline_bytes: Int
        let actual_bytes: Int
    }
}
