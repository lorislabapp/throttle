import Foundation

/// Deterministic, model-free fold of repetitive developer output — the
/// compression tier the 2026-08 mix research rated highest-confidence
/// (dictionary/dedup of logs: strong fidelity; semantic paraphrase: risky;
/// source-code minification: rejected). No model decides what matters here:
/// only exact repetition is collapsed, annotated `⟨× N⟩` so the reader can
/// reconstruct what happened, and ANSI colour codes (which cost tokens and
/// carry nothing) are stripped.
///
/// Used as a pre-pass before feeding logs/terminal evidence to the *local*
/// model (pure win — no frontier prompt is ever rewritten by this service).
enum LogFoldService {

    static let savedCharactersKey = "throttleLogFoldSavedCharacters"

    struct Folded: Sendable {
        let text: String
        let originalCharacters: Int
        let foldedCharacters: Int
        let collapsedLines: Int
        var savedCharacters: Int { max(0, originalCharacters - foldedCharacters) }
        var worthwhile: Bool { savedCharacters > 200 }
    }

    /// CSI/OSC escape sequences — colour, cursor movement, titles.
    private static let ansiPattern = try? NSRegularExpression(
        pattern: "\u{001B}(?:\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\))"
    )

    static func stripANSI(_ text: String) -> String {
        guard let ansiPattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Fold exactly repeated lines (after ANSI strip + trailing-space trim).
    /// Blank runs collapse silently; content runs keep one instance + `⟨× N⟩`.
    static func fold(_ raw: String) -> Folded {
        let clean = stripANSI(raw)
        var out: [String] = []
        var collapsed = 0
        var previousTrimmed: String? = nil
        var runLength = 0

        func flushRun() {
            defer { runLength = 0 }
            guard runLength > 1, let prev = previousTrimmed else { return }
            collapsed += runLength - 1
            // Blank runs collapse silently; content runs keep one line + a count.
            if !prev.isEmpty { out.append("⟨× \(runLength)⟩") }
        }

        for line in clean.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if runLength > 0, trimmed == previousTrimmed {
                runLength += 1
                continue
            }
            flushRun()
            out.append(String(line))
            previousTrimmed = trimmed
            runLength = 1
        }
        flushRun()

        let folded = out.joined(separator: "\n")
        let result = Folded(
            text: folded,
            originalCharacters: raw.count,
            foldedCharacters: folded.count,
            collapsedLines: collapsed
        )
        if result.savedCharacters > 0 {
            let defaults = UserDefaults.standard
            defaults.set(defaults.integer(forKey: savedCharactersKey) + result.savedCharacters,
                         forKey: savedCharactersKey)
        }
        return result
    }
}
