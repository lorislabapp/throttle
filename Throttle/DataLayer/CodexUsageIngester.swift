import Foundation
import GRDB
import OSLog

/// Persists Codex usage so it survives the session that produced it.
///
/// Codex was already read live for the menu bar, but nothing was written down:
/// the moment a rollout aged out of the three-day window, its cost vanished.
/// That left `get_session_cost` reporting a Claude-only figure as though it
/// were the whole bill, and no way to see a Codex trend at all.
///
/// The write is an UPSERT keyed by session, because Codex reports a session's
/// CUMULATIVE totals rather than the delta since the last read. Appending each
/// observation would re-add the session's entire history on every poll — the
/// same failure mode migration v6 had to undo. Upserting makes re-reading the
/// same rollout converge on one row instead of accumulating.
///
/// Only the last three days of rollouts are scanned, matching what
/// `CodexUsageService` already walks: sessions older than that were either
/// already stored by an earlier run or predate the feature. This deliberately
/// does not backfill history that was never observed.
@MainActor
final class CodexUsageIngester {
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "CodexUsageIngester")
    private let database: any DatabaseWriter
    private let sessionsRoot: URL
    private var pollTask: Task<Void, Never>?

    /// Fired when at least one row was written, so the UI can refresh instead of
    /// waiting for the next periodic sweep.
    var onIngest: (() -> Void)?

    init(database: any DatabaseWriter, sessionsRoot: URL? = nil) {
        self.database = database
        self.sessionsRoot = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.ingest()
            while !Task.isCancelled {
                // Slower than the savings sweep: a rollout's totals only move
                // while a Codex session is live, and the row is idempotent, so
                // there is nothing to gain from polling harder.
                try? await Task.sleep(for: .seconds(120))
                await self?.ingest()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Read every recent rollout's latest totals and upsert them. Idempotent.
    func ingest(now: Date = Date()) async {
        let urls = CodexUsageService.recentRolloutURLs(root: sessionsRoot, now: now)
        guard !urls.isEmpty else { return }

        let rows: [CodexUsageRow] = urls.compactMap { url in
            guard let snapshot = CodexUsageService.snapshot(from: url),
                  let tokens = snapshot.tokens else { return nil }
            // Codex sometimes reports `total_tokens` equal to the context window
            // with every component at zero — observed 2026-08-21 on a real
            // rollout that carried 111 such events. That is Codex describing the
            // window, not work performed, and storing it credited a session with
            // 121,600 tokens it never spent. A total no component accounts for is
            // not evidence, so require the components rather than the total.
            guard tokens.input > 0 || tokens.output > 0 else { return nil }
            return CodexUsageRow(
                sessionId: snapshot.sessionID ?? Self.sessionID(fromRolloutAt: url),
                observedAt: Int64(snapshot.observedAt.timeIntervalSince1970),
                inputTokens: tokens.input,
                cachedInputTokens: tokens.cachedInput,
                cacheWriteInputTokens: tokens.cacheWrite,
                outputTokens: tokens.output,
                reasoningOutputTokens: tokens.reasoning,
                totalTokens: tokens.total,
                contextWindow: snapshot.contextWindow
            )
        }
        guard !rows.isEmpty else { return }

        var written = 0
        do {
            written = try await Task.detached { [database] in
                try database.write { db in
                    var count = 0
                    for row in rows {
                        // Only move a session forward. A stale re-read must never
                        // lower a total that a later observation already raised.
                        let existing = try CodexUsageRow
                            .filter(Column("session_id") == row.sessionId)
                            .fetchOne(db)
                        if let existing, existing.totalTokens >= row.totalTokens,
                           existing.observedAt >= row.observedAt { continue }
                        try row.save(db)
                        count += 1
                    }
                    return count
                }
            }.value
        } catch {
            logger.error("codex_usage ingest failed: \(error.localizedDescription)")
            return
        }

        if written > 0 {
            logger.info("Ingested \(written, privacy: .public) Codex usage row(s)")
            onIngest?()
        }
    }

    /// `rollout-2026-08-20T16-26-04-01a01f90-....jsonl` → the trailing UUID.
    /// Used only when the rollout itself carries no session id; the filename is
    /// still stable per session, so the row stays idempotent either way.
    static func sessionID(fromRolloutAt url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        // A UUID contributes its five dash-separated groups at the end.
        guard parts.count >= 5 else { return stem }
        return parts.suffix(5).joined(separator: "-")
    }
}
