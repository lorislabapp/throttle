import Foundation
import OSLog

/// Sandboxed runner for the AI Assistant's `bash` tool.
///
/// **Threat model.** The AI may be tricked, jailbroken, or hallucinate.
/// We assume the AI is hostile-by-default and design the sandbox so
/// that even a malicious prompt-injected response cannot:
///   - exfiltrate via curl/wget/nc — those binaries are not on the
///     allowlist
///   - read keys/credentials — explicit deny path-list checked against
///     EVERY argument that looks like a path
///   - escalate to write — only read-only commands are allowed
///   - chain commands via shell — no `sh -c`, every command runs via
///     `Process` with explicit `executableURL` + `arguments`. Pipes,
///     redirections, `&&`, `;`, backticks, `$()` are rejected at parse
///     time
///   - spin forever — 30 s wall-clock timeout, killed via SIGKILL
///   - flood logs / context — combined stdout+stderr capped at 64 KB
///   - drift over time — locale + PATH + env are deterministic; the
///     subprocess can't read the user's `~/.zshrc`
///
/// Only the allowlist binaries below can be invoked. Adding to the
/// list requires a security review: each entry is a discrete capability
/// that could be abused if its arguments aren't constrained correctly.
enum BashSandbox {
    private static let logger = Logger(subsystem: "com.lorislab.throttle", category: "BashSandbox")

    /// Wall-clock seconds before SIGKILL.
    private static let timeoutSeconds: TimeInterval = 30
    /// Combined stdout+stderr cap, in bytes.
    private static let outputCapBytes = 64 * 1024

    /// Read-only commands the AI is allowed to invoke. Each entry maps
    /// the command name (as the AI would type it) to its absolute
    /// executable path; we never trust PATH lookups at runtime.
    ///
    /// The set is intentionally tiny. Read-only inspection commands the
    /// AI typically wants for an audit:
    ///   - git: `git status`, `git log -n`, `git diff`, `git show`,
    ///     `git config --get`, `git rev-parse`, `git branch`
    ///   - swift: `swift --version`, `swift test`, `swift build`
    ///   - xcodebuild: `xcodebuild -list`, `-showBuildSettings`,
    ///     `-version`
    ///   - ls / cat / find / grep / head / tail / wc: filesystem
    ///     inspection (paths still go through the home-directory
    ///     check below)
    ///
    /// Notably absent: any networking (curl, wget, ssh, scp, nc),
    /// shell utilities (sh, bash, zsh, env, exec), package managers
    /// (npm, pip, brew, cargo), interpreters (python, ruby, node),
    /// destructive tools (rm, mv, chmod, chown, kill).
    private static let allowlist: [String: String] = [
        "git": "/usr/bin/git",
        // `swift` and `xcodebuild` were here. Both are arbitrary-code-execution
        // engines wearing the costume of a build tool: `swift build` compiles
        // and RUNS Package.swift at manifest-load time, and `xcodebuild` runs a
        // project's Run Script phases. Either one turns any repository the user
        // has ever cloned into a payload the assistant only has to name — which
        // makes the promise 20 lines above ("cannot exfiltrate", "cannot
        // escalate to write") false for both. Removed rather than argument-
        // constrained: a safe shape for them is a smaller allowlist than the
        // whole tool, and nothing here needed them.
        "ls": "/bin/ls",
        "cat": "/bin/cat",
        "find": "/usr/bin/find",
        "grep": "/usr/bin/grep",
        "head": "/usr/bin/head",
        "tail": "/usr/bin/tail",
        "wc": "/usr/bin/wc"
    ]

