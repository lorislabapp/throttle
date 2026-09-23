import Foundation

/// Deterministic, no-AI-needed audit of a Claude Code `settings.json` /
/// `settings.local.json`. Produces a proposed file that MERGES in the
/// suggested tool permission rules, plus a plain-language
/// rationale — feeding the Optimizer tab's existing diff → Apply (backup)
/// pipeline. Reliable where the AI optimizer is provider-dependent.
///
/// Model and reasoning preferences are preserved, including an absent override.
enum SettingsAuditService {

    struct Result: Sendable {
        let proposed: String
        let why: [String]
        let changed: Bool
    }

    /// Tool-level restrictions, not an OS sandbox or a measured cost saving.
    static let recommendedDeny: [String] = [
        "Read(./.env)",
        "Read(./.env.*)",
        "Read(./node_modules/**)",
        "Read(./dist/**)",
        "Read(./build/**)",
        "Bash(git push *)"
    ]

    /// Merge the recommended wins into `currentJSON`. Never removes or overrides
    /// an existing deliberate value, including model and reasoning preferences.
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
        guard obj["permissions"] == nil || obj["permissions"] is [String: Any] else {
            return Result(proposed: currentJSON,
                          why: [String(localized: """
                              Unrecognized permissions format. No settings were changed.
                              """)], changed: false)
        }
        var permissions = obj["permissions"] as? [String: Any] ?? [:]
        guard permissions["deny"] == nil || permissions["deny"] is [String] else {
            return Result(proposed: currentJSON,
                          why: [String(localized: """
                              Unrecognized deny rules. No settings were changed.
                              """)], changed: false)
        }
        var deny = permissions["deny"] as? [String] ?? []
        let have = Set(deny)
        let missing = recommendedDeny.filter { !have.contains($0) }
        if !missing.isEmpty {
            deny.append(contentsOf: missing)
            permissions["deny"] = deny
            obj["permissions"] = permissions
            why.append(String(localized: """
                Proposed additional tool permission rules. Review their effect on your workflow; they are \
                not an operating-system sandbox or a guarantee of savings.
                """))
        }

        guard !missing.isEmpty else {
            return Result(proposed: currentJSON,
                          why: [String(localized: """
                              No additional permission rules proposed. Model and reasoning preferences are unchanged.
                              """)],
                          changed: false)
        }

        return Result(proposed: serialize(obj), why: why, changed: true)
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
