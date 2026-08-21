import Foundation

/// Last measured context weight of each MCP server's tool list.
///
/// The probe (`MCPProbeService`) already measures the exact bytes of a server's
/// `tools/list` response — that JSON is what gets injected into the model's
/// context on *every* turn of *every* session where the server is enabled. But
/// the probe spawns processes, so it is user-triggered and its result used to
/// die with the view that showed it.
///
/// This cache keeps the last measurement on disk so the advisor can weigh a
/// server's context cost without spawning anything. Two numbers are kept, because
/// one alone misleads: the **floor** (tool names only, what a schema-deferring
/// client like Claude Code actually injects) and the **ceiling** (full schemas).
/// Measured 2026-08-22 on this Mac, hostinger-mcp: 201 tools → 9.8 KB of names but
/// 131 KB of schemas — a 13× spread.
///
/// Honesty rule: a server that has never been probed has **no** entry, and the
/// advisor must say "not measured" rather than guess from tool-name length. The
/// stored date is surfaced so a stale number reads as stale.
enum MCPSchemaCache {

    struct Entry: Sendable, Codable {
        /// Full `tools/list` JSON — the ceiling, paid when the client sends complete
        /// tool schemas.
        let bytes: Int
        /// `mcp__<server>__<tool>` names only — the floor, paid when the client
        /// defers schemas and lists names (Claude Code's behaviour). Optional so an
        /// entry written before this field existed still decodes.
        let nameBytes: Int?
        let tools: Int
        let measuredAt: Date
        /// Dense-JSON token estimate — same ratio the probe UI reports.
        var tokensEst: Int { TokenEstimate.fromBytes(bytes, kind: .dense) }
        /// The floor, when it was measured.
        var nameTokensEst: Int? { nameBytes.map { TokenEstimate.fromBytes($0, kind: .dense) } }
        var age: TimeInterval { Date().timeIntervalSince(measuredAt) }
    }

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
    }
    private static var fileURL: URL { appSupport.appendingPathComponent("mcp-schema-weight.json") }

    /// Merge a probe run into the cache. Only healthy probes carry a measurement;
    /// a failed probe leaves any previous number untouched rather than erasing it
    /// (a server that would not spawn today still cost what it cost yesterday).
    static func record(_ results: [MCPProbeResult]) {
        var table = load()
        let now = Date()
        for r in results {
            guard r.status == .healthy, let bytes = r.schemaBytes, let tools = r.toolCount else { continue }
            table[r.server] = Entry(bytes: bytes, nameBytes: r.nameBytes, tools: tools, measuredAt: now)
        }
        guard !table.isEmpty else { return }
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(table) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return table
    }

    /// Total measured context weight across the servers named, in bytes. Servers
    /// with no measurement contribute nothing — the total is a floor, not a truth.
    static func measuredTotalBytes(of names: [String]) -> Int {
        let table = load()
        return names.compactMap { table[$0]?.bytes }.reduce(0, +)
    }
}
