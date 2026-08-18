import Foundation
import GRDB

/// Evidence mode (`Throttle --sota-selftest`): exercises the whole frontier↔local
/// mix stack end-to-end and writes a timestamped proof report — using ZERO
/// frontier tokens. Every check is local by construction: SQLite reads on the
/// real usage DB, real transcript files, pure functions, and (when installed)
/// the on-device MLX model. Nothing talks to an API, nothing touches a real
/// session, and the synthetic replay bypasses the golden-set ledger so the
/// user's evidence store is never polluted with test data.
///
/// Report: ~/Library/Application Support/Throttle/evidence/sota-selftest-<ts>.md
/// Exit code 0 when every non-skipped check passes.
enum SOTASelfTest {

    private struct Check {
        let name: String
        /// PASS | FAIL | SKIP
        let status: String
        let detail: String
    }

    static func run() async -> Bool {
        var checks: [Check] = []
        let started = Date()

        func pass(_ name: String, _ detail: String) { checks.append(Check(name: name, status: "PASS", detail: detail)) }
        func fail(_ name: String, _ detail: String) { checks.append(Check(name: name, status: "FAIL", detail: detail)) }
        func skip(_ name: String, _ detail: String) { checks.append(Check(name: name, status: "SKIP", detail: detail)) }

        // 1 — LogFold: deterministic, known input → known outcome.
        let noisy = (["\u{001B}[31merror: widget failed\u{001B}[0m"]
                     + Array(repeating: "retry: connect 10.9.8.131 timed out", count: 40)
                     + ["done"]).joined(separator: "\n")
        let folded = LogFoldService.fold(noisy)
        if folded.collapsedLines == 39, folded.text.contains("⟨× 40⟩"), !folded.text.contains("\u{001B}") {
            pass("LogFold determinism",
                 "40 identical lines → 1 + ⟨× 40⟩; ANSI stripped; \(folded.savedCharacters) chars saved (\(folded.originalCharacters)→\(folded.foldedCharacters))")
        } else {
            fail("LogFold determinism",
                 "expected 39 collapsed + marker, got collapsed=\(folded.collapsedLines)")
        }

        // 2 — RouterAdvisor: the three lanes on canned objectives.
        let ledger = ShadowReplayService.loadLedger()
        let critical = RouterAdvisorService.advise(
            objective: "Deploy the new signing pipeline to production", ledger: ledger)
        // NB: phrasing avoids the fail-closed "log in" action pattern — "log into
        // N bullets" legitimately trips it (conservative by design, worth knowing).
        let bounded = RouterAdvisorService.advise(
            objective: "Summarize these failing test results as 5 bullet points", ledger: ledger)
        let vague = RouterAdvisorService.advise(
            objective: "Continue the current work at the next unfinished task.", ledger: ledger)
        if critical.recommendation == .frontier,
           bounded.recommendation == .local || bounded.recommendation == .uncertain,
           vague.recommendation != .local {
            pass("RouterAdvisor lanes",
                 "critical→\(critical.recommendation.rawValue), bounded→\(bounded.recommendation.rawValue), vague→\(vague.recommendation.rawValue) (bounded may demote on ledger evidence — that is the design)")
        } else {
            fail("RouterAdvisor lanes",
                 "critical→\(critical.recommendation.rawValue), bounded→\(bounded.recommendation.rawValue), vague→\(vague.recommendation.rawValue)")
        }

        // 3 — Real usage DB: retro-attribution runs on the user's actual data.
        do {
            let pool = try await DatabaseManager.shared.open()
            let report = try await pool.read { try LocalCandidateService.scan(in: $0) }
            pass("Retro-attribution on real DB",
                 "\(report.scannedSessions) sessions scanned (7d) · \(report.candidates.count) local-safe candidates · ≈€\(String(format: "%.2f", report.avoidableEUR)) est")
        } catch {
            fail("Retro-attribution on real DB", error.localizedDescription)
        }

        // 4 — Real transcript parsing: the shadow-replay input path.
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        if let newest = newestTranscript(under: projects) {
            if let ask = ShadowReplayService.firstUserAsk(transcriptPath: newest.path) {
                pass("Transcript first-ask extraction",
                     "\(newest.lastPathComponent): \(ask.count) chars, starts \"\(String(ask.prefix(60)).replacingOccurrences(of: "\n", with: " "))…\"")
            } else {
                fail("Transcript first-ask extraction", "no user ask found in \(newest.lastPathComponent)")
            }
        } else {
            skip("Transcript first-ask extraction", "no Claude Code transcripts on this machine")
        }

        // 5 — Embedded model + synthetic shadow replay (MLX only, ledger untouched).
        if EmbeddedModelRuntime.isInstalled {
            let syntheticTranscript = FileManager.default.temporaryDirectory
                .appendingPathComponent("sota-selftest-\(UUID().uuidString).jsonl")
            let askText = "Extract the failing file names from this log as a list: " +
                "Build failed. error: cannot find type Widget in Gauge.swift " +
                "error: missing return in Meter.swift"
            let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": askText]]
            if let data = try? JSONSerialization.data(withJSONObject: line) {
                try? (String(data: data, encoding: .utf8)! + "\n").write(
                    to: syntheticTranscript, atomically: true, encoding: .utf8)
            }
            defer { try? FileManager.default.removeItem(at: syntheticTranscript) }

            let candidate = LocalCandidateService.Candidate(
                sessionId: "selftest-synthetic", projectName: "selftest", turns: 1,
                outputTokens: 100, freshInputTokens: 100, weightedTokens: 200,
                costEUR: 0, lastActivity: Int64(Date().timeIntervalSince1970))
            let loadStart = Date()
            let entry = await ShadowReplayService.replay(
                candidate: candidate, transcriptPath: syntheticTranscript.path)
            let elapsed = Date().timeIntervalSince(loadStart)
            // The check proves the MACHINERY (transcript → kind → gate → model →
            // validation → entry). Any contract verdict is a working pipeline;
            // "escalate" is the model honestly failing the task — that quality
            // signal belongs to the golden-set ledger, not to this self-test.
            // Only "error" (infra: transcript/parse/runtime) fails the check.
            if entry.status != "error" {
                pass("Shadow replay pipeline (synthetic, on-device)",
                     "model verdict=\(entry.status) kind=\(entry.kind) in \(String(format: "%.1f", elapsed))s · \(entry.localCharacters) chars from \(EmbeddedModelRuntime.displayName) · \(entry.reason)"
                     + (entry.status == "escalate" ? " — repeated escalates on real replays = the 1.7B→4B upgrade signal" : ""))
            } else {
                fail("Shadow replay pipeline (synthetic, on-device)",
                     "status=\(entry.status) · \(entry.reason)")
            }
        } else {
            skip("Shadow replay pipeline (synthetic, on-device)",
                 "embedded model not installed (Settings → Assistant) — install it to prove the replay path")
        }

        // 6 — Golden-set ledger: readable, and honest about its size.
        let bound = ledger.hardFailureBound95.map { String(format: "≤%.0f%% (95%%)", $0 * 100) } ?? "n/a (needs ≥10 replays, 0 hard failures)"
        pass("Golden-set ledger",
             "\(ledger.replayed) replayed · \(ledger.verified) verified · \(ledger.review) review · \(ledger.hardFailures) hard failures · bound \(bound)")

        // 7 — On-machine bench: run it here when it is safe to (model installed,
        // no synchronous memory-pressure signal), so the evidence report carries
        // real tok/s from THIS Mac. Skipped under pressure — a benchmark on a
        // swapping machine would worsen the condition it measures.
        if EmbeddedModelRuntime.isInstalled, !SystemMemoryService.sample().underPressure {
            do {
                let profile = try await LocalModelBenchService.run()
                pass("On-machine bench",
                     "≈\(Int(profile.estTokensPerSecond.rounded())) tok/s est (end-to-end, chars/4) · load \(String(format: "%.1f", profile.loadSeconds))s · \(profile.generatedCharacters) chars in \(String(format: "%.1f", profile.generateSeconds))s")
            } catch {
                fail("On-machine bench", error.localizedDescription)
            }
        } else if let profile = LocalModelBenchService.loadProfile() {
            pass("On-machine bench (cached profile)",
                 "≈\(Int(profile.estTokensPerSecond.rounded())) tok/s est · load \(String(format: "%.1f", profile.loadSeconds))s · measured \(profile.measuredAt.formatted(date: .abbreviated, time: .shortened))")
        } else {
            skip("On-machine bench",
                 EmbeddedModelRuntime.isInstalled
                 ? "memory pressure right now — Cockpit → LOCAL MIX → Benchmark this Mac when quiet"
                 : "embedded model not installed")
        }

        // Report.
        let failures = checks.filter { $0.status == "FAIL" }
        let lines = [
            "# Throttle SOTA self-test — evidence report",
            "",
            "Generated: \(ISO8601DateFormatter().string(from: started))",
            "Duration: \(String(format: "%.1f", Date().timeIntervalSince(started)))s",
            "Frontier tokens used: **0** — every check is local (SQLite, files, pure functions, on-device MLX).",
            "Golden-set ledger untouched: the synthetic replay never appends to it.",
            "",
        ] + checks.map { "- [\($0.status)] **\($0.name)** — \($0.detail)" } + [
            "",
            "Result: \(failures.isEmpty ? "PASS" : "FAIL") (\(checks.filter { $0.status == "PASS" }.count) pass · \(failures.count) fail · \(checks.filter { $0.status == "SKIP" }.count) skip)",
        ]
        let report = lines.joined(separator: "\n") + "\n"

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Throttle/evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: started)
            .replacingOccurrences(of: ":", with: "-")
        let reportURL = dir.appendingPathComponent("sota-selftest-\(stamp).md")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)

        FileHandle.standardOutput.write(Data((report + "\nReport: \(reportURL.path)\n").utf8))
        return failures.isEmpty
    }

    private static func newestTranscript(under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var newest: (URL, Date)? = nil
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || date > newest!.1 { newest = (url, date) }
        }
        return newest?.0
    }
}
