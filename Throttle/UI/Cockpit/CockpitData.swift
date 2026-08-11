import Foundation
import GRDB
import Observation

/// Everything the cockpit shows beyond the live snapshot: the session model split,
/// the recent-sessions list, and the local config "weight" (CLAUDE.md / skills /
/// hooks). Loaded off the main actor; every field is optional so the view can hide
/// what isn't real yet.
///
/// Per-session tokens/cost/model/burn used to live here too. Those moved to
/// `MultiCockpitModel` (per tab) and nothing ever read them from here again — the
/// queries kept running on the 10 s loop for nobody, so they were deleted rather
/// than left as a plausible-looking cell nobody renders.
struct CockpitData: Sendable {
    var modelSplit: [StatsDataService.ModelSlice]
    var config: ConfigWeight
    var sessions: [CockpitSession]

    static let empty = CockpitData(modelSplit: [], config: .empty, sessions: [])
}

/// One row in the cockpit's Sessions panel — analytics only.
struct CockpitSession: Sendable, Identifiable {
    let id: String
    let project: String?
    let projectPath: String?   // real cwd, so Resume can `cd` there first
    let lastActivity: Date
    let weightedTokens: Int
    let costEUR: Double?
    let topTier: ModelTier?
    let isCurrent: Bool
}

/// Real project cwd from a session JSONL path, by decoding the encoded folder.
/// `…/projects/-Users-kevin-GitHub-Throttle/<id>.jsonl` → `/Users/kevin/GitHub/Throttle`.
/// Lossy for paths whose components contain a dash; returns nil if it doesn't resolve.
func cockpitProjectPath(fromJSONLPath path: String) -> String? {
    let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let real = folder.replacingOccurrences(of: "-", with: "/")
    return FileManager.default.fileExists(atPath: real) ? real : nil
}

extension ModelTier {
    static func from(model: String) -> ModelTier {
        let l = model.lowercased()
        if l.contains("opus") { return .opus }
        if l.contains("sonnet") { return .sonnet }
        if l.contains("haiku") { return .haiku }
        return .other
    }
}

/// Derive a human project name from a session's JSONL path.
/// `~/.claude/projects/-Users-kevin-GitHub-Throttle/<id>.jsonl` → "Throttle".
/// Repo names containing dashes collapse to their last segment (acceptable v1).
func cockpitProjectName(fromJSONLPath path: String) -> String? {
    let encoded = (path as NSString).deletingLastPathComponent
    let folder = (encoded as NSString).lastPathComponent
    let parts = folder.split(separator: "-").map(String.init).filter { !$0.isEmpty }
    return parts.last
}

/// Local context cost-sources, read from `~/.claude`. Token figures are
/// estimates (≈250 tok per KB of always-injected text) and are labelled as such.
struct ConfigWeight: Sendable {
    var claudeMdTokens: Int?   // nil when no CLAUDE.md
    var mcpCount: Int
    var skillCount: Int
    /// Skill weight that IS on every prompt: only the frontmatter `description` of each
    /// skill is preloaded so the model can pick one. Measured, not assumed.
    var skillPreloadTokens: Int
    /// Skill weight that is NOT on the prompt until the skill is actually invoked.
    /// Reported separately so "N skills" stops reading as "N skills' worth of context".
    var skillDeferredTokens: Int
    /// Hooks run as local scripts — they cost zero context. Counted to make that visible.
    var hookCount: Int
    var outputStyleShadowing: OutputStyleShadowingDetector.Warning?

    static let empty = ConfigWeight(
        claudeMdTokens: nil, mcpCount: 0, skillCount: 0,
        skillPreloadTokens: 0, skillDeferredTokens: 0, hookCount: 0,
        outputStyleShadowing: nil
    )

    /// What the config actually costs on every single prompt of the session.
    var alwaysOnTokens: Int { (claudeMdTokens ?? 0) + skillPreloadTokens }

    var hasAnything: Bool {
        claudeMdTokens != nil || skillCount > 0 || hookCount > 0 || outputStyleShadowing != nil
    }
}

@MainActor
@Observable
final class CockpitViewModel {
    private(set) var data: CockpitData = .empty
    private(set) var mcp: [MCPHealth] = []
    private(set) var mcpProbing = false
    private(set) var dedup: DedupReport = .empty
    private(set) var memory: MemoryReport = .empty
    private(set) var memoryIndex: MemoryIndexReport = .empty
    private(set) var cache: CacheHygieneReport = .empty
    private(set) var cacheRecoverableEUR: Double = 0   // € re-written into a cache that should've been warm
    private(set) var cacheBustReport: CacheBustAnalyzer.Report? = nil   // WHY the cache got busted (model swap vs prefix churn)
    private(set) var skills: SkillReport = .empty
    private(set) var reads: ReadFirewallReport = .empty
    private(set) var firewallInstalled = ReadFirewallService.isInstalled()
    private(set) var firewallBusy = false
    private(set) var scopeCandidates: [SkillScopeService.Candidate] = []
    private(set) var scopeBusy = false
    private(set) var bloat: ContextBloat = .empty
    private(set) var memHealth: MemoryHealth = .unknown

