import Foundation

/// OKF v0.1 (Chantier 2) — Open Knowledge Format. A validated research result
/// compiled into a PORTABLE bundle: a markdown file with a small YAML frontmatter
/// header (okf_version, title, created, confidence, tags, sources) followed by a
/// markdown body. Plain files → copyable anywhere, no lock-in, human-diffable.
/// The frontmatter is hand-serialized/parsed (no YAML dependency) for the narrow,
/// known schema we emit.
struct OKFBundle: Sendable, Equatable {
    var title: String
    var confidence: String          // "high" | "medium" | "low"
    var tags: [String]
    var sources: [String]
    var created: Date
    var body: String
    static let version = "0.1"
}

enum OKFStore {

    /// Override-able for tests; defaults to the app-support store.
    nonisolated(unsafe) static var baseDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Throttle/okf", isDirectory: true)

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    // MARK: - Serialize / parse

    static func serialize(_ b: OKFBundle) -> String {
        var s = "---\n"
        s += "okf_version: \(OKFBundle.version)\n"
        s += "title: \(b.title)\n"
        s += "created: \(iso.string(from: b.created))\n"
        s += "confidence: \(b.confidence)\n"
        s += "tags: [\(b.tags.joined(separator: ", "))]\n"
        s += "sources:\n"
        for src in b.sources { s += "  - \(src)\n" }
        s += "---\n\n"
        s += b.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return s
    }

    static func parse(_ text: String) -> OKFBundle? {
        // Frontmatter is the block between the first two `---` fences.
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        let header = Array(lines[1..<close])
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var title = "", confidence = "", created = Date.distantPast
        var tags: [String] = [], sources: [String] = []
        var inSources = false
        for raw in header {
            let line = raw
            if inSources {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") { sources.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)); continue }
                inSources = false   // a non-list line ends the block
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "title": title = val
            case "confidence": confidence = val
            case "created": created = iso.date(from: val) ?? Date.distantPast
            case "tags":
                let inner = val.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                tags = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "sources":
                inSources = true   // entries follow on subsequent `  - ` lines
            default: break
            }
        }
        guard !title.isEmpty else { return nil }
        return OKFBundle(title: title, confidence: confidence, tags: tags, sources: sources, created: created, body: body)
    }

    // MARK: - IO

    @discardableResult
    static func write(_ b: OKFBundle) throws -> URL {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let url = baseDir.appendingPathComponent("\(slug(b.title)).okf.md")
        try serialize(b).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func list() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix(".okf.md") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func read(_ url: URL) -> OKFBundle? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(parse)
    }

    /// Bundles whose title or tags contain `topic` (case-insensitive).
    static func search(_ topic: String) -> [OKFBundle] {
        list().compactMap(read).filter {
            $0.title.localizedCaseInsensitiveContains(topic)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(topic) }
        }
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "bundle" : collapsed
    }
}
