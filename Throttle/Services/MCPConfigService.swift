import Foundation

/// Full read/write manager for Claude Code **MCP server definitions** across the
/// three scopes Claude Code supports:
///   • user    — `~/.claude.json` → top-level `mcpServers`            (every project)
///   • local   — `~/.claude.json` → `projects[<path>].mcpServers`     (one project, private)
///   • project — `<path>/.mcp.json` → `mcpServers`                    (one project, shareable/committed)
///
/// Every write backs up the touched file to `~/.claude/throttle-backups/` first,
/// preserves ALL sibling keys, and is atomic. Sibling ordering may change
/// (Claude Code reads JSON order-independent); the original is always backed up.
///
/// Disable is uniform across scopes: the def is parked under a Throttle-owned
/// `throttleDisabledMcpServers` object in the SAME file/section, so a disabled
/// server is invisible to Claude Code yet fully reversible with one click. This
/// avoids relying on Claude Code's `disabledMcpjsonServers` list, which only
/// covers project `.mcp.json` servers and never user-scope ones.
///
/// Distinct from `MCPHealthService`, which only *probes* liveness. This service
/// is the only place in the app that WRITES MCP config.
enum MCPConfigService {

    // MARK: - Model

    enum Scope: Hashable, Sendable {
        case user
        case local(projectPath: String)
        case project(projectPath: String)   // <path>/.mcp.json

        var label: String {
            switch self {
            case .user:                  return "Global (all projects)"
            case .local(let p):          return "Project-local · \(URL(fileURLWithPath: p).lastPathComponent)"
            case .project(let p):        return "Project .mcp.json · \(URL(fileURLWithPath: p).lastPathComponent)"
            }
        }
        var shareable: Bool { if case .project = self { return true }; return false }
        var key: String {
            switch self {
            case .user:            return "user"
            case .local(let p):    return "local:\(p)"
            case .project(let p):  return "project:\(p)"
            }
        }
    }

    struct Entry: Identifiable, Hashable, Sendable {
        let name: String
        let scope: Scope
        let disabled: Bool
        let transport: String   // "stdio · <cmd>" or "HTTP · <host>"
        let rawData: Data       // the def object, JSON-serialized (for move/edit)
        var id: String { "\(scope.key)/\(name)" }
    }