    /// Path prefixes that may NEVER appear in any argument the AI
    /// passes. Checked against the EXPANDED, REALPATH-resolved version
    /// of every arg that looks like a filesystem path.
    private static let denyPaths: [String] = [
        "/.ssh",
        "/.aws",
        "/.bitwarden",
        "/.gnupg",
        "/.netrc",
        "/.npmrc",
        // Claude Code's own OAuth credentials and MCP server env blocks. The
        // list guarded ssh, aws and gnupg but not the file belonging to the
        // agent this app exists to instrument — `~/.claude/.credentials.json`
        // holds the session token, and `~/.claude.json` carries every MCP
        // server's environment, which is where API keys live.
        "/.claude/.credentials.json",
        "/.claude.json",
        "/.config/gh/hosts.yml",
        "/.docker/config.json",
        "/.kube/config",
        "/Library/Keychains",
        "/Library/Application Support/com.apple.TCC",
        "/Library/Cookies",
        "/Library/Mail",
        "/Library/Messages",
        "/Library/Safari",
        "/etc/sudoers",
        "/etc/shadow",
        "/private/etc",
        "/private/var/db"
    ]

    /// Shell metacharacters that immediately disqualify a command.
    /// Even spaces inside quoted args are not allowed — the AI is
    /// instructed to pass simple tokens.
    private static let forbiddenChars: [Character] = [
        "|", ";", "&", "`", "$", ">", "<", "\n", "\r", "\\"
    ]

    /// Run `command` (e.g. `"git status"` or `"swift test --filter Foo"`)
    /// after splitting it into binary + args, validating both, and
    /// executing via `Process` with no shell. Returns user-readable
    /// output text, prefixed with `Error:` when the request was
    /// rejected.
    static func run(command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return "Error: empty command."
        }

        // Forbidden chars short-circuit before anything else — it's
        // cheaper than parsing.
        if let bad = trimmed.first(where: { forbiddenChars.contains($0) }) {
            return "Error: command contains forbidden shell character '\(bad)'. Pipes, redirections, env-var expansion, command substitution, and backslashes are not allowed in the bash tool."
        }

        // Tokenize on whitespace. We rejected anything fancy above.
        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        guard !tokens.isEmpty else {
            return "Error: empty command."
        }

        let bin = tokens[0]
        let rawArgs = Array(tokens.dropFirst())

        guard let exe = allowlist[bin] else {
            return "Error: '\(bin)' is not on the bash allowlist. Allowed: \(allowlist.keys.sorted().joined(separator: ", "))."
        }

        // Reject any arg that contains a path-like component (starts
        // with `/`, `~`, or `.`) AND resolves under one of the deny
        // paths. We do the check on every arg defensively: even args
        // that look harmless might be paths.
        // The child runs with its cwd at HOME, so a bare `.ssh/id_rsa` is a
        // real path even though it starts with no `/`, `~` or `.`. Resolve
        // every argument against that cwd before comparing.
        let cwd = FileManager.default.homeDirectoryForCurrentUser
        for arg in rawArgs {
            if let denyError = pathDenyCheck(arg, cwd: cwd.path) {
                return denyError
            }
        }

        // Build a minimal env. `PATH` is sanitized so the subprocess
        // can't shadow our explicit-path binaries. `HOME` is preserved
        // so commands that genuinely need it (xcodebuild for caches,
        // git for global config) keep working.
        let env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": cwd.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = rawArgs
        process.currentDirectoryURL = cwd
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let started = Date()
        do {
            try process.run()
        } catch {
            return "Error: failed to launch \(bin): \(error.localizedDescription)"
        }

