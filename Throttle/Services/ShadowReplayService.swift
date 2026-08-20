import CryptoKit
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

    /// Which population a case was drawn from. Never mix them into one rate: the
    /// naturalistic sample estimates production performance, the stress sample
    /// measures robustness on cases deliberately chosen to be hard.
    enum Population: String, Codable, Sendable { case naturalistic, stress }

    /// Exploratory cases are used to find failure modes and tune prompt/schema/
    /// validator. Certification cases are FROZEN — never used for tuning — and
    /// they alone may back a published bound. Mixing the two would certify a
    /// pipeline against the very cases it was fitted to.
    enum Stage: String, Codable, Sendable { case exploratory, certification }

    /// One replay. The reproducibility block exists because changing the model
    /// digest, the quantization, the prompt, the schema, the context window or
    /// the KV cache turns this into a different system — a bound carried over
    /// from the previous configuration would be a bound on something else.
    ///
    /// Fields added after the first schema are OPTIONAL on purpose: a ledger
    /// written by an older build still decodes, and a value we cannot honestly
    /// determine stays nil rather than being invented.
    struct Entry: Codable, Sendable, Identifiable {
        var id: String { "\(sessionId)-\(ts)" }
        let ts: Int64
        let sessionId: String
        let project: String?
        let kind: String
        /// What the PIPELINE decided: verified | review_required | escalate | error.
        /// This is a claim, not a fact — `adjudicatedStatus` is what checks it.
        let status: String
        let reason: String
        let frontierWeightedTokens: Int
        let frontierEUR: Double
        let latencyMs: Int
        let askCharacters: Int
        let localCharacters: Int

        // MARK: Reproducibility

        var schemaVersion: Int?
        /// embedded | server — which backend actually ran the inference.
        var backend: String?
        var model: String?
        var weightQuant: String?
        /// Server-side generation parameters. nil for the embedded backend,
        /// where they do not apply — never zero-filled.
        var numCtx: Int?
        var kvType: String?
        var flashAttention: Bool?
        var gpuFreeMiB: Int?
        /// e.g. "28/37" — how much of the model reached the GPU.
        var gpuLayers: String?
        var promptVersion: String?
        /// Lets a case be re-run against the byte-identical source later.
        var sourceSHA256: String?

        // MARK: Sampling + adjudication

        var stage: String?
        var population: String?
        /// Near-duplicate cases share a cluster id. Ten variants of one build log
        /// are ONE piece of evidence, not ten — the rule of three assumes
        /// independent trials and silently lies when they are not.
        var clusterID: String?
        /// The verdict a human reached against the ORIGINAL source. nil = not yet
        /// adjudicated, which is why an un-adjudicated case can never count
        /// toward a bound: nothing has checked the pipeline's own claim.
        var adjudicatedStatus: String?

        static let currentSchemaVersion = 2

        var isCertification: Bool { stage == Stage.certification.rawValue }
        /// The event that actually matters: the pipeline said `verified` and the
        /// adjudication disagreed. A `review_required` that a human confirms is
        /// not a failure — it is the contract working.
        var isFalseVerified: Bool {
            guard let adjudicatedStatus else { return false }
            return status == "verified" && adjudicatedStatus != "verified"
        }
    }

    struct Ledger: Sendable {
        let entries: [Entry]
        var replayed: Int { entries.count }
        var verified: Int { entries.filter { $0.status == "verified" }.count }
        var review: Int { entries.filter { $0.status == "review_required" }.count }
        var hardFailures: Int { entries.filter { $0.status == "escalate" || $0.status == "error" }.count }

        // MARK: - The bound that matters

        /// Certification-stage cases a human has adjudicated. Exploratory cases
        /// tuned the pipeline, so they cannot also certify it; un-adjudicated
        /// cases carry no evidence at all, because nothing has checked the
        /// pipeline's own verdict.
        var certified: [Entry] {
            entries.filter { $0.isCertification && $0.adjudicatedStatus != nil }
        }
        /// Denominator: adjudicated cases where the pipeline claimed `verified`.
        /// Only those can produce the failure we are bounding.
        var certifiedVerifiedClaims: Int {
            certified.filter { $0.status == "verified" }.count
        }
        var falseVerified: Int { certified.filter(\.isFalseVerified).count }

        /// Exact one-sided 95% upper bound on the false-`verified` rate, given
        /// zero observed false positives: 1 − α^(1/n), not the 3/n
        /// approximation. nil once a false positive exists — then the rate is
        /// measured, not bounded — and nil below `minimumForBound`, where the
        /// bound is arithmetically real but too weak to mean anything.
        var falseVerifiedBound95: Double? {
            let n = certifiedVerifiedClaims
            guard n >= Self.minimumForBound, falseVerified == 0 else { return nil }
            return 1 - pow(0.05, 1.0 / Double(n))
        }

        /// Below this many cases the bound exceeds 25% — reporting it invites
        /// the reader to hear "proven" where the arithmetic says "unknown".
        static let minimumForBound = 10

        /// Cases needed, all passing, to push the 95% bound under `target`.
        /// 299 for 1%, 99 for 3%, 598 for 0.5% — the numbers behind the
        /// golden-set sizing, derived rather than copied.
        static func casesNeeded(forBound target: Double, confidence: Double = 0.95) -> Int {
            guard target > 0, target < 1, confidence > 0, confidence < 1 else { return .max }
            return Int(ceil(log(1 - confidence) / log(1 - target)))
        }

        /// Kept as a SECONDARY signal: it bounds hard failures (escalate/error),
        /// which are the cases the pipeline correctly refused. Useful for sizing
        /// how often the local model gives up, useless as a safety claim — a
        /// wrong `verified` never appears in it.
        var hardFailureBound95: Double? {
            guard replayed >= Self.minimumForBound, hardFailures == 0 else { return nil }
            return 1 - pow(0.05, 1.0 / Double(replayed))
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
        func entry(kind: String, status: String, reason: String,
                   localChars: Int = 0, askChars: Int = 0, askSHA: String? = nil) -> Entry {
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
                localCharacters: localChars,
                schemaVersion: Entry.currentSchemaVersion,
                // Shadow replay runs on the EMBEDDED model on purpose — it
                // measures this Mac, not the Proxmox box. The server-side
                // generation fields therefore stay nil: they do not apply here,
                // and a zero would read as a measurement.
                backend: LocalWorkerBackend.embedded.rawValue,
                model: EmbeddedModelRuntime.modelID,
                weightQuant: "Q4",
                promptVersion: LocalDelegationService.promptVersion,
                sourceSHA256: askSHA,
                stage: Stage.exploratory.rawValue,
                population: Population.naturalistic.rawValue,
                // Adjudication is a human act against the original source. It
                // stays nil until someone does it, which is exactly why a fresh
                // replay contributes nothing to the certification bound.
                adjudicatedStatus: nil
            )
        }

        func sha256(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
                         askChars: boundedAsk.count, askSHA: sha256(boundedAsk))
        }

        do {
            let result = try await EmbeddedModelRuntime.shared.delegate(
                source: boundedAsk,
                objective: "Produce exactly the artifact this developer request asks for, using SOURCE alone.",
                kind: kind
            )
            return entry(kind: kind.rawValue, status: result.status, reason: result.reason,
                         localChars: result.returnedCharacters, askChars: boundedAsk.count,
                         askSHA: sha256(boundedAsk))
        } catch {
            return entry(kind: kind.rawValue, status: "error",
                         reason: error.localizedDescription, askChars: boundedAsk.count,
                         askSHA: sha256(boundedAsk))
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
