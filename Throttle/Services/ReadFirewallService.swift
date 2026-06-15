import Foundation

/// Read-Firewall audit (Connections/Context pillar). Greps the transcripts for
/// `Read` tool calls and finds large files the agent brute-reads repeatedly —
/// the classic 200k-context drain. Throttle is the *shield*, not the engine: it
/// detects the waste and recommends routing those reads through an existing
/// local-RAG MCP (mcp-local-rag), which returns snippets instead of whole files.
/// It never builds a RAG or edits anything.
struct BruteRead: Sendable, Identifiable {
    let id: String       // path
    let name: String
    let project: String
    let reads: Int
    let lines: Int
    var wasteScore: Int { reads * lines }
}

struct ReadFirewallReport: Sendable {
    let files: [BruteRead]
    static let empty = ReadFirewallReport(files: [])

    /// Ready-to-paste MCP config recommending the local-RAG read firewall.
    static let mcpSnippet = """
    "mcp-local-rag": {
      "command": "npx",
      "args": ["-y", "mcp-local-rag"],
      "env": { "BASE_DIR": "." }
    }
    """
}

enum ReadFirewallService {
    static let minReads = 3
    static let minLines = 300

    // MARK: - Auto-config (opt-in): install the local-RAG read firewall

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Global MCP config (where Claude Code keeps `mcpServers`).
    private static var globalConfig: URL { home.appendingPathComponent(".claude.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }
    static let serverKey = "mcp-local-rag"

    /// The third-party local-RAG MCP we install (runs via npx; no daemon).
    /// Computed (not a stored static) so it carries no shared mutable state.
    static func serverConfig() -> [String: Any] {
        ["command": "npx", "args": ["-y", "mcp-local-rag"], "env": ["BASE_DIR": "."]]
    }

    static func isInstalled() -> Bool {
        guard let dict = readJSON(globalConfig),
              let mcp = dict["mcpServers"] as? [String: Any] else { return false }
        return mcp[serverKey] != nil
    }

    /// Add the read-firewall MCP to the GLOBAL config, backed up first. Idempotent.
    /// Returns true if it wrote (false if already present). Restart Claude Code to load it.
    @discardableResult
    static func install() throws -> Bool {
        guard var dict = readJSON(globalConfig) else { throw FirewallError.noConfig }
        var mcp = dict["mcpServers"] as? [String: Any] ?? [:]
        guard mcp[serverKey] == nil else { return false }
        try backup(globalConfig)
        mcp[serverKey] = serverConfig()
        dict["mcpServers"] = mcp
        try writeJSON(dict, to: globalConfig)
        return true
    }

    /// Reverse install: splice out the read-firewall MCP (only if it's ours), backed up.
    static func remove() throws {
        guard var dict = readJSON(globalConfig),
              var mcp = dict["mcpServers"] as? [String: Any], mcp[serverKey] != nil else { return }
        try backup(globalConfig)
        mcp.removeValue(forKey: serverKey)
        dict["mcpServers"] = mcp
        try writeJSON(dict, to: globalConfig)
    }

    enum FirewallError: Error { case noConfig }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func writeJSON(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    private static func backup(_ url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = backupsDir.appendingPathComponent("claude.json-\(stamp).bak")
        if fm.fileExists(atPath: url.path) { try? fm.copyItem(at: url, to: dest) }
        return dest
    }

    static func scan() -> ReadFirewallReport {
        let counts = readCounts()
        guard !counts.isEmpty else { return .empty }
        let fm = FileManager.default
        var out: [BruteRead] = []
        // Only stat the most-read candidates to bound IO.
        for (path, reads) in counts.sorted(by: { $0.value > $1.value }).prefix(60) where reads >= minReads {
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let lines = content.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            guard lines >= minLines else { continue }
            let url = URL(fileURLWithPath: path)
            let project = (url.deletingLastPathComponent().lastPathComponent)
            out.append(BruteRead(id: path, name: url.lastPathComponent, project: project, reads: reads, lines: lines))
        }
        return ReadFirewallReport(files: out.sorted { $0.wasteScore > $1.wasteScore }.prefix(20).map { $0 })
    }

    /// Count `{"name":"Read","input":{"file_path":"X"}}` across transcripts via grep.
    private static func readCounts() -> [String: Int] {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-rhoE", "\"name\":\"Read\",\"input\":\\{\"file_path\":\"[^\"]+\"", projects]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var counts: [String: Int] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            guard let r = line.range(of: "\"file_path\":\"") else { continue }
            let path = String(line[r.upperBound...].prefix { $0 != "\"" })
            if !path.isEmpty { counts[path, default: 0] += 1 }
        }
        return counts
    }
}
