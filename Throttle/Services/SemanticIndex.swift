import Foundation

/// Orchestration layer for Chantier 4: turns an `EmbeddingProvider` + a
/// `VectorStore` into a usable semantic index. It chunks a document, embeds each
/// chunk, upserts them, and answers natural-language queries. Stack-agnostic — V1
/// is NLEmbedding + BruteForceVectorStore, but any provider/store combo works, so
/// the sqlite-vec/Wax + bge-small upgrade is a constructor swap, not a rewrite.
struct SemanticIndex {
    private(set) var store: BruteForceVectorStore
    let embedder: EmbeddingProvider

    init(embedder: EmbeddingProvider = NLEmbeddingProvider(), store: BruteForceVectorStore = .init()) {
        self.embedder = embedder
        self.store = store
    }

    var chunkCount: Int { store.count }

    /// Index one document: chunk → embed → upsert as `<docId>#<n>`. Re-indexing the
    /// same docId overwrites its chunks (id-dedup). Returns the number of chunks
    /// actually embedded (0 if the embedder is unavailable). Chunks that fail to
    /// embed are skipped, not faked.
    @discardableResult
    mutating func index(docId: String, text: String, metadata: [String: String] = [:], maxChars: Int = 1000) -> Int {
        let chunks = Self.chunk(text, maxChars: maxChars)
        var indexed = 0
        for (i, c) in chunks.enumerated() {
            guard let v = embedder.embed(c) else { continue }
            var md = metadata; md["doc"] = docId
            store.upsert(VectorRecord(id: "\(docId)#\(i)", vector: v, text: c, metadata: md))
            indexed += 1
        }
        return indexed
    }

    /// Query by natural-language text: embed it, then cosine-rank the store. Empty
    /// if the embedder can't embed the query (e.g. model absent).
    func search(_ query: String, k: Int = 5) -> [VectorHit] {
        guard let v = embedder.embed(query) else { return [] }
        return store.search(v, k: k)
    }

    func save(to url: URL) throws { try store.save(to: url) }

    /// Load a persisted store and pair it with an embedder for querying.
    static func load(from url: URL, embedder: EmbeddingProvider = NLEmbeddingProvider()) -> SemanticIndex {
        SemanticIndex(embedder: embedder, store: .load(from: url))
    }

    // MARK: - Chunking

    /// Paragraph-aware chunking: pack whole paragraphs up to `maxChars`, and
    /// hard-split any single paragraph that exceeds it. Pure + deterministic.
    static func chunk(_ text: String, maxChars: Int) -> [String] {
        let paras = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var cur = ""
        func flushOverlong() {
            while cur.count > maxChars {
                let cut = cur.index(cur.startIndex, offsetBy: maxChars)
                chunks.append(String(cur[..<cut]))
                cur = String(cur[cut...])
            }
        }
        for p in paras {
            if cur.isEmpty { cur = p }
            else if cur.count + 2 + p.count <= maxChars { cur += "\n\n" + p }
            else { chunks.append(cur); cur = p }
            flushOverlong()
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }
}
