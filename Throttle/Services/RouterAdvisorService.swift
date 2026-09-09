import Foundation

/// Prospective router advisory — the third leg of the 2026-08 mix architecture
/// (retro-attribution looks back, shadow replay measures, this one advises at
/// the only decision point that is cache-safe: a NEW task/session boundary).
///
/// Three outputs, never two: `local` / `frontier` / `uncertain` — and uncertain
/// resolves to frontier by policy. This is deliberately NOT a learned router:
/// generic routers degrade out-of-distribution, and a small model's
/// self-confidence is not a safety statement. Deterministic rules derived from
/// the research's feature table decide; the user's own shadow-replay ledger is
/// the only "learning" input, because it is the only evidence that is actually
/// about *their* tasks. Advisory only — it never routes anything by itself.
enum RouterAdvisorService {

    enum Recommendation: String, Sendable {
        case local, frontier, uncertain
        var label: String {
            switch self {
            case .local: return "Local-safe (est)"
            case .frontier: return "Frontier"
            case .uncertain: return "Uncertain → Frontier"
            }
        }
    }

    /// What leaving a warm session would cost. Caches are model-scoped, so a
    /// detour to another model does not read the context that is already paid
    /// for; coming back rebuilds it at the write rate. The number is the
    /// session's own context repriced, not an average.
    struct Detour: Sendable, Equatable {
        let contextTokens: Int
        let strandedEUR: Double

        var line: String {
            let tokens = contextTokens >= 1_000
                ? "\(contextTokens / 1_000)k" : "\(contextTokens)"
            return String(format: "leaving this session strands %@ of warm context (~€%.2f to rebuild)",
                          tokens, strandedEUR)
        }
    }

    struct Advice: Sendable, Equatable {
        let recommendation: Recommendation
        let reasons: [String]
        /// Personal evidence line from the shadow-replay ledger, when any exists
        /// for this family of ask ("11 replays, 0 hard failures").
        let history: String?
        /// Present only when the advice was given inside a session that already
        /// holds a warm cache — what a detour would throw away.
        let detour: Detour?

        init(recommendation: Recommendation, reasons: [String],
             history: String? = nil, detour: Detour? = nil) {
            self.recommendation = recommendation
            self.reasons = reasons
            self.history = history
            self.detour = detour
        }
    }

    /// Below this, the warm context is not worth protecting: rebuilding it costs
    /// less than the awkwardness of refusing a reasonable local detour.
    static let sessionAffinityFloor = 5_000

    // Signals from the research's feature table. Criticality and breadth force
    // frontier; only a bounded artifact class with no counter-signal earns local.
    private static let criticalityMarkers = [
        "security", "sécurité", "credential", "secret", "deploy", "publish",
        "notarize", "migration", "migrate", "drop table", "delete", "supprime",
        "production", "release", "signing", "keychain"
    ]
    private static let breadthMarkers = [
        "refactor", "repo", "codebase", "all files", "tous les fichiers",
        "across", "architecture", "debug", "diagnose", "pourquoi", "why",
        "race condition", "crash", "multi-file", "migrate", "investigate"
    ]
    private static let artifactMarkers = [
        "summarize", "summary", "résume", "résumé", "tl;dr", "extract",
        "extrais", "classify", "classifie", "title", "titre", "commit message",
        "list the", "liste les", "normalize", "convert", "json"
    ]

    /// Pure and fast — safe to call on every keystroke of an objective field.
    /// `ledger` is injected so callers load it once, not per keypress.
    /// `session` is the live session's cache position, when the ask is being
    /// made inside one. Passing it turns on session affinity: the advice may
    /// still be local at a session boundary, but never in the middle of a
    /// conversation whose warm context a detour would strand.
    static func advise(objective: String,
                       ledger: ShadowReplayService.Ledger = ShadowReplayService.loadLedger(),
                       session: PromptCacheImpact? = nil) -> Advice {
        let advice = judge(objective: objective, ledger: ledger)
        return applyingSessionAffinity(advice, session: session)
    }