    private weak var appState: AppState?
    private var loop: Task<Void, Never>?

    func start(appState: AppState) {
        self.appState = appState
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                await self?.sampleMemory()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        Task { [weak self] in await self?.probeMCP() }     // one probe on open
        Task { [weak self] in await self?.scanDedup() }     // one dedup scan on open
        Task { [weak self] in await self?.scanMemory() }    // one memory scan on open
        Task { [weak self] in await self?.scanMemoryIndex() } // MEMORY.md auto-load cap
        Task { [weak self] in await self?.scanCache() }     // one cache-hygiene scan on open
        Task { [weak self] in await self?.scanSkills() }    // one skill-usage scan on open
        Task { [weak self] in await self?.scanReads() }     // one read-firewall scan on open
        Task { [weak self] in await self?.scanScopeCandidates() } // skills usable in one project only
        Task { [weak self] in await self?.scanBloat() }     // one context-bloat scan on open
    }

    func stop() { loop?.cancel(); loop = nil }

    /// Scan project CLAUDE.md files for duplicated content (off-main, on-demand).
    func scanDedup() async {
        let report = await Task.detached(priority: .utility) { ConfigDedupService.scan() }.value
        dedup = report
    }

    /// Hoist a duplicated block to a shared skill + remove from CLAUDE.md
    /// (backed up first), then rescan.
    func hoistDedup(_ block: DuplicatedBlock) async {
        await Task.detached(priority: .utility) { ConfigDedupService.hoist(block) }.value
        await scanDedup()
    }

    /// Scan project memory dirs for stale files (off-main, on-demand).
    func scanMemory() async {
        let report = await Task.detached(priority: .utility) { MemoryCleanupService.scan() }.value
        memory = report
    }

    /// Scan MEMORY.md indexes for ones at/over the 200-line / 25 KB auto-load
    /// cap, where content silently won't reach Claude (off-main, on-demand).
    func scanMemoryIndex() async {
        let report = await Task.detached(priority: .utility) { MemoryCleanupService.scanIndexLoad() }.value
        memoryIndex = report
    }

    /// Audit prompt-cache hygiene of the local hooks (off-main, on-demand).
    func scanCache() async {
        let report = await Task.detached(priority: .utility) { CacheHygieneService.scan() }.value
        cache = report
        await scanRecoverableMiss()
    }

    /// Compute the Recoverable Miss Cost (€ wasted re-writing a cache that should
    /// have been warm) from usage.db (off-main, GRDB read is thread-safe).
    func scanRecoverableMiss() async {
        guard let db = appState?.database else { return }
        let result = await Task.detached(priority: .utility) { () -> (Double, CacheBustAnalyzer.Report?) in
            let eur = (try? db.read { try StatsDataService.recoverableMissCostEUR(in: $0).eur }) ?? 0
            let report = try? db.read { try CacheBustAnalyzer.analyze(in: $0) }
            return (eur, report)
        }.value
        cacheRecoverableEUR = result.0
        cacheBustReport = result.1
    }

    /// Cross-ref installed skills vs invocation counts in transcripts (off-main).
    func scanSkills() async {
        let report = await Task.detached(priority: .utility) { SkillUsageService.scan() }.value
        skills = report
    }

    /// Archive a dead skill (reversible move) then rescan.
    func archiveSkill(_ name: String) async {
        await Task.detached(priority: .utility) { try? SkillUsageService.archive(skillName: name) }.value
        await scanSkills()
    }

    /// Audit transcripts for brute-read large files (off-main).
    func scanReads() async {
        let report = await Task.detached(priority: .utility) { ReadFirewallService.scan() }.value
        reads = report
    }

    /// Find global skills used in exactly one project — candidates to scope there
    /// so they stop taxing every other session (off-main, on-demand).
    func scanScopeCandidates() async {
        let cands = await Task.detached(priority: .utility) { SkillScopeService.scopeCandidates() }.value
        scopeCandidates = cands
    }

    /// Scope every single-project skill into its project (reversible file move),
    /// then rescan. Stops on the first error but keeps what already moved.
    func scopeAllCandidates() async {
        guard !scopeBusy else { return }
        scopeBusy = true
        let cands = scopeCandidates
        await Task.detached(priority: .utility) {
            for c in cands { _ = try? SkillScopeService.scope(skillDir: c.skillDir, toProject: c.project) }
        }.value
        scopeBusy = false
        await scanScopeCandidates()
        await scanSkills()
    }

