import Foundation

/// Throttle's embedded token-optimization hook. Invoked as a Claude Code
/// **PostToolUse(Bash)** hook (`Throttle --tokopt-hook`): it reads the tool
/// result on stdin, compresses verbose-but-low-signal CLI output, and returns
/// `hookSpecificOutput.updatedToolOutput` so the MODEL sees the compressed
/// version. Requires Claude Code ≥ 2.1.121 (built-in `updatedToolOutput`).
///
/// SAFETY (the cardinal rule): this only ever rewrites what Claude SEES — the
/// command already ran. Every uncertainty is a **no-op** (exit 0, no JSON), and
/// Claude Code then keeps the original output. We NEVER compress on failure,
/// never touch JSON, never drop errors, and tee the full raw output to a file
/// with a breadcrumb so nothing is lost. PostToolUse does not even fire for
/// failed commands, so errors pass through raw by construction.
enum TokoptHook {

    static func run() {
        // Any failure → silent no-op (Claude keeps the original output).
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (payload["tool_name"] as? String) == "Bash",
              let resp = payload["tool_response"] as? [String: Any] else { return }

        let stdout = resp["stdout"] as? String ?? ""
        let stderr = resp["stderr"] as? String ?? ""
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String ?? ""

        // Phase 1 (measure-only): JSON-array outputs are something we deliberately
        // pass through uncompressed below — but we record how much TOON *would*
        // save (separate log, never applied) so the value is provable before we
        // ever opt into replacing. Returns true when it logged a candidate.
        if stderr.isEmpty, TOONTranspiler.measurePotential(stdout, tool: "Bash") { return }

        guard shouldCompress(stdout: stdout, stderr: stderr) else { return }

        let compressed = compress(stdout, command: command)
        // Require a real gain (≥15% smaller) or it's not worth replacing.
        guard compressed.utf8.count < (stdout.utf8.count * 85) / 100 else { return }

        emit(stdout: compressed, original: resp)
        logSavings(command: command, before: stdout.utf8.count, after: compressed.utf8.count)
    }

    // MARK: - Safety gate

