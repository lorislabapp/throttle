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
        /// Roots not finished because a pause was requested, in order. Re-running
        /// them is cheap: the manifest already holds every file embedded so far.
        var pausedRemaining: [String] = []
    }

    /// Per-repo progress, reported so the Cockpit can show the pass instead of
    /// 12 silent minutes at ~200% CPU.
    enum Event: Sendable, Equatable {
        case started(total: Int)
        case repoStarted(index: Int, name: String)
        case repoFinished(index: Int, name: String, outcome: RepoOutcome)
    }
    enum RepoOutcome: Sendable, Equatable {
        case done, skipped
        case failed(String)
    }

    /// Testable core: index each repo root incrementally, gated by `enabled` and
    /// memory state. Pure w.r.t. its inputs (FS + corpus store are the only side
    /// effects). Bounded per pass so a huge project set can't stall launch.
    /// `control` lets the UI skip the current repo or pause the pass; both are
    /// honoured between files.
    @discardableResult
    static func run(roots: [String], enabled: Bool, memoryQuiet: Bool,
                    embedder: EmbeddingProvider, maxReposPerPass: Int = 12,
                    control: BackgroundWorkControl? = nil,
                    onEvent: (@Sendable (Event) -> Void)? = nil) -> Summary {
        guard enabled else { return Summary(skipped: "disabled") }
        guard !memoryQuiet else { return Summary(skipped: "memory-pressure") }
        var s = Summary()
        let fm = FileManager.default
        let pass = roots.prefix(maxReposPerPass).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
        onEvent?(.started(total: pass.count))
        for (position, root) in pass.enumerated() {
            if control?.isPauseRequested == true {
                s.pausedRemaining = Array(pass[position...])
                break
            }
            let name = URL(fileURLWithPath: root).lastPathComponent
            onEvent?(.repoStarted(index: position, name: name))
            var index = SemanticCorpusStore.loadIndex(repo: root, embedder: embedder)
            var manifest = SemanticCorpusStore.loadManifest(repo: root)
            let stats = RepoIndexer.indexDirectory(URL(fileURLWithPath: root), into: &index, manifest: &manifest,
                                                shouldStop: { control?.shouldInterrupt ?? false })
            // Saved even when interrupted: every manifest entry written so far
            // matches an embedded file, so the next pass resumes, not restarts.
            var outcome: RepoOutcome = .done
            do {
                try SemanticCorpusStore.save(repo: root, index: index, manifest: manifest)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            if stats.indexed > 0 || stats.removed > 0 { s.reposTouched += 1 }
            s.filesIndexed += stats.indexed
            s.chunks += stats.chunks
            if stats.interrupted, control?.consumeSkip() == true {
                if case .done = outcome { outcome = .skipped }
            } else if stats.interrupted {
                // Interrupted by a pause: this repo is not finished.
                s.pausedRemaining = Array(pass[position...])
                break
            }
            onEvent?(.repoFinished(index: position, name: name, outcome: outcome))
        }
        return s
    }
}
