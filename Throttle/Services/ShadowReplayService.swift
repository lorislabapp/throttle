import Foundation

/// Shadow replay: the honest way to close the counterfactual that
/// `LocalCandidateService` deliberately leaves open. A "local-safe profile" is
/// only a shape; whether the embedded model would actually have served the ask
/// can be *measured* by replaying the session's original request against it and
/// putting the result through `LocalDelegationService.validate` — the same
/// evidence-grounded contract used for live delegation. No cloud call, no
/// interception, no effect on the real session.
///
/// Verdict semantics stay conservative (per the 2026-08 mix research):
/// - `verified`        — deterministic pass (extraction grounded byte-for-byte).
/// - `review_required` — plausible, but only a human A/B can prove quality.
///   NEVER counted as a success in any displayed statistic.
/// - `escalate` / `error` — hard failure: the local model could not serve this.
///
/// Every replay is appended to a local JSONL ledger. That ledger IS the golden
/// set being built: n grows, and once hard failures are zero the rule of three
/// gives a defensible 95% upper bound of ≈3/n on the hard-failure rate.
enum ShadowReplayService {

    /// Cap the ask we feed the 1.7B — bounded replay, not a context contest.
    static let maxAskCharacters = 12_000
    /// How many candidates one batch replays (sequential — 16 GB discipline).
    static let batchLimit = 5

    struct Entry: Codable, Sendable, Identifiable {
        var id: String { "\(sessionId)-\(ts)" }
        let ts: Int64
        let sessionId: String
        let project: String?
        let kind: String
        /// verified | review_required | escalate | error
        let status: String
        let reason: String
        let frontierWeightedTokens: Int
        let frontierEUR: Double
        let latencyMs: Int
        let askCharacters: Int
        let localCharacters: Int
    }

    struct Ledger: Sendable {
        let entries: [Entry]
        var replayed: Int { entries.count }
        var verified: Int { entries.filter { $0.status == "verified" }.count }
        var review: Int { entries.filter { $0.status == "review_required" }.count }
        var hardFailures: Int { entries.filter { $0.status == "escalate" || $0.status == "error" }.count }
        /// Rule of three: zero hard failures over n replays → ≤ 3/n at 95%.
        /// A bound on HARD failures only — review items remain unproven.
        var hardFailureBound95: Double? {
            guard replayed >= 10, hardFailures == 0 else { return nil }
            return 3.0 / Double(replayed)
        }
        static let empty = Ledger(entries: [])
    }

    static var ledgerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Throttle", isDirectory: true)
            .appendingPathComponent("shadow-replay-ledger.jsonl")
    }

    static func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else { return .empty }
        let decoder = JSONDecoder()
        let entries = text.split(separator: "\n").compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
        return Ledger(entries: entries)
    }

    private static func append(_ entry: Entry) {
        guard var payload = try? JSONEncoder().encode(entry) else { return }
        payload.append(0x0A)
        let url = ledgerURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url)
        }
    }

    // MARK: - Replay

    /// Replay one candidate. Reads the session transcript for the original ask,
    /// runs the embedded model through the delegation contract, validates, and
    /// appends the outcome to the ledger. Never throws — failures become entries.
    static func replay(candidate: LocalCandidateService.Candidate,
                       transcriptPath: String?) async -> Entry {
        let started = Date()
        func entry(kind: String, status: String, reason: String, localChars: Int = 0, askChars: Int = 0) -> Entry {
            Entry(
                ts: Int64(Date().timeIntervalSince1970),
                sessionId: candidate.sessionId,
                project: candidate.projectName,
                kind: kind,
                status: status,
                reason: reason,
                frontierWeightedTokens: candidate.weightedTokens,
                frontierEUR: candidate.costEUR,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                askCharacters: askChars,
                localCharacters: localChars
            )
        }

        guard let transcriptPath,
              let ask = firstUserAsk(transcriptPath: transcriptPath) else {
            return entry(kind: "unknown", status: "error",
                         reason: "transcript not found or holds no user request")
        }
        let boundedAsk = String(ask.prefix(maxAskCharacters))
        let kind = inferKind(ask: boundedAsk)

        // Same fail-closed gate as live delegation: action-oriented asks are
        // never "local-safe", and saying so is itself a measurement.
        if case .escalate(let why) = LocalDelegationService.assess(
            kind: kind.rawValue, objective: String(boundedAsk.prefix(1_800))
        ) {
            return entry(kind: kind.rawValue, status: "escalate", reason: why,
                         askChars: boundedAsk.count)
        }

        do {
            let result = try await EmbeddedModelRuntime.shared.delegate(
                source: boundedAsk,
                objective: "Produce exactly the artifact this developer request asks for, using SOURCE alone.",
                kind: kind
            )
            return entry(kind: kind.rawValue, status: result.status, reason: result.reason,
                         localChars: result.returnedCharacters, askChars: boundedAsk.count)
        } catch {
            return entry(kind: kind.rawValue, status: "error",
                         reason: error.localizedDescription, askChars: boundedAsk.count)
        }
    }

    /// Sequential batch (one model, one Mac, 16 GB): replays up to `batchLimit`
    /// candidates that are not already in the ledger, appending as it goes.
    static func replayBatch(candidates: [LocalCandidateService.Candidate],
                            transcriptPaths: [String: String]) async -> [Entry] {
        let done = Set(loadLedger().entries.map(\.sessionId))
        var out: [Entry] = []
        for candidate in candidates where !done.contains(candidate.sessionId) {
            if out.count >= batchLimit { break }
            let entry = await replay(candidate: candidate,
                                     transcriptPath: transcriptPaths[candidate.sessionId])
            append(entry)
            out.append(entry)
        }
        return out
    }

    // MARK: - Transcript

    /// First real user request in a Claude Code transcript. Scans from the head
    /// (the ask is at the top), tolerating meta lines and both content shapes.
    static func firstUserAsk(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath),
              let data = try? handle.read(upToCount: 4 * 1024 * 1024) else { return nil }
        try? handle.close()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  let message = obj["message"] as? [String: Any] else { continue }
            let content: String
            if let s = message["content"] as? String {
                content = s
            } else if let parts = message["content"] as? [[String: Any]] {
                content = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            } else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip harness scaffolding (system reminders, command echoes).
            if trimmed.isEmpty || trimmed.hasPrefix("<") { continue }
            return trimmed
        }
        return nil
    }

    /// Conservative mapping of a free-form ask onto the delegation taxonomy.
    /// `.draft` (always human-reviewed) is the default — never guess upward.
    static func inferKind(ask: String) -> LocalDelegationService.TaskKind {
        let a = ask.lowercased()
        if a.contains("extract") || a.contains("json") || a.contains("extrais") { return .extract }
        if a.contains("classif") { return .classify }
        if a.contains("summar") || a.contains("résum") || a.contains("tl;dr") { return .summarize }
        return .draft
    }
}
