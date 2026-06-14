import Foundation

/// Deterministic, no-AI-needed audit of a Claude Code `settings.json` /
/// `settings.local.json`. Produces a proposed file that MERGES in the
/// research-backed, high-leverage cost-safety wins, plus a plain-language
/// rationale — feeding the Optimizer tab's existing diff → Apply (backup)
/// pipeline. Reliable where the AI optimizer is provider-dependent.
///
/// Sources: the Claude Code optimization research (permissions.deny is the only
/// real read-firewall; `.claudeignore` is NOT honored; model=sonnet ≈ 1/5 Opus
/// cost; extended-thinking tokens up to ~40% of session cost).
enum SettingsAuditService {

    struct Result: Sendable {
        let proposed: String
        let why: [String]
        let changed: Bool
    }

    /// Read-firewall + destructive-shell denies. permissions.deny is the only
    /// exclusion Claude Code's native Read/Glob/Grep actually honor.
    static let recommendedDeny: [String] = [
        "Read(./.env)",
        "Read(./.env.*)",
        "Read(./node_modules/**)",
        "Read(./dist/**)",
        "Read(./build/**)",
        "Bash(git push *)",
    ]

    /// Merge the recommended wins into `currentJSON`. Never removes or overrides
    /// an existing deliberate value (model is only suggested when unset).
    static func audit(currentJSON: String) -> Result {
        let trimmed = currentJSON.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty file → start from {}. Malformed → don't touch it.
        var obj: [String: Any]
        if trimmed.isEmpty {
            obj = [:]
        } else if let parsed = parse(trimmed) {
            obj = parsed
        } else {
            return Result(proposed: currentJSON,
                          why: ["Couldn't parse this as JSON — fix the syntax first, then run Quick wins."],
                          changed: false)
        }

        var why: [String] = []

        // 1) permissions.deny — append any missing recommended rules.
        var permissions = obj["permissions"] as? [String: Any] ?? [:]
        var deny = permissions["deny"] as? [String] ?? []
        let have = Set(deny)
        let missing = recommendedDeny.filter { !have.contains($0) }
        if !missing.isEmpty {
            deny.append(contentsOf: missing)
            permissions["deny"] = deny
            obj["permissions"] = permissions
            why.append("Added \(missing.count) permissions.deny rule\(missing.count == 1 ? "" : "s") (\(missing.joined(separator: ", "))) — blocks blind reads of secrets / deps / generated files that silently burn 10k+ tokens. permissions.deny is the only real read-firewall (.claudeignore is NOT honored by Read/Glob/Grep).")
        }

        // 2) model — suggest sonnet only if the user hasn't set one.
        if obj["model"] == nil {
            obj["model"] = "claude-sonnet-4-6"
            why.append("Set model → claude-sonnet-4-6 — handles ~90% of coding at roughly 1/5 the cost of Opus. Remove or change it if you need Opus by default.")
        }

        // 3) alwaysThinkingEnabled — turn OFF if explicitly on.
        if let thinking = obj["alwaysThinkingEnabled"] as? Bool, thinking {
            obj["alwaysThinkingEnabled"] = false
            why.append("alwaysThinkingEnabled → false — extended-thinking tokens bill as (expensive) output and can be up to ~40% of a session's cost. Reach for depth per-task with /effort instead.")
        }

        let proposed = serialize(obj)
        let changed = proposed.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed
        if !changed {
            return Result(proposed: currentJSON,
                          why: ["Already applies the recommended cost-safety settings — nothing to add."],
                          changed: false)
        }
        return Result(proposed: proposed, why: why, changed: true)
    }

    // MARK: - JSON IO

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func serialize(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8)
        else { return "{\n}\n" }
        return s + "\n"
    }
}
