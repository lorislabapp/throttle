import AppKit
import Foundation
import GRDB
import ThrottleShared

/// Exports the full `usage_events` history as a CSV file on the user's
/// Desktop. Power users (Anthropic Pro Max, multi-org accounts) ask for
/// this regularly — they want to pivot the data in their own tooling.
///
/// Format: one row per event, ISO-8601 timestamp, columns sized for
/// Excel/Numbers/Google Sheets without escaping headaches. No usage
/// content is exported — just token counts, timestamps, model name,
/// and project path. This is more sensitive than the allowlisted support summary.
@MainActor
enum CSVExporter {
    static func exportToDesktop(database: any DatabaseReader) -> URL? {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        return export(database: database, to: desktop)
    }

    /// The export is the user's own data on their own disk, so project paths
    /// stay legible; credential-shaped strings are masked at this boundary all
    /// the same (`OutboundPolicy`), whatever produced them upstream.
    static func export(database: any DatabaseReader, to directory: URL) -> URL? {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let csvURL = directory.appendingPathComponent("throttle-usage-\(timestamp).csv")

        let header = "timestamp_iso,model,input_tokens,output_tokens,cache_create,cache_read,project\n"
        guard let handle = try? makeFileHandle(at: csvURL, header: header) else { return nil }
        var complete = false
        defer {
            try? handle.close()
            // A header-only file is not an export; leave nothing behind on failure.
            if !complete { try? FileManager.default.removeItem(at: csvURL) }
        }

        // `usage_events` never carried a project column: the previous SELECT
        // failed on every database and the export silently produced nothing.
        // The project is the transcript's encoded directory, reached through
        // the session's file state; a session without one exports blank.
        let sql = """
            SELECT u.timestamp, u.model, u.input_tokens, u.output_tokens,
                   u.cache_create, u.cache_read,
                   COALESCE((SELECT f.encoded_project FROM file_state f
                             WHERE f.session_id = u.session_id AND f.encoded_project IS NOT NULL
                             LIMIT 1), '') AS project
            FROM usage_events u
            ORDER BY u.timestamp ASC, u.id ASC
            """
        do {
            try database.read { db in
                let cursor = try Row.fetchCursor(db, sql: sql)
                while let row = try cursor.next() {
                    let line = csvLine(from: row)
                    if let data = line.data(using: .utf8) {
                        try handle.write(contentsOf: data)
                    }
                }
            }
        } catch {
            return nil
        }
        complete = true
        return csvURL
    }

    private static func makeFileHandle(at url: URL, header: String) throws -> FileHandle {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        if let data = header.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
        return handle
    }

    private static func csvLine(from row: Row) -> String {
        let ts: Int64 = row["timestamp"] ?? 0
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
        let model: String = row["model"] ?? ""
        let i: Int = row["input_tokens"] ?? 0
        let o: Int = row["output_tokens"] ?? 0
        let cc: Int = row["cache_create"] ?? 0
        let cr: Int = row["cache_read"] ?? 0
        let proj: String = row["project"] ?? ""
        return "\(iso),\(escape(OutboundPolicy.scrub(model))),\(i),\(o),\(cc),\(cr),"
            + "\(escape(OutboundPolicy.scrub(proj)))\n"
    }

    /// Quote any field that contains a comma, quote, or newline; double
    /// embedded quotes per RFC 4180.
    private static func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
