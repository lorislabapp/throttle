import AppKit
import GRDB
import SwiftUI

extension MultiCockpitModel {
    /// Native identity and process generation are captured together. A result can
    /// only update the same generation, even if the query crosses a tab restart.
    func refreshStats() {
        guard let database = appState?.database else { return }
        let items = sessions.map(CockpitSessionProbe.init)
        guard !items.isEmpty else { return }
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                let codexRoot = URL.homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
                let codexURLs = items.contains(where: { $0.runtime == .codex })
                    ? CodexUsageService.recentRolloutURLs(root: codexRoot, now: Date()) : []
                return items.map {
                    Self.collectUsage($0, database: database, codexRoot: codexRoot, codexURLs: codexURLs)
                }
            }.value
            guard let self else { return }
            var changed = false
            for usage in results where self.applyUsage(usage, originals: items) {
                changed = true
            }
            if changed { self.persist() }
            self.recomputeSortOrder()
            self.recomputeActivityFilter()
        }
    }

    nonisolated static func collectUsage(
        _ item: CockpitSessionProbe, database: any DatabaseWriter,
        codexRoot: URL, codexURLs: [URL]
    ) -> CockpitSessionUsage {
        var usage = CockpitSessionUsage(id: item.id)
        if item.sessionId == nil || item.choosing, let root = item.root, let foreground = item.foreground {
            usage.owned = NativeSessionBinding.ownedTranscript(
                runtime: item.runtime, cwd: item.cwd, root: root, foregroundPID: foreground)
        }
        let costID = item.choosing ? usage.owned?.id ?? item.sessionId : item.sessionId ?? usage.owned?.id
        let recent = costID.flatMap {
            NativeSessionBinding.knownTranscript(runtime: item.runtime, id: $0, cwd: item.cwd, codexURLs: codexURLs)
        }
        usage.live = recent.map { Date().timeIntervalSince($0.modifiedAt) < 12 } ?? false
        usage.loop = item.runtime == .claudeCode
            ? (usage.live ? costID : nil).flatMap { LoopDetectorService.detect(cwd: item.cwd, sessionId: $0) } : nil
        guard let costID else { return usage }
        // Claude's usage database must never be presented as Codex session cost.
        if item.runtime == .claudeCode {
            usage.financial = try? database.read { connection in
                let eur = try? StatsDataService.cockpitSessionCostEUR(in: connection, sessionId: costID)
                let tokens = try? StatsDataService.cockpitSessionTokens(in: connection, sessionId: costID)
                let split = (try? StatsDataService.cockpitModelSplitForSession(in: connection, sessionId: costID)) ?? []
                let model = split.max { $0.weightedTokens < $1.weightedTokens }.flatMap { Self.modelName($0.tier) }
                let impact = try? PromptCacheImpactService.latest(in: connection, sessionId: costID)
                return CockpitSessionUsage.Financial(eur: eur, tokens: tokens, model: model, impact: impact)
            }
        } else {
            usage.progress = CodexProgressService.latest(
                sessionID: costID, cwd: item.cwd, sessionsRoot: codexRoot, rolloutURLs: codexURLs)
        }
        return usage
    }

    @discardableResult
    func applyUsage(_ usage: CockpitSessionUsage, originals: [CockpitSessionProbe]) -> Bool {
        guard let tab = sessions.first(where: { $0.id == usage.id }),
              let original = originals.first(where: { $0.id == usage.id }), original.matches(tab) else { return false }
        notifyModelChange(tab: tab, usage: usage)
        let financial = usage.financial
        if financial?.model != nil { tab.lastSeenModel = financial?.model }
        tab.eur = financial?.eur; tab.tokens = financial?.tokens; tab.model = financial?.model
        tab.promptCacheImpact = financial?.impact; tab.codexProgress = usage.progress
        tab.isLive = usage.live; tab.loopSignal = usage.loop
        return usage.owned.map { tab.bindOwnedTranscript($0) } ?? false
    }

    private func notifyModelChange(tab: CockpitTab, usage: CockpitSessionUsage) {
        guard let old = tab.lastSeenModel, let new = usage.financial?.model, old != new else { return }
        let wasConfirmed = tab.confirmedModelSwitchTarget.map { new.lowercased().contains($0.lowercased()) } ?? false
        let tokens = usage.financial?.tokens ?? 0
        if usage.live, tokens > 30_000, !wasConfirmed {
            CockpitNotifier.shared.notifyRule(
                title: "Model swap mid-session — \(tab.projectName)",
                body: """
                \(old) → \(new) with \(tokens / 1_000)k tokens of context: the prompt cache is per-model, \
                so this rebuilds it from scratch (often pricier than staying). Prefer finishing the task, \
                or offload to the box.
                """)
        }
        tab.confirmedModelSwitchTarget = nil
    }

    nonisolated static func modelName(_ tier: ModelTier) -> String? {
        switch tier {
        case .fable:  return "Fable"
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .other:  return nil
        }
    }

    /// Claude Code's project-dir encoding: EVERY non-alphanumeric character in
    /// the absolute cwd becomes `-` (so `/`, spaces, dots, accents all collapse
    /// to `-`). Matching this exactly is critical — "Opnsens Prod" → "…-Opnsens
    /// -Prod", not "…-Opnsens Prod". A mismatch unlinks the session and loses it.
    nonisolated static func claudeProjectDirName(_ cwd: String) -> String {
        // Iterate SCALARS, not Characters. Swift treats "É" as ONE Character even
        // when the filesystem stores it decomposed (E + U+0301), so mapping
        // Characters collapsed it to a single dash — while Claude Code, walking
        // code units, keeps the E and dashes only the accent. `/root/offload/Éclair`
        // resolved to `-root-offload--clair` here and `-root-offload-E-clair` there,
        // so an offloaded session died with "No conversation found with session ID":
        // the transcript sat in a directory claude never reads.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".unicodeScalars)
        return String(String.UnicodeScalarView(
            cwd.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
    }
}