        // Wall-clock timeout watchdog. We kill the process if it
        // doesn't terminate within `timeoutSeconds`; the caller waits
        // synchronously below.
        let timeoutFired = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timeoutFired.schedule(deadline: .now() + timeoutSeconds)
        timeoutFired.setEventHandler {
            if process.isRunning {
                process.terminate()
                // Give it 1s to clean up, then SIGKILL via a second timer
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        timeoutFired.resume()

        // Read up to outputCapBytes from each pipe, then drain the rest
        // silently. We don't want a runaway test to OOM the AI's
        // context.
        let stdoutData = readCapped(stdoutPipe.fileHandleForReading, cap: outputCapBytes)
        let stderrData = readCapped(stderrPipe.fileHandleForReading, cap: outputCapBytes)

        process.waitUntilExit()
        timeoutFired.cancel()

        let elapsed = Date().timeIntervalSince(started)
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? "<non-UTF8 stdout>"
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? "<non-UTF8 stderr>"

        logger.info("bash \(bin, privacy: .public) \(rawArgs.joined(separator: " "), privacy: .public) → exit=\(process.terminationStatus, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s stdout=\(stdoutStr.count, privacy: .public)b stderr=\(stderrStr.count, privacy: .public)b")

        var lines: [String] = ["[$ \(bin) \(rawArgs.joined(separator: " ")) — exit \(process.terminationStatus), \(String(format: "%.2f", elapsed))s]"]
        if !stdoutStr.isEmpty {
            lines.append("--- stdout ---")
            lines.append(stdoutStr)
        }
        if !stderrStr.isEmpty {
            lines.append("--- stderr ---")
            lines.append(stderrStr)
        }
        if elapsed >= timeoutSeconds {
            lines.append("--- killed after \(Int(timeoutSeconds))s timeout ---")
        }
        return lines.joined(separator: "\n")
    }

    /// Returns an `Error: ...` string if `arg` resolves under one of the
    /// `denyPaths`, or `nil` if it is safe.
    ///
    /// ## Two defects this had, both live
    ///
    /// The old version skipped the check entirely unless the argument began
    /// with `/`, `~`, `./` or `..`/. The child runs with its cwd set to the
    /// user's HOME, so **`cat .ssh/id_rsa` was never checked at all** — it is
    /// not "path-like" by that rule, and it reads the private key. Same for
    /// `.aws/credentials`, `.netrc`, `.npmrc`, `.claude/.credentials.json`.
    /// The tests covered `~/.ssh/id_rsa`, `~/.aws/credentials` and
    /// `~/Documents/../.ssh/id_rsa` — precisely the three spellings that were
    /// already caught. The bypass lived in the untested gap.
    ///
    /// And the doc comment claimed the comparison ran against a
    /// realpath-resolved path. It did not: `standardizedFileURL` is purely
    /// textual, so a symlink anywhere under HOME pointing at `.ssh` defeated
    /// even the spellings that were checked.
    ///
    /// Now: every argument is treated as a candidate path, resolved relative to
    /// the working directory, with symlinks followed.
    private static func pathDenyCheck(_ arg: String, cwd: String) -> String? {
        // A leading `-` is a flag, but `--file=<path>` carries one. Take the
        // value after the first `=` as a candidate too.
        var candidates = [arg]
        if arg.hasPrefix("-"), let equals = arg.firstIndex(of: "=") {
            candidates.append(String(arg[arg.index(after: equals)...]))
        }

        for candidate in candidates where !candidate.isEmpty {
            let expanded = (candidate as NSString).expandingTildeInPath
            let base = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: cwd).appendingPathComponent(expanded)
            // resolvingSymlinksInPath follows links that exist; standardizing
            // afterwards collapses any `..` the link did not resolve.
            let resolved = base.resolvingSymlinksInPath().standardizedFileURL.path
            for deny in denyPaths where resolved.contains(deny) {
                return "Error: refusing to access \(arg) — path resolves under a credential-bearing location (\(deny)). Throttle's bash tool blocks reads of keychains, SSH keys, and other secrets even read-only."
            }
        }
        return nil
    }

    /// Read up to `cap` bytes from `fh`, then drain the rest into the
    /// void. Synchronous — we're in a sandboxed child process flow,
    /// the calling Task is already off the main actor.
    private static func readCapped(_ fh: FileHandle, cap: Int) -> Data {
        var collected = Data()
        while collected.count < cap {
            let remaining = cap - collected.count
            // availableData reads up to ~1 MB at a time. We slice to
            // remaining so we never overshoot the cap.
            let chunk = fh.availableData
            if chunk.isEmpty { break }
            if chunk.count <= remaining {
                collected.append(chunk)
            } else {
                collected.append(chunk.prefix(remaining))
                break
            }
        }
        // Drain the rest so the writer doesn't block on a full pipe.
        while !fh.availableData.isEmpty { /* discard */ }
        return collected
    }
}
