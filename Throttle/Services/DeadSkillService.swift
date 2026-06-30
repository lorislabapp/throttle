import Foundation

/// Audits Claude Code transcripts for "Dead Skills" — MCP servers and skills that
/// are LOADED into every session (paying their schema-token tax) but went UNUSED
/// over a trailing window. Pure librarian/CFO: read-only, recommendation-only,
/// never purges anything. v3.0 blueprint, Pillar 2, Stage 1.
///
/// Usage comes from `~/.claude/projects/**/*.jsonl` tool_use blocks
/// (mcp__<server>__<tool>, and name=="Skill" with input.skill). "Dead = loaded ∧
/// 0 uses" is invariant to transcript double-counting (0 stays 0), so we skip the
/// expensive global uuid dedup and stay memory-safe over thousands of files.
struct DeadSkillRow: Sendable, Identifiable {
    let id = UUID()
    let name: String          // server name or skill slug
    let kind: Kind
    let uses: Int             // tool_use count over the window
    let lastUsed: Date?
    let loaded: Bool          // present in the current loadout
    var schemaTokensEst: Int? = nil   // ~schema-token tax (filled from a live probe)
    enum Kind: String, Sendable { case mcp = "MCP server", skill = "Skill" }
    var isDead: Bool { loaded && uses == 0 }
}

struct DeadSkillReport: Sendable {
    var rows: [DeadSkillRow] = []
    var filesScanned: Int = 0
    var windowDays: Int = 30
    var deadCount: Int { rows.filter(\.isDead).count }
    /// The CFO number: schema tokens paid every session for DEAD MCP servers
    /// (loaded ∧ 0 uses) whose cost we know from a probe. Skills are sized
    /// separately by SkillUsageService; this is the MCP-server side.
    var deadMCPTokens: Int {
        rows.filter { $0.isDead && $0.kind == .mcp }.compactMap(\.schemaTokensEst).reduce(0, +)
    }
}

enum DeadSkillService {

    /// Audit against a loadout (from ClaudeSetupService). Off-main caller.
    static func audit(loadout: ClaudeSetup, windowDays: Int = 30, fileCap: Int = 6000) -> DeadSkillReport {
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let (mcpUses, mcpLast, skillUses, skillLast, scanned) = tally(since: cutoff, fileCap: fileCap)

        var rows: [DeadSkillRow] = []
        // Loaded MCP servers (the schema-tax payers).
        for m in loadout.mcp {
            rows.append(DeadSkillRow(name: m.name, kind: .mcp,
                                     uses: mcpUses[m.name] ?? 0, lastUsed: mcpLast[m.name],
                                     loaded: true))
        }
        // Loaded skills.
        for s in loadout.skills {
            rows.append(DeadSkillRow(name: s.name, kind: .skill,
                                     uses: skillUses[s.name] ?? 0, lastUsed: skillLast[s.name],
                                     loaded: true))
        }
        // Dead first, then least-used, then by name — the remediation order.
        rows.sort {
            if $0.isDead != $1.isDead { return $0.isDead && !$1.isDead }
            if $0.uses != $1.uses { return $0.uses < $1.uses }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return DeadSkillReport(rows: rows, filesScanned: scanned, windowDays: windowDays)
    }

    /// Fold a live probe pass (server name → estimated schema tokens) onto an
    /// existing audit, so the UI can surface "≈N tokens/session paid for dead
    /// servers" without re-scanning transcripts. Pure; only MCP rows change.
    static func folding(_ report: DeadSkillReport, withProbe tokensByServer: [String: Int]) -> DeadSkillReport {
        var r = report
        r.rows = r.rows.map { row in
            guard row.kind == .mcp, let est = tokensByServer[row.name] else { return row }
            var m = row; m.schemaTokensEst = est; return m
        }
        return r
    }

    // MARK: - Transcript tally

    private static func tally(since cutoff: Date, fileCap: Int)
        -> (mcp: [String: Int], mcpLast: [String: Date], skill: [String: Int], skillLast: [String: Date], scanned: Int) {
        var mcp: [String: Int] = [:], skill: [String: Int] = [:]
        var mcpLast: [String: Date] = [:], skillLast: [String: Date] = [:]
        let fm = FileManager.default
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        guard let en = fm.enumerator(atPath: root) else { return (mcp, mcpLast, skill, skillLast, 0) }

        // Newest files first (most relevant), capped.
        var files: [(path: String, mtime: Date)] = []
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let full = (root as NSString).appendingPathComponent(rel)
            let mt = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? nil
            if let mt, mt >= cutoff { files.append((full, mt)) }
        }
        files.sort { $0.mtime > $1.mtime }
        if files.count > fileCap { files = Array(files.prefix(fileCap)) }

        for (path, _) in files {
            guard let data = fm.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // Cheap pre-filter before paying for JSON parse.
                guard line.contains("tool_use") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { continue }
                let ts = (obj["timestamp"] as? String).flatMap(parseTS)
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    guard let name = b["name"] as? String else { continue }
                    if name.hasPrefix("mcp__") {
                        let server = String(name.dropFirst(5).prefix(while: { $0 != "_" }))
                        // mcp__<server>__<tool> — server is up to the "__" separator.
                        let srv = serverName(from: name) ?? server
                        mcp[srv, default: 0] += 1
                        if let ts { mcpLast[srv] = max(mcpLast[srv] ?? .distantPast, ts) }
                    } else if name == "Skill" || name == "skills" {
                        if let input = b["input"] as? [String: Any],
                           let slug = (input["skill"] ?? input["command"]) as? String {
                            skill[slug, default: 0] += 1
                            if let ts { skillLast[slug] = max(skillLast[slug] ?? .distantPast, ts) }
                        }
                    }
                }
            }
        }
        return (mcp, mcpLast, skill, skillLast, files.count)
    }

    /// "mcp__app-store-connect__asc_list_apps" → "app-store-connect".
    private static func serverName(from full: String) -> String? {
        let body = full.dropFirst(5)            // drop "mcp__"
        guard let r = body.range(of: "__") else { return String(body) }
        return String(body[..<r.lowerBound])
    }

    // Used only from the single detached audit pass; ISO8601DateFormatter parsing
    // is thread-safe in practice and we never run two audits concurrently.
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
    private static func parseTS(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
}
