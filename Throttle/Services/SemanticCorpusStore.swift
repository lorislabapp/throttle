import Foundation

/// Per-repo persistence for the semantic index (Chantier 4). Each repo gets its own
/// corpus directory (keyed by a hash of its absolute path) holding the vector store
/// + the content-hash manifest, so `--index-repo` can update incrementally and the
/// `throttle_semantic_search` MCP tool can load + query it later.
enum SemanticCorpusStore {

    /// Override-able for tests; defaults to the app-support store.
    nonisolated(unsafe) static var baseDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Throttle/semindex", isDirectory: true)

    /// Stable per-repo directory: a hash of the absolute path (avoids odd filename
    /// chars and cross-repo collisions).
    static func dir(forRepo repoPath: String) -> URL {
        let key = String(ContentStore.sha256Hex(Data(repoPath.utf8)).prefix(16))
        return baseDir.appendingPathComponent(key, isDirectory: true)
    }

    private static func indexURL(_ repoPath: String) -> URL { dir(forRepo: repoPath).appendingPathComponent("store.json") }
    private static func manifestURL(_ repoPath: String) -> URL { dir(forRepo: repoPath).appendingPathComponent("manifest.json") }

    static func loadIndex(repo repoPath: String, embedder: EmbeddingProvider = NLEmbeddingProvider()) -> SemanticIndex {
        SemanticIndex(embedder: embedder, store: .load(from: indexURL(repoPath)))
    }

    static func loadManifest(repo repoPath: String) -> [String: String] {
        guard let data = try? Data(contentsOf: manifestURL(repoPath)),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    static func save(repo repoPath: String, index: SemanticIndex, manifest: [String: String]) throws {
        try FileManager.default.createDirectory(at: dir(forRepo: repoPath), withIntermediateDirectories: true)
        try index.save(to: indexURL(repoPath))
        try JSONEncoder().encode(manifest).write(to: manifestURL(repoPath), options: .atomic)
    }

    /// Walk up from `start` to the nearest enclosing git repo root (dir containing
    /// `.git`); falls back to `start` itself if none is found. Lets the MCP tool
    /// resolve "this project" from the server's working directory.
    static func repoRoot(from start: URL) -> URL {
        var dir = start.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<40 {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return start.standardizedFileURL
    }
}
