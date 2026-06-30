import Foundation

/// Background driver for the C4 semantic index: keeps each Claude Code project's
/// corpus fresh so `throttle_semantic_search` is usable without anyone running
/// `--index-repo` by hand. Opt-in (OFF by default) and memory-pressure-gated —
/// embedding a whole repo is CPU/RAM heavy, and this runs on a 16 GB Mac that
/// already swaps, so it never fires under pressure. Incremental (RepoIndexer's
/// content-hash manifest skips unchanged files), so steady-state passes are cheap.
enum SemanticAutoIndexer {

    private static let enabledKey = "semanticAutoIndexEnabled"

    /// Opt-in: default OFF.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    struct Summary: Sendable, Equatable {
        var reposTouched = 0       // repos with at least one (re)indexed/evicted file
        var filesIndexed = 0
        var chunks = 0
        var skipped: String?       // "disabled" | "memory-pressure" | nil
    }

    /// Testable core: index each repo root incrementally, gated by `enabled` and
    /// memory state. Pure w.r.t. its inputs (FS + corpus store are the only side
    /// effects). Bounded per pass so a huge project set can't stall launch.
    @discardableResult
    static func run(roots: [String], enabled: Bool, memoryQuiet: Bool,
                    embedder: EmbeddingProvider, maxReposPerPass: Int = 12) -> Summary {
        guard enabled else { return Summary(skipped: "disabled") }
        guard !memoryQuiet else { return Summary(skipped: "memory-pressure") }
        var s = Summary()
        let fm = FileManager.default
        for root in roots.prefix(maxReposPerPass) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
            var index = SemanticCorpusStore.loadIndex(repo: root, embedder: embedder)
            var manifest = SemanticCorpusStore.loadManifest(repo: root)
            let st = RepoIndexer.indexDirectory(URL(fileURLWithPath: root), into: &index, manifest: &manifest)
            try? SemanticCorpusStore.save(repo: root, index: index, manifest: manifest)
            if st.indexed > 0 || st.removed > 0 { s.reposTouched += 1 }
            s.filesIndexed += st.indexed
            s.chunks += st.chunks
        }
        return s
    }
}
