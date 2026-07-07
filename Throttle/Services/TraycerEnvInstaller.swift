import Foundation

/// Opt-in installer that merges a top-level `env` block into
/// `~/.claude/settings.json` so new Claude Code sessions export OpenTelemetry to
/// Throttle's local `TraycerReceiver` (127.0.0.1:4318).
///
/// Reversible and non-clobbering: it backs up settings.json (shared
/// `throttle-backups` dir, same path the hook + statusline writers use), merges
/// only OUR keys, and on `remove()` strips exactly the keys whose value still
/// matches what we wrote — a user's own later override is left intact.
///
/// **Privacy:** enables `OTEL_LOG_TOOL_DETAILS=1` (full shell command lines land
/// in the local `usage.db`, never leaving the machine) but deliberately does NOT
/// set `OTEL_LOG_USER_PROMPTS` — prompt text is never captured. The Settings
/// toggle discloses the command-logging before enabling.
///
/// Only affects **new** sessions (Claude Code snapshots env at session start);
/// existing sessions are untouched. No auto-restart (memory: never relaunch CC).
enum TraycerEnvInstaller {

    /// 127.0.0.1 (not localhost) to skip DNS and pin the loopback the receiver binds.
    static let endpoint = "http://127.0.0.1:4318"

    /// The env we own. `http/json` (verified against v2.1.202 — no protobuf dep)
    /// and `compression=none` keep the receiver's decode path a plain
    /// `JSONSerialization` with no gunzip; the receiver still handles gzip as a
    /// fallback if a user forces compression elsewhere.
    static var desiredEnv: [String: String] {
        [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_METRICS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
            "OTEL_EXPORTER_OTLP_COMPRESSION": "none",
            "OTEL_LOG_TOOL_DETAILS": "1",
        ]
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }

    /// True when every key we manage is present with our value.
    static func isInstalled() -> Bool {
        let env = envBlock(readSettings())
        return desiredEnv.allSatisfy { env[$0.key] as? String == $0.value }
    }

    /// True when the block bears our signature (our endpoint) — i.e. the user
    /// opted in at some point, even if a key later drifted.
    private static func isOptedIn() -> Bool {
        (envBlock(readSettings())["OTEL_EXPORTER_OTLP_ENDPOINT"] as? String) == endpoint
    }

    @discardableResult
    static func install() throws -> Bool {
        guard !isInstalled() else { return false }
        var dict = readSettings() ?? [:]
        var env = dict["env"] as? [String: Any] ?? [:]
        try backupSettings()
        for (k, v) in desiredEnv { env[k] = v }
        dict["env"] = env
        try writeSettings(dict)
        return true
    }

    /// Strip only the keys we set (value still equal to ours). A user override
    /// applied after install is preserved. Drops the empty `env` block entirely.
    static func remove() throws {
        guard var dict = readSettings(), var env = dict["env"] as? [String: Any] else { return }
        var changed = false
        for (k, v) in desiredEnv where env[k] as? String == v {
            env.removeValue(forKey: k); changed = true
        }
        guard changed else { return }
        try backupSettings()
        if env.isEmpty { dict.removeValue(forKey: "env") } else { dict["env"] = env }
        try writeSettings(dict)
    }

    /// Launch-time self-heal — only touches settings if the user already opted in
    /// (our endpoint present). Re-applies drifted keys (e.g. a changed default
    /// across a Throttle update). No-op when not opted in or already consistent.
    @discardableResult
    static func reconcile() -> Bool {
        guard isOptedIn(), !isInstalled() else { return false }
        return (try? install()) ?? false
    }

    // MARK: - settings.json IO (shared shape with TokoptHookInstaller)

    private static func envBlock(_ dict: [String: Any]?) -> [String: Any] {
        dict?["env"] as? [String: Any] ?? [:]
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func writeSettings(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsFile, options: .atomic)
    }

    @discardableResult
    private static func backupSettings() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let dest = backupsDir.appendingPathComponent("settings-\(Int(Date().timeIntervalSince1970)).json")
        if fm.fileExists(atPath: settingsFile.path) { try? fm.copyItem(at: settingsFile, to: dest) }
        return dest
    }
}
