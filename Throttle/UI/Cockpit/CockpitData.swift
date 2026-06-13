import Foundation
import GRDB
import Observation

/// Everything the cockpit shows beyond the live snapshot: the current session's
/// tokens/cost/model-split, a recent burn sample for the forecast, and the local
/// config "weight" (CLAUDE.md / MCP / skills). Loaded off the main actor; every
/// field is optional so the view can hide what isn't real yet.
struct CockpitData: Sendable {
    var sessionTokens: Int?
    var sessionCostEUR: Double?
    var sessionMsgCount: Int?
    var allTimeCostEUR: Double?
    var modelSplit: [StatsDataService.ModelSlice]
    var burn: StatsDataService.BurnSample?
    var config: ConfigWeight
    var sessions: [CockpitSession]
    var currentModelTier: ModelTier?
    var currentModelName: String?   // pretty real name, for models outside opus/sonnet/haiku
    var currentSessionProject: String?  // which project the "latest session" belongs to

    static let empty = CockpitData(
        sessionTokens: nil, sessionCostEUR: nil, sessionMsgCount: nil,
        allTimeCostEUR: nil, modelSplit: [], burn: nil, config: .empty,
        sessions: [], currentModelTier: nil, currentModelName: nil, currentSessionProject: nil
    )

    /// Average weighted tokens per assistant turn this session (for msgs-left).
    var avgTokensPerMessage: Double? {
        guard let t = sessionTokens, let c = sessionMsgCount, c > 0, t > 0 else { return nil }
        return Double(t) / Double(c)
    }
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

/// Clean a raw model id into a display name for models outside opus/sonnet/haiku.
/// `claude-fable-5-20260601` → "Fable 5".
func prettyModelName(_ raw: String) -> String {
    var s = raw.lowercased()
    if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
    if let r = s.range(of: "-[0-9]{6,8}$", options: .regularExpression) { s.removeSubrange(r) }
    let parts = s.split(separator: "-").map { $0.capitalized }
    return parts.isEmpty ? raw : parts.joined(separator: " ")
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

    static let empty = ConfigWeight(claudeMdTokens: nil, mcpCount: 0, skillCount: 0)

    var hasAnything: Bool { claudeMdTokens != nil || skillCount > 0 }
}

@MainActor
@Observable
final class CockpitViewModel {
    private(set) var data: CockpitData = .empty
    private(set) var mcp: [MCPHealth] = []
    private(set) var mcpProbing = false
    private(set) var dedup: DedupReport = .empty
    private(set) var memory: MemoryReport = .empty
    private(set) var cache: CacheHygieneReport = .empty
    private(set) var skills: SkillReport = .empty

    private weak var appState: AppState?
    private var loop: Task<Void, Never>?

    func start(appState: AppState) {
        self.appState = appState
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        Task { [weak self] in await self?.probeMCP() }     // one probe on open
        Task { [weak self] in await self?.scanDedup() }     // one dedup scan on open
        Task { [weak self] in await self?.scanMemory() }    // one memory scan on open
        Task { [weak self] in await self?.scanCache() }     // one cache-hygiene scan on open
        Task { [weak self] in await self?.scanSkills() }    // one skill-usage scan on open
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

    /// Audit prompt-cache hygiene of the local hooks (off-main, on-demand).
    func scanCache() async {
        let report = await Task.detached(priority: .utility) { CacheHygieneService.scan() }.value
        cache = report
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
        mcpProbing = false
    }

    func reload() async {
        guard let appState else { return }
        let db = appState.database
        let allTime = data.allTimeCostEUR  // keep last good value if query fails
        let loaded = await Task.detached(priority: .utility) {
            CockpitData.load(db: db, previousAllTime: allTime)
        }.value
        self.data = loaded
    }
}

extension CockpitData {
    /// Off-main loader. Never throws — a failed query degrades to nil so the
    /// view hides that cell instead of showing a wrong number.
    static func load(db: any DatabaseReader, previousAllTime: Double?) -> CockpitData {
        var out = CockpitData.empty
        out.allTimeCostEUR = previousAllTime
        try? db.read { db in
            let sid = try StatsDataService.cockpitCurrentSessionId(in: db)
            if let sid {
                out.sessionTokens = try? StatsDataService.cockpitSessionTokens(in: db, sessionId: sid)
                out.sessionCostEUR = try? StatsDataService.cockpitSessionCostEUR(in: db, sessionId: sid)
                out.sessionMsgCount = try? StatsDataService.cockpitSessionMessageCount(in: db, sessionId: sid)
                out.modelSplit = (try? StatsDataService.cockpitModelSplitForSession(in: db, sessionId: sid)) ?? []
                out.currentSessionProject = (try? StatsDataService.cockpitSessionPath(in: db, sessionId: sid))
                    .flatMap { $0 }.flatMap(cockpitProjectName(fromJSONLPath:))
            }
            out.burn = try? StatsDataService.cockpitRecentBurn(in: db)
            out.allTimeCostEUR = (try? StatsDataService.extrapolatedCostEUR(in: db, range: .all)) ?? previousAllTime

            if let model = try? StatsDataService.cockpitCurrentModel(in: db) {
                out.currentModelTier = ModelTier.from(model: model)
                out.currentModelName = prettyModelName(model)
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
        out.config = ConfigWeight.read()
        return out
    }
}

extension ConfigWeight {
    /// Read `~/.claude` for CLAUDE.md size, MCP server count, skill count.
    static func read() -> ConfigWeight {
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

        // Skills: each subdirectory of ~/.claude/skills.
        var skillCount = 0
        let skillsURL = claude.appendingPathComponent("skills", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: skillsURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            skillCount = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        }

        return ConfigWeight(claudeMdTokens: claudeMdTokens, mcpCount: mcpCount, skillCount: skillCount)
    }
}
