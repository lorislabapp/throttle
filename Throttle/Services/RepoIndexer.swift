import Foundation

/// Polyrepo ingestion for Chantier 4: walk a repo, read its text files, and feed
/// them through a `SemanticIndex`. Incremental — a per-doc content-hash manifest
/// lets unchanged files skip re-embedding, and files that vanished get their chunks
/// removed. Pure-Swift, no native deps. Heavy CLI/background work (it embeds every
/// chunk), never run inside an MCP tool call.
enum RepoIndexer {

    struct IndexStats: Sendable, Equatable {
        var scanned = 0      // eligible text files seen
        var indexed = 0      // (re)embedded this pass
        var unchanged = 0    // skipped via manifest hash
        var removed = 0      // docs gone from disk, evicted
        var chunks = 0       // chunks embedded this pass
    }

    /// Text file extensions worth indexing (code + docs + config).
    static let allowedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "js", "jsx", "ts", "tsx",
        "py", "rb", "go", "rs", "java", "kt", "kts", "php", "cs", "scala", "sh",
        "md", "markdown", "txt", "rst", "json", "yaml", "yml", "toml", "ini",
        "cfg", "html", "css", "scss", "sql", "graphql", "proto",
    ]

    /// Directory names pruned wholesale (build output, deps, VCS, caches).
    static let excludedDirs: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "dist",
        "out", "target", ".next", "vendor", ".venv", "venv", "__pycache__",
        ".swiftpm", ".gradle", "coverage", ".cache",
    ]

    /// Index `root` into `index`, updating `manifest` (relPath → content SHA-256).
    /// Mutates both in place; caller persists them.
    @discardableResult
    static func indexDirectory(_ root: URL, into index: inout SemanticIndex,
                               manifest: inout [String: String],
                               maxChars: Int = 1000, maxFileBytes: Int = 256 * 1024) -> IndexStats {
        var stats = IndexStats()
        let fm = FileManager.default
        let rootName = root.lastPathComponent
        let rootPath = root.standardizedFileURL.path
        var seen = Set<String>()

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return stats }

        while let url = en.nextObject() as? URL {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true {
                if excludedDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            guard rv?.isRegularFile == true,
                  allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }

            stats.scanned += 1
            if let size = rv?.fileSize, size > maxFileBytes { continue }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }   // binary → skip

            let rel = relativePath(of: url, under: rootPath)
            seen.insert(rel)
            let hash = ContentStore.sha256Hex(data)
            if manifest[rel] == hash { stats.unchanged += 1; continue }

            index.removeDoc(rel)                                   // evict stale chunks first
            let n = index.index(docId: rel, text: text,
                                metadata: ["repo": rootName, "path": rel], maxChars: maxChars)
            manifest[rel] = hash
            stats.indexed += 1; stats.chunks += n
        }

        // Evict docs that disappeared from disk since last pass.
        for rel in manifest.keys where !seen.contains(rel) {
            index.removeDoc(rel)
            manifest.removeValue(forKey: rel)
            stats.removed += 1
        }
        return stats
    }

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(p.dropFirst(rootPath.count + 1))
    }
}
