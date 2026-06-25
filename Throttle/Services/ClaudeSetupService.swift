import Foundation

/// Reads the user's Claude Code environment — MCP servers, skills, plugins — for
/// the cockpit's "Setup" panel. On-doctrine: a cockpit that knows the agent's
/// surroundings. Read-only; never surfaces MCP `env` (those hold secrets).
struct MCPEntry: Sendable, Identifiable { let id = UUID(); let name: String; let kind: String; let locator: String }
struct SkillEntry: Sendable, Identifiable { let id = UUID(); let name: String; let detail: String }
struct PluginEntry: Sendable, Identifiable { let id = UUID(); let name: String; let marketplace: String; let version: String }

struct ClaudeSetup: Sendable {
    var claudeVersion: String = ""   // e.g. "2.1.191"
    var mcp: [MCPEntry] = []
    var skills: [SkillEntry] = []
    var plugins: [PluginEntry] = []
    var projectMCPCount: Int = 0   // MCP servers configured per-project (not global)
}

enum ClaudeSetupService {

    static func load() -> ClaudeSetup {
        var setup = ClaudeSetup()
        let home = FileManager.default.homeDirectoryForCurrentUser
        setup.claudeVersion = claudeVersion()
        loadMCP(home: home, into: &setup)
        loadSkills(home: home, into: &setup)
        loadPlugins(home: home, into: &setup)
        return setup
    }

    /// `claude --version` → "2.1.191" (drops the "(Claude Code)" suffix). Empty if
    /// claude isn't found. Login shell so PATH/nvm resolve like Claude's own spawn.
    private static func claudeVersion() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "claude --version"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.split(separator: " ").first.map(String.init) ?? ""
    }

    // MARK: - MCP servers (~/.claude.json)

    private static func loadMCP(home: URL, into setup: inout ClaudeSetup) {
        let url = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let servers = root["mcpServers"] as? [String: Any] {
            setup.mcp = servers.map { name, def in mcpEntry(name: name, def: def) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        // Tally per-project MCP servers (so the panel can note "+N project-scoped").
        if let projects = root["projects"] as? [String: Any] {
            setup.projectMCPCount = projects.values.reduce(0) { acc, v in
                acc + (((v as? [String: Any])?["mcpServers"] as? [String: Any])?.count ?? 0)
            }
        }
    }

    private static func mcpEntry(name: String, def: Any) -> MCPEntry {
        let d = def as? [String: Any] ?? [:]
        let kind = (d["type"] as? String) ?? "stdio"
        // NEVER read `env` — secrets live there. Show only the transport locator.
        let locator: String
        if let url = d["url"] as? String { locator = url }
        else if let cmd = d["command"] as? String { locator = (cmd as NSString).lastPathComponent }
        else { locator = "" }
        return MCPEntry(name: name, kind: kind, locator: locator)
    }

    // MARK: - Skills (~/.claude/skills)

    private static func loadSkills(home: URL, into setup: inout ClaudeSetup) {
        let dir = home.appendingPathComponent(".claude/skills")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        var out: [SkillEntry] = []
        for entry in entries where !entry.hasPrefix(".") {
            let full = dir.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full.path, isDirectory: &isDir)
            let mdPath = isDir.boolValue ? full.appendingPathComponent("SKILL.md") : full
            guard mdPath.pathExtension == "md" || isDir.boolValue,
                  let text = try? String(contentsOf: mdPath, encoding: .utf8) else { continue }
            let (name, desc) = frontmatter(text)
            let display = name ?? (entry as NSString).deletingPathExtension
            out.append(SkillEntry(name: display, detail: desc ?? ""))
        }
        setup.skills = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Pull `name:` and `description:` from a leading `--- … ---` YAML frontmatter.
    private static func frontmatter(_ text: String) -> (name: String?, description: String?) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var name: String?, desc: String?
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            if name == nil, t.hasPrefix("name:") { name = value(t, "name:") }
            else if desc == nil, t.hasPrefix("description:") { desc = value(t, "description:") }
        }
        return (name, desc)
    }

    private static func value(_ line: String, _ key: String) -> String {
        String(line.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    // MARK: - Plugins (~/.claude/plugins/installed_plugins.json)

    private static func loadPlugins(home: URL, into setup: inout ClaudeSetup) {
        let url = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return }
        var out: [PluginEntry] = []
        for (key, val) in plugins {
            // key = "name@marketplace"
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            let name = parts.first ?? key
            let marketplace = parts.count > 1 ? parts[1] : ""
            let version = (val as? [[String: Any]])?.first?["version"] as? String ?? ""
            out.append(PluginEntry(name: name, marketplace: marketplace, version: version))
        }
        setup.plugins = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
