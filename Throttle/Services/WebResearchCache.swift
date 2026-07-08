import Foundation
import GRDB

/// Text cache behind web_render (Rank-3). The costly part of a render is spinning
/// up WKWebView and waiting for the page to settle — so a repeat render of the same
/// URL within a TTL returns the previously-extracted text instead of rendering
/// again. Extracted text is content-addressed in `ContentStore` (SHA-256, free
/// dedup + 30-day expiry); `web_fetches` maps a normalized URL → that hash.
///
/// Embeddings would be free (on-device NLEmbedding), so the win here is skipping
/// the *render*, not embed tokens. Fail-open: any DB/blob miss just means "render".
enum WebResearchCache {

    struct Hit { let text: String; let ageSeconds: Int }

    /// Synthetic "repo" key for the semantic corpus of rendered pages, so
    /// research_grounded can retrieve prior research by MEANING (not just by exact
    /// URL). Keyed like any repo corpus — `SemanticCorpusStore` hashes the path.
    static let webCorpusKey = "__throttle_web_corpus__"
    /// Only the app writes this corpus (during a render); serialize its
    /// load→modify→save so two concurrent records never clobber each other.
    private static let corpusQ = DispatchQueue(label: "throttle.web.corpus")

    /// Canonical key: drop fragment, lowercase host, strip tracking params, sort the
    /// rest, trim a trailing slash. Over-normalizing collapses distinct pages, so we
    /// only strip well-known tracking params — meaningful query params are kept.
    static func normalize(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return raw.lowercased() }
        c.fragment = nil
        c.host = c.host?.lowercased()
        if let items = c.queryItems {
            let tracking: Set<String> = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid", "ref"]
            let kept = items.filter { !tracking.contains($0.name.lowercased()) }.sorted { $0.name < $1.name }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        var s = (c.string ?? raw)
        if s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    /// Freshest cached text for `url` within `ttl`, or nil (→ caller renders).
    static func lookup(_ url: String, ttl: TimeInterval, reader: any DatabaseReader) -> Hit? {
        let norm = normalize(url)
        let cutoff = Int(Date().timeIntervalSince1970 - ttl)
        let found: (String, Int)? = (try? reader.read { db in
            try Row.fetchOne(db, sql: """
                SELECT content_hash, fetched_at FROM web_fetches
                WHERE url_normalized = ? AND fetched_at >= ?
                ORDER BY fetched_at DESC LIMIT 1
                """, arguments: [norm, cutoff]).map { (($0["content_hash"] as String), ($0["fetched_at"] as Int)) }
        }) ?? nil
        guard let (hash, at) = found,
              let data = ContentStore.get(hash),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Hit(text: text, ageSeconds: max(0, Int(Date().timeIntervalSince1970) - at))
    }

    /// Store extracted text + record the fetch, then index the page into the `__web__`
    /// semantic corpus for later meaning-based recall. Best-effort / fail-open.
    static func record(url: String, text: String, title: String, renderMs: Int, sessionId: String?, writer: any DatabaseWriter) {
        guard !text.isEmpty else { return }
        let hash = ContentStore.put(Data(text.utf8))   // content-addressed; identical pages dedupe to one blob
        let norm = normalize(url)
        let now = Int(Date().timeIntervalSince1970)
        try? writer.write { db in
            try db.execute(sql: """
                INSERT INTO web_fetches (url_normalized, content_hash, fetched_at, render_ms, text_bytes, session_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [norm, hash, now, renderMs, text.utf8.count, sessionId])
        }
        indexPage(url: url, norm: norm, title: title, text: text)
    }

    /// Add/replace the page in the `__web__` semantic corpus (on-device embeddings,
    /// free). Serialized on `corpusQ` so concurrent renders don't clobber the store.
    private static func indexPage(url: String, norm: String, title: String, text: String) {
        corpusQ.async {
            var index = SemanticCorpusStore.loadIndex(repo: webCorpusKey)
            var manifest = SemanticCorpusStore.loadManifest(repo: webCorpusKey)
            index.removeDoc(norm)   // replace any prior copy of this URL
            _ = index.index(docId: norm, text: text, metadata: ["url": url, "title": title])
            manifest[norm] = ContentStore.sha256Hex(Data(text.utf8))
            try? SemanticCorpusStore.save(repo: webCorpusKey, index: index, manifest: manifest)
        }
    }
}