    /// Install the local-RAG read firewall into the global MCP config (backed up,
    /// reversible). Opt-in — it adds a third-party npx server. Restart Claude Code after.
    func installFirewall() async {
        firewallBusy = true
        await Task.detached(priority: .utility) { try? ReadFirewallService.install() }.value
        firewallInstalled = ReadFirewallService.isInstalled()
        firewallBusy = false
    }

    func removeFirewall() async {
        firewallBusy = true
        await Task.detached(priority: .utility) { try? ReadFirewallService.remove() }.value
        firewallInstalled = ReadFirewallService.isInstalled()
        firewallBusy = false
    }

    /// Sample system-memory health (off-main) — the machine-capacity half of the
    /// keep-going decision. Cheap (mach stats + one `ps`).
    func sampleMemory() async {
        let h = await Task.detached(priority: .utility) { SystemMemoryService.sample() }.value
        memHealth = h
    }

    /// Detect base64 image bloat in transcripts (off-main).
    func scanBloat() async {
        let report = await Task.detached(priority: .utility) { ContextBloatService.scan() }.value
        bloat = report
    }

    // MARK: - Surgical Context Trimmer (CMV brick 3)

    private(set) var trimCandidates: [ContextTrimmerService.Plan] = []
    private(set) var trimScanning = false
    private(set) var trimBusy: String?     // session stem currently being applied
    private(set) var trimNote: String?     // transient result line for the sheet

    /// Lazily find trimmable PAST sessions. Heavy (per-session preview), so it
    /// runs only when the user opens the trim sheet — never on the reload timer.
    func scanTrim(aggressive: Bool = false) async {
        trimScanning = true
        defer { trimScanning = false }
        let exclude = currentSessionId()
        let opt: ContextTrimmerService.Options = aggressive ? .aggressive : .safe
        trimCandidates = await Task.detached(priority: .utility) {
            ContextTrimmerService.scanCandidates(excludingSessionId: exclude, options: opt)
        }.value
    }

    /// Apply a reversible trim to one past session (backup kept), then refresh
    /// so the now-light session drops out of the candidate list.
    func applyTrim(_ plan: ContextTrimmerService.Plan, aggressive: Bool = false) async {
        trimBusy = plan.sessionShort
        defer { trimBusy = nil }
        let exclude = currentSessionId()
        let opt: ContextTrimmerService.Options = aggressive ? .aggressive : .safe
        let url = plan.sessionURL
        trimNote = await Task.detached(priority: .utility) {
            do {
                let (p, backup) = try ContextTrimmerService.apply(url, options: opt, currentSessionId: exclude)
                let mb = Double(p.bytesSaved) / 1_048_576
                return String(format: "Trimmed %d imgs · saved %.1f MB — backup kept (%@)",
                              p.imagesTrimmed, mb, backup.lastPathComponent)
            } catch {
                return (error as? ContextTrimmerService.TrimError)?.errorDescription
                    ?? error.localizedDescription
            }
        }.value
        await scanTrim(aggressive: aggressive)
        await scanBloat()
    }

    private func currentSessionId() -> String? {
        guard let db = appState?.database else { return nil }
        return (try? db.read { try StatsDataService.cockpitCurrentSessionId(in: $0) }) ?? nil
    }

    /// Archive stale memory files (reversible move) then rescan.
    func archiveMemory(_ paths: [String]) async {
        await Task.detached(priority: .utility) { MemoryCleanupService.archive(paths: paths) }.value
        await scanMemory()
    }

    /// On-demand MCP probe (never on the reload timer — spawning servers is heavy).
    func probeMCP() async {
        guard !mcpProbing else { return }
        mcpProbing = true
        let results = await MCPHealthService.probeAll()
        mcp = results
        ThrottleMCPHealthStore.write(results)   // share to the --mcp-server CLI for get_mcp_health_status
        mcpProbing = false
    }

    func reload() async {
        guard let appState else { return }
        let db = appState.database
        let loaded = await Task.detached(priority: .utility) {
            CockpitData.load(db: db)
        }.value
        self.data = loaded
    }
}