    private static let disabledKey = "throttleDisabledMcpServers"
    private static let activeKey = "mcpServers"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }
    private static func mcpJSON(_ projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json")
    }

    // MARK: - List

    /// Every MCP server across all three scopes, active and disabled, sorted by
    /// scope then name.
    static func list() -> [Entry] {
        var out: [Entry] = []

        // user + local both live in ~/.claude.json
        if let root = readJSON(claudeJSON) {
            out += entries(from: root, scope: .user)
            if let projects = root["projects"] as? [String: Any] {
                for (path, v) in projects {
                    guard let pv = v as? [String: Any] else { continue }
                    if pv[activeKey] != nil || pv[disabledKey] != nil {
                        out += entries(from: pv, scope: .local(projectPath: path))
                    }
                }
            }
        }

        // project scope: <path>/.mcp.json for every known project path
        for path in knownProjectPaths() {
            let url = mcpJSON(path)
            guard let root = readJSON(url) else { continue }
            out += entries(from: root, scope: .project(projectPath: path))
        }

        return out.sorted {
            $0.scope.key == $1.scope.key ? $0.name < $1.name : $0.scope.key < $1.scope.key
        }
    }

    /// Project directories to scan for a `.mcp.json`: every project Claude Code
    /// knows about (keys under `projects`) that has one on disk.
    private static func knownProjectPaths() -> [String] {
        guard let root = readJSON(claudeJSON),
              let projects = root["projects"] as? [String: Any] else { return [] }
        let fm = FileManager.default
        return projects.keys.filter { fm.fileExists(atPath: mcpJSON($0).path) }.sorted()
    }

    private static func entries(from container: [String: Any], scope: Scope) -> [Entry] {
        var out: [Entry] = []
        if let active = container[activeKey] as? [String: Any] {
            for (name, def) in active {
                if let e = makeEntry(name: name, def: def, scope: scope, disabled: false) { out.append(e) }
            }
        }
        if let disabled = container[disabledKey] as? [String: Any] {
            for (name, def) in disabled {
                if let e = makeEntry(name: name, def: def, scope: scope, disabled: true) { out.append(e) }
            }
        }
        return out
    }

    private static func makeEntry(name: String, def: Any, scope: Scope, disabled: Bool) -> Entry? {
        guard let obj = def as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        let transport: String
        if let url = obj["url"] as? String {
            transport = "HTTP · " + (URL(string: url)?.host ?? url)
        } else if let cmd = obj["command"] as? String {
            transport = "stdio · " + cmd
        } else {
            transport = "unknown"
        }
        return Entry(name: name, scope: scope, disabled: disabled, transport: transport, rawData: data)
    }

    // MARK: - Mutations

    /// Enable/disable in place: park the def under `throttleDisabledMcpServers`
    /// (or move it back to `mcpServers`) within the same scope/section.
    static func setDisabled(_ entry: Entry, _ disabled: Bool) throws {
        guard disabled != entry.disabled else { return }
        try mutate(scope: entry.scope) { section in
            let (from, to) = disabled ? (activeKey, disabledKey) : (disabledKey, activeKey)
            guard var src = section[from] as? [String: Any], let def = src[entry.name] else { return }
            src.removeValue(forKey: entry.name)
            section[from] = src.isEmpty ? nil : src
            var dst = (section[to] as? [String: Any]) ?? [:]
            dst[entry.name] = def
            section[to] = dst
        }
    }

    /// Move a server to another scope, preserving its enabled/disabled state.
    /// Removes it from the source section, writes it into the destination.
    static func move(_ entry: Entry, to dest: Scope) throws {
        guard dest.key != entry.scope.key else { return }
        guard let def = try? JSONSerialization.jsonObject(with: entry.rawData) else { return }
        let bucket = entry.disabled ? disabledKey : activeKey
        // Write to destination first (so a mid-op failure never loses the def).
        try mutate(scope: dest) { section in
            var dst = (section[bucket] as? [String: Any]) ?? [:]
            dst[entry.name] = def
            section[bucket] = dst
        }
        // Then remove from source.
        try mutate(scope: entry.scope) { section in
            for k in [activeKey, disabledKey] {
                guard var d = section[k] as? [String: Any] else { continue }
                d.removeValue(forKey: entry.name)
                section[k] = d.isEmpty ? nil : d
            }
        }
    }

    /// Add a new server. `defJSON` is the raw def object (validated JSON).
    static func add(name: String, scope: Scope, defJSON: Data, enabled: Bool = true) throws {
        guard let def = try? JSONSerialization.jsonObject(with: defJSON) as? [String: Any] else {
            throw Err.invalidJSON
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Err.emptyName }
        let bucket = enabled ? activeKey : disabledKey
        try mutate(scope: scope) { section in
            var dst = (section[bucket] as? [String: Any]) ?? [:]
            dst[trimmed] = def
            section[bucket] = dst
        }
    }

    /// Remove a server entirely from its scope (both buckets).
    static func delete(_ entry: Entry) throws {
        try mutate(scope: entry.scope) { section in
            for k in [activeKey, disabledKey] {
                guard var d = section[k] as? [String: Any] else { continue }
                d.removeValue(forKey: entry.name)
                section[k] = d.isEmpty ? nil : d
            }
        }
    }

    enum Err: Error { case invalidJSON, emptyName }

    // MARK: - Scoped read-modify-write

    /// Mutate the `mcpServers`/`throttleDisabledMcpServers` section for a scope.
    /// The closure receives the section dict (the whole `~/.claude.json`, the
    /// `projects[path]` sub-dict, or the `.mcp.json` root) and mutates it in
    /// place. Backs the file up, preserves all sibling keys, writes atomically.
    private static func mutate(scope: Scope, _ body: (inout [String: Any]) -> Void) throws {
        switch scope {
        case .user:
            try mutateFile(claudeJSON) { root in body(&root) }

        case .local(let path):
            try mutateFile(claudeJSON) { root in
                var projects = (root["projects"] as? [String: Any]) ?? [:]
                var section = (projects[path] as? [String: Any]) ?? [:]
                body(&section)
                projects[path] = section
                root["projects"] = projects
            }

        case .project(let path):
            try mutateFile(mcpJSON(path)) { root in body(&root) }
        }
    }

    /// Read a JSON file (or start empty), run `body`, back up, write atomically.
    private static func mutateFile(_ url: URL, _ body: (inout [String: Any]) -> Void) throws {
        var root = readJSON(url) ?? [:]
        try backup(url)
        body(&root)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    @discardableResult
    private static func backup(_ url: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = backupsDir.appendingPathComponent("\(url.lastPathComponent)-\(stamp).bak")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: url, to: dest)
        return dest
    }

    // MARK: - Templates for the "Add server" editor

    static let stdioTemplate = """
    {
      "command": "npx",
      "args": ["-y", "@scope/some-mcp-server"],
      "env": {}
    }
    """

    static let httpTemplate = """
    {
      "url": "https://example.com/mcp",
      "headers": {}
    }
    """
}