    static func shouldCompress(stdout: String, stderr: String) -> Bool {
        if !stderr.isEmpty { return false }                 // never compress a failure
        if stdout.utf8.count < 1_000 { return false }       // too small to bother
        // Treat as a failure only on a real failure SHAPE — a line-anchored
        // error/panic/FAILED banner or a traceback — NOT any line that merely
        // contains "error" as a substring (e.g. the filename "macerror").
        let failureSignals = [
            "(?im)^\\s*(error|fatal|panic|exception)\\b[: ]",
            "(?im)traceback \\(most recent call last\\)",
            "(?im)^[\\s=-]*FAIL(ED|URE)?\\b",
        ]
        for re in failureSignals where stdout.range(of: re, options: .regularExpression) != nil {
            return false                                     // preserve diagnostics verbatim
        }
        // Structured output: corrupting JSON/NDJSON is the worst failure → pass through.
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil { return false }
        }
        return true
    }

    // MARK: - Compression (generic, conservative). Per-command recipes = stage 2.

    static func compress(_ stdout: String, command: String) -> String {
        let clean = stripANSI(stdout)
        // Try a per-command recipe first (safe, success-only); else generic.
        if let r = recipe(for: command, on: clean) { return r }
        var s = collapseBlankRuns(clean)
        s = dedupConsecutive(s)
        s = headTailTruncate(s, command: command)
        return s
    }

    // MARK: - Per-command recipes (conservative; nil = fall back to generic)

    /// The base executable, ignoring leading `VAR=val`, `cd … &&`, `sudo`, `time`.
    static func baseCommand(_ command: String) -> (cmd: String, sub: String) {
        var toks = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // peel a leading `cd … &&`
        if let amp = toks.firstIndex(of: "&&") { toks = Array(toks[(amp + 1)...]) }
        // peel env assignments / wrappers
        while let first = toks.first, first.contains("=") || ["sudo", "time", "env"].contains(first) {
            toks.removeFirst()
        }
        let cmd = (toks.first.map { ($0 as NSString).lastPathComponent }) ?? ""
        let sub = toks.count > 1 ? toks[1] : ""
        return (cmd, sub)
    }

    static func recipe(for command: String, on clean: String) -> String? {
        let (cmd, sub) = baseCommand(command)
        switch cmd {
        case "git" where sub == "status": return gitStatusRecipe(clean)
        case "git" where sub == "log":    return gitLogRecipe(command, clean)
        case "npm", "pnpm", "yarn", "cargo", "pip", "pip3", "go", "make", "bundle", "brew", "docker":
            return stripBuildProgress(clean)
        default: return nil
        }
    }

    /// `git status` — drop the instructional "(use \"git …\")" hint lines and
    /// blank padding; keep every branch line and file path verbatim.
    static func gitStatusRecipe(_ s: String) -> String? {
        let lines = s.components(separatedBy: "\n")
        let kept = lines.filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("(use \"git") && !(t.isEmpty)
        }
        guard kept.count < lines.count else { return nil }
        return kept.joined(separator: "\n")
    }

    /// `git log` (default multi-line format only) — one line per commit
    /// "<hash7> <subject>". Skipped if the user passed a custom --format/--pretty
    /// or --oneline (don't mangle their chosen shape).
    static func gitLogRecipe(_ command: String, _ s: String) -> String? {
        if command.contains("--oneline") || command.contains("--pretty") || command.contains("--format") || command.contains("--stat") || command.contains("-p") { return nil }
        let lines = s.components(separatedBy: "\n")
        var out: [String] = []
        var hash = ""
        for line in lines {
            if line.hasPrefix("commit ") {
                hash = String(line.dropFirst(7).prefix(7))
            } else {
                let t = line.trimmingCharacters(in: .whitespaces)
                // First non-empty, non-header line after a commit = the subject.
                if !hash.isEmpty, !t.isEmpty,
                   !t.hasPrefix("Author:"), !t.hasPrefix("Date:"), !t.hasPrefix("Merge:") {
                    out.append("\(hash) \(t)")
                    hash = ""
                }
            }
        }
        guard out.count >= 3, out.count < lines.count / 2 else { return nil }
        return out.joined(separator: "\n")
    }

    /// Build / package managers — drop transient progress, spinners and download
    /// chatter; keep result + warning lines. Conservative (only strips lines that
    /// are clearly progress noise).
    static func stripBuildProgress(_ s: String) -> String? {
        let progress = [
            "(?i)^\\s*(downloading|fetching|resolving|compiling|building|installing|updating|extracting|unpacking|preparing|reading|writing|verifying)\\b",
            "^\\s*[\\[(]?\\d{1,3}%",                 // 42%  / [42%]
            "^[⠁-⣿✔✓●○◐◓◑◒\\-\\\\|/]\\s",            // spinner glyphs
            "^\\s*\\d+\\s+packages?\\s+(are|in)\\b", // npm "N packages are looking for funding"
        ]
        let res = progress.map { try? NSRegularExpression(pattern: $0) }
        let lines = s.components(separatedBy: "\n")
        let kept = lines.filter { l in
            let r = NSRange(l.startIndex..<l.endIndex, in: l)
            return !res.contains { $0?.firstMatch(in: l, range: r) != nil }
        }
        // Only worth it if it actually removed a meaningful chunk.
        guard kept.count <= (lines.count * 85) / 100 else { return nil }
        return kept.joined(separator: "\n")
    }

    /// Remove ANSI/CSI escape sequences and carriage returns (progress redraws).
    static func stripANSI(_ s: String) -> String {
        let esc = "\u{1B}"   // the actual ESC byte, so the regex matches the full sequence
        var out = s.replacingOccurrences(
            of: "\(esc)\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)   // CSI
        out = out.replacingOccurrences(
            of: "\(esc)\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)        // OSC … BEL
        out = out.replacingOccurrences(of: "\r", with: "")
        return out
    }

    /// Collapse 3+ blank lines into one, trim trailing spaces.
    static func collapseBlankRuns(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
        var out: [String] = []
        var blanks = 0
        for l in lines {
            if l.isEmpty { blanks += 1; if blanks <= 1 { out.append(l) } }
            else { blanks = 0; out.append(l) }
        }
        return out.joined(separator: "\n")
    }

    /// Collapse runs of identical consecutive lines into one + a count.
    static func dedupConsecutive(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            var j = i + 1
            while j < lines.count && lines[j] == lines[i] { j += 1 }
            let n = j - i
            out.append(lines[i])
            if n > 2 { out.append("[… repeated \(n) times]") }
            else if n == 2 { out.append(lines[i]) }
            i = j
        }
        return out.joined(separator: "\n")
    }

    /// Cap very large output: keep the head + tail, tee the full raw to a file,
    /// and leave a breadcrumb so the model can `cat` it if it needs the rest.
    static func headTailTruncate(_ s: String, command: String, head: Int = 120, tail: Int = 60) -> String {
        let lines = s.components(separatedBy: "\n")
        guard lines.count > head + tail + 20 else { return s }
        let path = teeRaw(s)
        let elided = lines.count - head - tail
        var kept = Array(lines.prefix(head))
        kept.append("[Throttle: trimmed \(elided) middle lines — full output: \(path)]")
        kept.append(contentsOf: lines.suffix(tail))
        return kept.joined(separator: "\n")
    }

    // MARK: - Emit (must match the Bash tool_response shape exactly)

    static func emit(stdout: String, original: [String: Any]) {
        let updated: [String: Any] = [
            "stdout": stdout,
            "stderr": original["stderr"] as? String ?? "",
            "interrupted": original["interrupted"] as? Bool ?? false,
            "isImage": original["isImage"] as? Bool ?? false,
        ]
        let out: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PostToolUse",
                "updatedToolOutput": updated,
            ],
        ]
        // If serialization fails, print nothing → safe no-op.
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
    }

    // MARK: - Persistence (raw tee + savings log)

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
    }

    /// Write the full raw output to a rolling temp file; return its path.
    static func teeRaw(_ s: String) -> String {
        let dir = appSupport.appendingPathComponent("tokopt-raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("out-\(ProcessInfo.processInfo.processIdentifier).log")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Append one record to savings.jsonl (the schema SavingsIngester reads).
    static func logSavings(command: String, before: Int, after: Int) {
        let dir = appSupport
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("savings.jsonl")
        let rec: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "hook": "tokopt-bash",
            "baseline_bytes": before,
            "actual_bytes": after,
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: rec) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); h.write(Data([0x0a])); try? h.close()
        } else {
            try? (String(data: line, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
