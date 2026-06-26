import Foundation

/// Detects local LLM runtimes whose usage Throttle does NOT track, so the cockpit
/// can scope its figures honestly. NotebookLM blind spot: users pair Claude Code
/// with local models (Ollama / LM Studio) for cheap reasoning or DeepEval tests;
/// Throttle parses only Anthropic usage, so it must say so rather than imply its
/// numbers are the whole picture (golden rule — never imply completeness it lacks).
enum MultiVendorService {

    /// Display names of local LLM runtimes present on this machine ([] if none).
    /// Presence-based (a marker dir) — cheap and side-effect-free; we phrase the
    /// disclosure as "not tracked", never as "in use", to avoid over-claiming.
    static func localRuntimes() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        var found: [String] = []
        if fm.fileExists(atPath: home.appendingPathComponent(".ollama").path) { found.append("Ollama") }
        if fm.fileExists(atPath: home.appendingPathComponent(".lmstudio").path) { found.append("LM Studio") }
        if fm.fileExists(atPath: home.appendingPathComponent(".cache/lm-studio").path) && !found.contains("LM Studio") { found.append("LM Studio") }
        return found
    }
}
