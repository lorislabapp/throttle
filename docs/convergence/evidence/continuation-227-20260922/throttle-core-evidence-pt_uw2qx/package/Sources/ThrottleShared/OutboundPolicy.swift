import Foundation

/// The one rule every outbound payload shares: credential-shaped strings never
/// leave, whatever they are travelling in. Exports remain data boundaries — a usage CSV on
/// the Desktop still names the user's own projects — but a token that ended up
/// in a path, a model name or a note is masked at the boundary, not trusted
/// to have been kept out upstream. The masks name the kind, never the value.
public enum OutboundPolicy {
    public struct Pattern: Sendable {
        public let kind: String
        public let regex: NSRegularExpression
    }

    /// Ordered from most to least specific so a token is named by its narrowest kind.
    public static let patterns: [Pattern] = [
        ("anthropic-key", #"sk-ant-[A-Za-z0-9_\-]{8,}"#),
        ("github-token", #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#),
        ("github-token", #"github_pat_[A-Za-z0-9_]{20,}"#),
        ("apple-auth-key", #"AuthKey_[A-Z0-9]{6,}(?:\.p8)?"#),
        ("aws-access-key", #"(?:AKIA|ASIA)[0-9A-Z]{16}"#),
        ("slack-token", #"xox[abpr]-[A-Za-z0-9\-]{10,}"#),
        ("bearer-token", #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#),
        ("secret-key", #"sk-[A-Za-z0-9]{16,}"#),
        ("private-key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#)
    ].compactMap { kind, expression in
        (try? NSRegularExpression(pattern: expression)).map { Pattern(kind: kind, regex: $0) }
    }

    /// Masks every credential-shaped substring; clean text comes back unchanged.
    public static func scrub(_ text: String) -> String {
        var output = text
        for pattern in patterns {
            let range = NSRange(output.startIndex..., in: output)
            output = pattern.regex.stringByReplacingMatches(
                in: output, range: range, withTemplate: "[redacted:" + pattern.kind + "]"
            )
        }
        return output
    }

    /// The kinds present in a text, for tests and for a preview that must say
    /// what was masked without repeating it.
    public static func findings(in text: String) -> [String] {
        patterns.filter { $0.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            .map(\.kind)
    }
}
