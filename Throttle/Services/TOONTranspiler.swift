import Foundation

/// JSON → TOON (Token-Oriented Object Notation) transpiler for the one shape
/// that actually wins: a top-level array of UNIFORM objects with scalar values.
/// JSON repeats every key on every row; TOON declares the keys once then emits
/// CSV-style rows — typically a large saving on big arrays.
///
///   [{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]
///   →
///   data[2]{id,name}:
///   1,Alice
///   2,Bob
///
/// PHASE 1 is MEASURE-ONLY: we never replace tool output, we only log how much
/// TOON *would* save, to a separate file (never savings.jsonl — that feeds the
/// realized-savings UI and must stay honest). The encoder is written lossless
/// (CSV quoting) so Phase 2 can reuse it to actually replace output.
enum TOONTranspiler {

    /// Encode `json` as TOON, or nil when the shape isn't TOON-favorable
    /// (not an array, < 2 elements, non-uniform keys, or any nested/non-scalar value).
    static func encode(_ json: Any, rootName: String = "data") -> String? {
        guard let arr = json as? [Any], arr.count >= 2,
              let first = arr.first as? [String: Any] else { return nil }
        let keys = first.keys.sorted()
        guard !keys.isEmpty else { return nil }

        var rows: [String] = []
        rows.reserveCapacity(arr.count)
        for el in arr {
            guard let obj = el as? [String: Any], obj.count == keys.count,
                  keys.allSatisfy({ obj[$0] != nil }) else { return nil }
            var cells: [String] = []
            cells.reserveCapacity(keys.count)
            for k in keys {
                guard let cell = scalarCell(obj[k]) else { return nil }   // nested → bail
                cells.append(cell)
            }
            rows.append(cells.joined(separator: ","))
        }
        let header = "\(rootName)[\(arr.count)]{\(keys.joined(separator: ","))}:"
        return ([header] + rows).joined(separator: "\n")
    }

    /// A single scalar cell, CSV-quoted when it contains a comma/quote/newline so
    /// the transform stays lossless. Returns nil for nested arrays/objects.
    private static func scalarCell(_ v: Any?) -> String? {
        let raw: String
        switch v {
        case let s as String: raw = s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { raw = n.boolValue ? "true" : "false" }
            else { raw = n.stringValue }
        case is NSNull, nil: raw = ""
        default: return nil   // array / dictionary → not flat
        }
        if raw.contains(",") || raw.contains("\"") || raw.contains("\n") {
            return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return raw
    }

    // MARK: - Phase 1 measurement

    /// If `text` is a TOON-favorable JSON array, log the potential saving to
    /// `toon-potential.jsonl` (measure-only) and return true. Never replaces
    /// output, never writes savings.jsonl. Any failure is a silent no-op.
    @discardableResult
    static func measurePotential(_ text: String, tool: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.utf8.count >= 600,
              let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let toon = encode(json) else { return false }

        let before = trimmed.utf8.count
        let after = toon.utf8.count
        guard after < before else { return false }   // only log a real would-be gain

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("toon-potential.jsonl")
        let rec: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "tool": tool,
            "json_bytes": before,
            "toon_bytes": after,
            "would_save_bytes": before - after,
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: rec) else { return true }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); h.write(Data([0x0a])); try? h.close()
        } else {
            try? (String(data: line, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        return true
    }
}
