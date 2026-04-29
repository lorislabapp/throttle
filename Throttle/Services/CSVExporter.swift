import AppKit
import Foundation
import GRDB

/// Exports the full `usage_events` history as a CSV file on the user's
/// Desktop. Power users (Anthropic Pro Max, multi-org accounts) ask for
/// this regularly — they want to pivot the data in their own tooling.
///
/// Format: one row per event, ISO-8601 timestamp, columns sized for
/// Excel/Numbers/Google Sheets without escaping headaches. No usage
/// content is exported — just token counts, timestamps, model name,
/// and project path. Same privacy posture as DiagnosticsExporter.
@MainActor
enum CSVExporter {
    static func exportToDesktop(database: any DatabaseReader) -> URL? {
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let csvURL = desktop.appendingPathComponent("throttle-usage-\(timestamp).csv")

        let header = "timestamp_iso,model,input_tokens,output_tokens,cache_create,cache_read,project_path\n"
        guard let handle = try? makeFileHandle(at: csvURL, header: header) else { return nil }
        defer { try? handle.close() }

        let sql = """
            SELECT timestamp, model, input_tokens, output_tokens,
                   cache_create, cache_read, project_path
            FROM usage_events
            ORDER BY timestamp ASC
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
        let proj: String = row["project_path"] ?? ""
        return "\(iso),\(escape(model)),\(i),\(o),\(cc),\(cr),\(escape(proj))\n"
    }

    /// Quote any field that contains a comma, quote, or newline; double
    /// embedded quotes per RFC 4180.
    private static func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
