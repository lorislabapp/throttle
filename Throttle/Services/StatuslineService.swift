import Foundation

/// Installs a Claude Code **statusline** so every terminal session (every tab,
/// every project) shows the user's live usage headroom — without opening the
/// app. Install once → it's there system-wide.
///
/// Design (confirmed against current Claude Code docs):
///   • settings.json `statusLine` = `{type:command, command:<script>}`,
///   • the script runs in a CLEAN env (no shell rc, no Homebrew PATH) and must
///     be <100 ms, so it avoids `jq`: it `cat`s a tiny PRE-RENDERED line that
///     Throttle keeps fresh (`~/.claude/throttle-status.line`), and only when
///     that file is stale (app not running) does it fall back to Claude Code's
///     own `rate_limits` from stdin via `/usr/bin/python3`.
/// Reversible: `remove()` deletes the script and restores the previous
/// `statusLine` (or clears it). settings.json is backed up before any edit.
enum StatuslineService {

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var scriptFile: URL { home.appendingPathComponent(".claude/throttle-statusline.sh") }
    static var lineFile: URL { home.appendingPathComponent(".claude/throttle-status.line") }
    private static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }

    private static let script = #"""
    #!/bin/bash
    # Throttle statusline — live Claude Code usage headroom in every session.
    # Fast path: print Throttle's pre-rendered line if fresh (app running).
    # Fallback: Claude Code's own rate_limits from stdin (Pro/Max), no jq.
    f="$HOME/.claude/throttle-status.line"
    if [ -f "$f" ]; then
      m=$(stat -f %m "$f" 2>/dev/null || echo 0)
      now=$(date +%s)
      if [ $((now - m)) -lt 150 ]; then cat "$f"; exit 0; fi
    fi
    /usr/bin/python3 -c 'import sys,json
    try:
        d=json.load(sys.stdin)
    except Exception:
        print(""); sys.exit()
    r=d.get("rate_limits") or {}
    def p(k):
        w=r.get(k) or {}; v=w.get("used_percentage")
        return None if v is None else round(v)
    a=[]
    h=p("five_hour"); w=p("seven_day")
    if h is not None: a.append("5h %d%%"%h)
    if w is not None: a.append("7d %d%%"%w)
    print("throttle "+(" · ".join(a) if a else "·"))' 2>/dev/null
    """#

    // MARK: - State

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptFile.path),
              let dict = readSettings(),
              let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd.contains("throttle-statusline.sh")
    }

    // MARK: - Install / remove

    /// Write the script + point `statusLine` at it. Backs up settings.json first.
    /// Returns the previous `statusLine` (JSON-encoded) so it can be restored.
    @discardableResult
    static func install() throws -> (previousJSON: String?, settingsBackup: URL?) {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

        var dict = readSettings() ?? [:]
        let prev = dict["statusLine"]
        let prevJSON = prev.flatMap { encodeJSON($0) }
        let already = (prev as? [String: Any])?["command"] as? String
        var backup: URL? = nil
        if already?.contains("throttle-statusline.sh") != true {
            backup = try backupSettings()
            dict["statusLine"] = ["type": "command", "command": "~/.claude/throttle-statusline.sh"]
            try writeSettings(dict)
        }
        return (prevJSON, backup)
    }

    /// Reverse `install`: delete the script and restore the previous statusLine
    /// (or clear it) — only if the key is still ours.
    static func remove(restorePreviousJSON previous: String? = nil) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: scriptFile)
        try? fm.removeItem(at: lineFile)

        guard var dict = readSettings() else { return }
        let cmd = (dict["statusLine"] as? [String: Any])?["command"] as? String
        guard cmd?.contains("throttle-statusline.sh") == true else { return }
        _ = try? backupSettings()
        if let previous, let restored = decodeJSON(previous) {
            dict["statusLine"] = restored
        } else {
            dict.removeValue(forKey: "statusLine")
        }
        try writeSettings(dict)
    }

    // MARK: - Live line

    /// Render + atomically write the pre-rendered line the script `cat`s.
    /// Cheap (~tens of bytes); safe to call on every refresh.
    static func update(snapshot: UsageSnapshot, exact: ExactSnapshot?, savedTokens: Int) {
        let line = render(snapshot: snapshot, exact: exact, savedTokens: savedTokens)
        try? line.write(to: lineFile, atomically: true, encoding: .utf8)
    }

    /// The binding window (highest utilization) → a compact, colour-by-pressure
    /// line. Prefers exact (claude.ai) data when present.
    static func render(snapshot: UsageSnapshot, exact: ExactSnapshot?, savedTokens: Int) -> String {
        var pct: Int?
        var reset: Date?
        var exactMark = ""

        if let ex = exact {
            let ws = [ex.fiveHour, ex.sevenDay, ex.sevenDaySonnet]
            if let b = ws.max(by: { $0.utilization < $1.utilization }) {
                pct = b.utilization; reset = b.resetsAt; exactMark = " ✓"
            }
        } else {
            let candidates: [(Double, Int64)] = [snapshot.session5h, snapshot.weeklyAll, snapshot.weeklySonnet]
                .compactMap { w in w.percentUsed.map { ($0, w.resetInSeconds) } }
            if let b = candidates.max(by: { $0.0 < $1.0 }) {
                pct = Int((b.0 * 100).rounded())
                reset = Date().addingTimeInterval(TimeInterval(b.1))
            }
        }

        guard let p = pct else { return "throttle ▸ —" }
        var s = "throttle ▸ \(colour(p))%\(exactMark)"
        if let r = reset { s += " · reset \(hm(r))" }
        let eur = Double(savedTokens) / 1_000_000 * 6.0
        if eur >= 1 { s += " · ≈€\(Int(eur))" }
        return s
    }

    /// ANSI: red ≥95, yellow ≥80, dim otherwise (matches the cockpit's
    /// pressure-colour-only discipline).
    private static func colour(_ p: Int) -> String {
        let code = p >= 95 ? "31" : (p >= 80 ? "33" : "2")
        return "\u{1B}[\(code)m\(p)\u{1B}[0m"
    }

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static func hm(_ d: Date) -> String { hmFormatter.string(from: d) }

    // MARK: - settings.json IO (backed up, value-preserving)

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

    private static func backupSettings() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = backupsDir.appendingPathComponent("settings-\(stamp).json")
        if fm.fileExists(atPath: settingsFile.path) { try fm.copyItem(at: settingsFile, to: dest) }
        return dest
    }

    private static func encodeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": value]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func decodeJSON(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["v"]
    }
}