    /// Session affinity, applied after the judgement rather than inside it, so
    /// the rules stay readable and the cost is stated rather than hidden in a
    /// verdict. It only ever moves advice towards frontier.
    static func applyingSessionAffinity(_ advice: Advice, session: PromptCacheImpact?) -> Advice {
        guard let session, session.contextTokens >= sessionAffinityFloor else { return advice }
        let detour = Detour(contextTokens: session.contextTokens, strandedEUR: session.rebuildEUR)
        guard advice.recommendation == .local else {
            return Advice(recommendation: advice.recommendation, reasons: advice.reasons,
                          history: advice.history, detour: detour)
        }
        return Advice(
            recommendation: .frontier,
            reasons: [detour.line + " — route between sessions, not inside one"] + advice.reasons,
            history: advice.history, detour: detour
        )
    }

    private static func judge(objective: String,
                              ledger: ShadowReplayService.Ledger) -> Advice {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 12 else {
            return Advice(recommendation: .uncertain,
                          reasons: ["objective too short to judge"], history: nil)
        }
        let lower = text.lowercased()
        var reasons: [String] = []

        // 1 — criticality: never local, whatever else matches (product policy).
        if let hit = criticalityMarkers.first(where: lower.contains) {
            return Advice(recommendation: .frontier,
                          reasons: ["high-stakes work (\"\(hit)\") stays frontier by policy"],
                          history: nil)
        }
        // Same fail-closed gate as live delegation (action-oriented asks).
        if case .escalate(let why) = LocalDelegationService.assess(
            kind: LocalDelegationService.TaskKind.draft.rawValue,
            objective: String(text.prefix(1_800))
        ) {
            return Advice(recommendation: .frontier, reasons: [why], history: nil)
        }

        // 2 — breadth/ambiguity: multi-file or causal work exceeds a small model.
        let breadthHits = breadthMarkers.filter(lower.contains)
        let pathLikeTokens = lower.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .filter { $0.contains("/") || $0.hasSuffix(".swift") || $0.hasSuffix(".ts") }
        if !breadthHits.isEmpty {
            reasons.append("multi-file / causal signals: \(breadthHits.prefix(3).joined(separator: ", "))")
        }
        if pathLikeTokens.count > 4 {
            reasons.append("\(pathLikeTokens.count) file references — cross-file context")
        }

        // 3 — bounded artifact class: the only positive local signal.
        let artifactHits = artifactMarkers.filter(lower.contains)
        let bounded = !artifactHits.isEmpty && text.count <= 1_200

        let kind = ShadowReplayService.inferKind(ask: text)
        let history = historyLine(for: kind, ledger: ledger)

        if !reasons.isEmpty {
            return Advice(recommendation: .frontier, reasons: reasons, history: history)
        }
        if bounded {
            // The personal ledger can only DEMOTE, never promote past evidence:
            // a hard failure on this family caps the advice at uncertain.
            let family = ledger.entries.filter { $0.kind == kind.rawValue }
            let hardFail = family.filter { $0.status == "escalate" || $0.status == "error" }.count
            if hardFail > 0 {
                return Advice(recommendation: .uncertain,
                              reasons: ["bounded artifact ask, but \(hardFail) hard failure(s) on \(kind.rawValue)-type replays"],
                              history: history)
            }
            return Advice(recommendation: .local,
                          reasons: ["bounded artifact ask (\(artifactHits.prefix(2).joined(separator: ", ")))"],
                          history: history)
        }
        return Advice(recommendation: .uncertain,
                      reasons: ["no bounded-artifact signal — frontier by policy"],
                      history: history)
    }

    private static func historyLine(for kind: LocalDelegationService.TaskKind,
                                    ledger: ShadowReplayService.Ledger) -> String? {
        let family = ledger.entries.filter { $0.kind == kind.rawValue }
        guard !family.isEmpty else { return nil }
        let hard = family.filter { $0.status == "escalate" || $0.status == "error" }.count
        return "shadow replay, \(kind.rawValue)-type: \(family.count) replayed · \(hard) hard failure(s)"
    }
}
