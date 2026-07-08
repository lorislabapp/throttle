import Foundation

/// Byte→token estimation for Throttle's *estimates* (savings projections, schema
/// weight) — NOT the billed meter, which reads real `input_tokens`/`output_tokens`
/// from `usage_events` and is tokenizer-correct already.
///
/// The old flat `bytes / 4` rule assumed ~4 bytes/token English prose. Opus 4.7+
/// (incl. 4.8 / Fable 5) ship a newer tokenizer that runs up to ~1.35× denser on
/// **code / JSON / config** — exactly what Claude Code logs, tool schemas, and
/// trimmed output are — so `/4` undercounts those by ~25–35%. Dense content is
/// ~3 bytes/token; prose stays ~4; mixed logs ~3.5.
/// (Verified 2026-07: OpenRouter/Anthropic migration docs on the 4.7 tokenizer.)
enum TokenEstimate {
    enum Kind { case prose, dense, mixed }

    /// Approximate bytes per token for the given content kind.
    static func bytesPerToken(_ kind: Kind) -> Double {
        switch kind {
        case .prose: return 4.0
        case .dense: return 3.0   // code / JSON / tool schemas / config
        case .mixed: return 3.5
        }
    }

    /// Estimate tokens from a byte (or char) count. Defaults to `.dense` because
    /// most Throttle estimate sites measure code / JSON / schema text.
    static func fromBytes(_ bytes: Int, kind: Kind = .dense) -> Int {
        guard bytes > 0 else { return 0 }
        return Int((Double(bytes) / bytesPerToken(kind)).rounded())
    }
}
