import Foundation
import GRDB
import NaturalLanguage

/// Local full-text index over the user's Claude Code transcripts — so they (and
/// Claude itself, via the MCP server) can search PAST sessions for context the
/// current window has lost. 100% local (SQLite FTS5), incremental by file mtime,
/// no cloud / no embeddings in v1 (semantic search is a later stage; keyword +
/// phrase search is already high value).
///
/// On-wedge: Throttle indexes + serves; Claude's engine decides when to query.
struct TranscriptHit: Sendable, Identifiable {
    var id: String { "\(sessionId):\(ord)" }
    let project: String
    let sessionId: String
    let timestamp: Date
    let role: String        // "user" / "assistant"
    let snippet: String
    let ord: Int            // position within the session
}

enum TranscriptIndex {

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
    }
    static var dbURL: URL { dir.appendingPathComponent("transcript-index.db") }
    private static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Open (creating) the index DB with its FTS5 table + a file-watermark table.
    static func open() throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try DatabaseQueue(path: dbURL.path)
        try db.write { d in
            if try !d.tableExists("messages") {
                try d.create(virtualTable: "messages", using: FTS5()) { t in
                    t.column("text")
                    t.column("project").notIndexed()
                    t.column("session_id").notIndexed()
                    t.column("ts").notIndexed()
                    t.column("role").notIndexed()
                    t.column("ord").notIndexed()
                }
            }
            try d.execute(sql: "CREATE TABLE IF NOT EXISTS indexed_files (path TEXT PRIMARY KEY, mtime DOUBLE, rows INTEGER)")
        }
        return db
    }

    // MARK: - Indexing (incremental, mtime-watermarked)

    /// Index every transcript whose mtime is newer than what we last recorded.
    /// Returns the number of messages added. Bounded + off-main friendly.
    @discardableResult
    static func reindex(maxFiles: Int = 400) -> Int {
        guard let db = try? open() else { return 0 }
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return 0 }

        var added = 0
        var files: [(URL, Double)] = []
        for proj in projects {
            guard let jsonls = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in jsonls where url.pathExtension == "jsonl" {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                files.append((url, mtime))
            }
        }
        // Newest first, bounded.
        files.sort { $0.1 > $1.1 }
        for (url, mtime) in files.prefix(maxFiles) {
            let known = (try? db.read { try Double.fetchOne($0, sql: "SELECT mtime FROM indexed_files WHERE path = ?", arguments: [url.path]) }) ?? nil
            if let known, known >= mtime { continue }   // unchanged
            added += indexFile(url, into: db, project: decodeProject(url), mtime: mtime)
        }
        return added
    }

    private static func indexFile(_ url: URL, into db: DatabaseQueue, project: String, mtime: Double) -> Int {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let session = url.deletingPathExtension().lastPathComponent
        var rows = 0
        try? db.write { d in
            // Replace any prior rows for this session (re-index cleanly).
            try d.execute(sql: "DELETE FROM messages WHERE session_id = ?", arguments: [session])
            var ord = 0
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                // Skip giant lines (base64 images / huge tool dumps) — not useful
                // text and expensive to parse. Substring guard before JSON decode.
                if line.utf8.count > 60_000 { continue }
                guard line.contains("\"role\""), let text = extractText(String(line)) else { continue }
                let role = line.contains("\"role\":\"assistant\"") ? "assistant" : (line.contains("\"role\":\"user\"") ? "user" : "")
                guard role == "user" || role == "assistant", text.count > 8 else { continue }
                try d.execute(
                    sql: "INSERT INTO messages (text, project, session_id, ts, role, ord) VALUES (?,?,?,?,?,?)",
                    arguments: [text, project, session, mtime, role, ord])
                ord += 1; rows += 1
            }
            try d.execute(sql: "INSERT OR REPLACE INTO indexed_files (path, mtime, rows) VALUES (?,?,?)",
                          arguments: [url.path, mtime, rows])
        }
        return rows
    }

    /// Pull the human/assistant TEXT out of one transcript JSON line. Concatenates
    /// all `{"type":"text","text":…}` blocks; ignores tool calls / images.
    private static func extractText(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = msg["content"] as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { b -> String? in
            (b["type"] as? String) == "text" ? (b["text"] as? String) : nil
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Search

    /// FTS5 search across all indexed sessions. `query` is an FTS5 MATCH
    /// expression (plain words → implicit AND). Returns ranked hits with a
    /// highlighted snippet.
    static func search(_ query: String, limit: Int = 20) -> [TranscriptHit] {
        guard let db = try? open() else { return [] }
        let fts = sanitize(query)
        guard !fts.isEmpty else { return [] }
        return (try? db.read { d -> [TranscriptHit] in
            let rows = try Row.fetchAll(d, sql: """
                SELECT project, session_id, ts, role, ord,
                       snippet(messages, 0, '«', '»', ' … ', 12) AS snip
                FROM messages WHERE messages MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [fts, limit])
            return rows.map { r in
                TranscriptHit(
                    project: r["project"] ?? "", sessionId: r["session_id"] ?? "",
                    timestamp: Date(timeIntervalSince1970: r["ts"] ?? 0),
                    role: r["role"] ?? "", snippet: r["snip"] ?? "", ord: r["ord"] ?? 0)
            }
        }) ?? []
    }

    /// Make an arbitrary user query safe for FTS5 MATCH, EXPANDED with on-device
    /// word-embedding neighbours for semantic recall (e.g. "auth" also matches
    /// "login", "token") — so the user finds the right session even when they
    /// don't remember the exact word. All terms OR'd; FTS5 rank handles precision.
    private static func sanitize(_ q: String) -> String {
        let toks = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        var terms = Set(toks.map { $0.lowercased() })
        if let emb = NLEmbedding.wordEmbedding(for: .english) {
            for t in toks where t.count > 3 {
                for (neighbour, dist) in emb.neighbors(for: t.lowercased(), maximumCount: 3) where dist < 0.85 {
                    if neighbour.allSatisfy({ $0.isLetter }) { terms.insert(neighbour) }
                }
            }
        }
        return terms.prefix(24).map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    private static func decodeProject(_ jsonl: URL) -> String {
        // …/projects/-Users-kevin-GitHub-Throttle/<id>.jsonl → "Throttle"
        let folder = jsonl.deletingLastPathComponent().lastPathComponent
        return folder.split(separator: "-").map(String.init).last ?? folder
    }
}