extension CockpitData {
    /// Off-main loader. Never throws — a failed query degrades to nil so the
    /// view hides that cell instead of showing a wrong number.
    static func load(db: any DatabaseReader) -> CockpitData {
        var out = CockpitData.empty
        var activeProjectURL: URL?
        try? db.read { db in
            let sid = try StatsDataService.cockpitCurrentSessionId(in: db)
            if let sid {
                out.modelSplit = (try? StatsDataService.cockpitModelSplitForSession(in: db, sessionId: sid)) ?? []
                // Still needed: the active project scopes the config-weight read.
                activeProjectURL = (try? StatsDataService.cockpitSessionPath(in: db, sessionId: sid))
                    .flatMap { $0 }
                    .flatMap(cockpitProjectPath(fromJSONLPath:))
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
            }

            let recents = (try? StatsDataService.cockpitRecentSessions(in: db, limit: 6)) ?? []
            out.sessions = recents.map { r in
                let cost = try? StatsDataService.cockpitSessionCostEUR(in: db, sessionId: r.id)
                let split = (try? StatsDataService.cockpitModelSplitForSession(in: db, sessionId: r.id)) ?? []
                let top = split.max { $0.weightedTokens < $1.weightedTokens }?.tier
                let jsonl = (try? StatsDataService.cockpitSessionPath(in: db, sessionId: r.id)).flatMap { $0 }
                let project = jsonl.flatMap(cockpitProjectName(fromJSONLPath:))
                let projectPath = jsonl.flatMap(cockpitProjectPath(fromJSONLPath:))
                return CockpitSession(
                    id: r.id, project: project, projectPath: projectPath,
                    lastActivity: Date(timeIntervalSince1970: Double(r.lastActivity)),
                    weightedTokens: r.weightedTokens, costEUR: cost,
                    topTier: top, isCurrent: r.id == sid
                )
            }
        }
        out.config = ConfigWeight.read(activeProjectURL: activeProjectURL)
        return out
    }
}

extension ConfigWeight {
    /// Read `~/.claude` for CLAUDE.md size, MCP server count, skill count.
    static func read(activeProjectURL: URL? = nil) -> ConfigWeight {
        let fm = FileManager.default
        let claude = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)

        // CLAUDE.md → ~250 tokens per KB (always-injected prelude).
        var claudeMdTokens: Int?
        let mdURL = claude.appendingPathComponent("CLAUDE.md")
        if let size = try? mdURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            claudeMdTokens = (size * 250) / 1024
        }

        // MCP servers: Claude Code stores them in ~/.claude.json (`mcpServers`),
        // older/other setups use ~/.claude/settings.json. Union the keys.
        var mcpKeys = Set<String>()
        let home = fm.homeDirectoryForCurrentUser
        for url in [home.appendingPathComponent(".claude.json"),
                    claude.appendingPathComponent("settings.json")] {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mcps = obj["mcpServers"] as? [String: Any] {
                mcpKeys.formUnion(mcps.keys)
            }
        }
        let mcpCount = mcpKeys.count

        // Skills: each subdirectory of ~/.claude/skills. A skill is NOT one lump of
        // context — only its frontmatter `description` is preloaded (so the model can
        // choose it); the SKILL.md body lands in the prompt only when it's invoked.
        // Measure both halves off disk rather than printing a bare count that reads
        // like the whole thing is always resident.
        var skillCount = 0
        var skillPreloadTokens = 0
        var skillDeferredTokens = 0
        let skillsURL = claude.appendingPathComponent("skills", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: skillsURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for dir in items where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                skillCount += 1
                guard let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
                else { continue }
                let (preload, body) = Self.splitSkillFrontmatter(text)
                skillPreloadTokens += preload.count / 4
                skillDeferredTokens += body.count / 4
            }
        }

        // Hooks are local scripts: they execute on this Mac and cost zero context.
        var hookCount = 0
        if let data = try? Data(contentsOf: claude.appendingPathComponent("settings.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooks = obj["hooks"] as? [String: Any] {
            hookCount = hooks.values.compactMap { ($0 as? [Any])?.count }.reduce(0, +)
        }

        return ConfigWeight(
            claudeMdTokens: claudeMdTokens,
            mcpCount: mcpCount,
            skillCount: skillCount,
            skillPreloadTokens: skillPreloadTokens,
            skillDeferredTokens: skillDeferredTokens,
            hookCount: hookCount,
            outputStyleShadowing: OutputStyleShadowingDetector.detect(projectURL: activeProjectURL)
        )
    }

    /// Split a SKILL.md into (always-preloaded discovery text, invoke-only body).
    /// The preloaded half is the YAML frontmatter — in practice its `description`
    /// line — delimited by the leading `---` / `---` pair.
    static func splitSkillFrontmatter(_ text: String) -> (preload: String, body: String) {
        guard text.hasPrefix("---") else { return ("", text) }
        let afterOpen = text.dropFirst(3)
        guard let close = afterOpen.range(of: "\n---") else { return ("", text) }
        return (String(afterOpen[afterOpen.startIndex..<close.lowerBound]),
                String(afterOpen[close.upperBound...]))
    }
}
