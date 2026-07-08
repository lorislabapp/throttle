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

    // MARK: - Phase 1.5 readout (measure-only summary)

    /// Accumulated, would-be TOON savings read straight from `toon-potential.jsonl`.
    /// Measure-only: this is what Phase 2 (CCR) *could* save, never realized spend —
    /// the UI must label it as potential and stay honest (golden rule).
    struct Potential: Sendable, Equatable {
        var samples = 0
        var jsonBytes = 0
        var toonBytes = 0
        var savedBytes = 0
        var since: Date?
        var topTool: String?

        /// Fraction of the measured JSON bytes TOON would shed (0…1).
        var savedFraction: Double { jsonBytes > 0 ? Double(savedBytes) / Double(jsonBytes) : 0 }
        /// Rough token equivalent of the saved bytes (~4 bytes/token, English-ish).
        var savedTokensApprox: Int { TokenEstimate.fromBytes(savedBytes, kind: .dense) }   // structured data → dense ratio
        var hasData: Bool { samples > 0 && savedBytes > 0 }
    }

    private static var potentialURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
            .appendingPathComponent("toon-potential.jsonl")
    }

    /// Fold `toon-potential.jsonl` into a single summary. Pure file read, no DB,
    /// silent no-op (empty summary) on any failure — safe to call off-main.
    static func potentialSummary() -> Potential {
        guard let raw = try? String(contentsOf: potentialURL, encoding: .utf8) else { return Potential() }
        var out = Potential()
        var byTool: [String: Int] = [:]
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jb = rec["json_bytes"] as? Int,
                  let tb = rec["toon_bytes"] as? Int else { continue }
            let saved = (rec["would_save_bytes"] as? Int) ?? max(0, jb - tb)
            out.samples += 1
            out.jsonBytes += jb
            out.toonBytes += tb
            out.savedBytes += saved
            if let ts = rec["ts"] as? Int {
                let d = Date(timeIntervalSince1970: TimeInterval(ts))
                if out.since == nil || d < out.since! { out.since = d }
            }
            if let tool = rec["tool"] as? String { byTool[tool, default: 0] += saved }
        }
        out.topTool = byTool.max { $0.value < $1.value }?.key
        return out
    }
}
