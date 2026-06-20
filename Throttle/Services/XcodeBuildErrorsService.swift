import Foundation

/// Pulls DISTILLED errors/warnings from the most recent Xcode build result and
/// formats them for pasting into a `claude` session — so a failing build becomes
/// one click instead of a copy-paste of a wall of log. Reads the structured
/// `.xcresult` via `xcresulttool` (no fragile .xcactivitylog SLF parsing). Local
/// only. Best-effort: returns nil if no recent build result is found.
enum XcodeBuildErrorsService {

    struct Issue { let isError: Bool; let message: String; let file: String?; let line: Int? }

    /// Distilled text for the newest build, or nil if none. `projectHint` (a cwd
    /// folder name) softly prefers that project's DerivedData when several builds
    /// are recent.
    static func distilledErrors(projectHint: String?, includeWarnings: Bool = false) -> String? {
        guard let result = newestBuildResult(projectHint: projectHint) else { return nil }
        let json = shell(["/usr/bin/xcrun", "xcresulttool", "get", "build-results", "--path", result.path, "--compact"])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var issues = parse(root["errors"], isError: true)
        if includeWarnings { issues += parse(root["warnings"], isError: false) }
        guard !issues.isEmpty else {
            return includeWarnings ? nil : "Last Xcode build of \(result.name) had no errors. 🎉"
        }

        // Dedupe + cap so we paste a tight, token-cheap summary, not a log dump.
        var seen = Set<String>(); var lines: [String] = []
        for i in issues {
            let loc = [i.file, i.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
            let tag = i.isError ? "error" : "warning"
            let line = loc.isEmpty ? "• \(tag): \(i.message)" : "• \(loc) — \(tag): \(i.message)"
            if seen.insert(line).inserted { lines.append(line) }
            if lines.count >= 25 { break }
        }
        let header = "Xcode build of \(result.name) failed with \(issues.filter(\.isError).count) error(s)"
            + (issues.count > lines.count ? " (showing first \(lines.count)):" : ":")
        return header + "\n" + lines.joined(separator: "\n")
            + "\n\nPlease fix these."
    }

    // MARK: - Parsing

    private static func parse(_ raw: Any?, isError: Bool) -> [Issue] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.map { obj in
            let msg = (obj["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let (file, line) = locating(obj["sourceURL"] as? String)
            return Issue(isError: isError, message: msg, file: file, line: line)
        }
    }

    /// `sourceURL` looks like `file:///…/File.swift#…&StartingLineNumber=11&…`.
    /// Pull the basename + the (0-based) starting line, presented 1-based.
    private static func locating(_ sourceURL: String?) -> (String?, Int?) {
        guard let s = sourceURL, let hash = s.firstIndex(of: "#") else {
            return (sourceURL.flatMap { URL(string: $0)?.lastPathComponent }, nil)
        }
        let path = String(s[..<hash])
        let file = URL(string: path)?.lastPathComponent
        var line: Int?
        for part in s[s.index(after: hash)...].split(separator: "&") {
            if part.hasPrefix("StartingLineNumber="), let n = Int(part.dropFirst("StartingLineNumber=".count)) {
                line = n + 1   // xcresult line numbers are 0-based
            }
        }
        return (file, line)
    }

    // MARK: - Locating the newest result bundle

    private struct BuildResult { let path: String; let name: String; let mtime: Date }

    private static func newestBuildResult(projectHint: String?) -> BuildResult? {
        let dd = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let fm = FileManager.default
        guard let projDirs = try? fm.contentsOfDirectory(atPath: dd) else { return nil }

        var found: [BuildResult] = []
        for proj in projDirs where !proj.hasPrefix(".") {
            let buildLogs = "\(dd)/\(proj)/Logs/Build"
            guard let entries = try? fm.contentsOfDirectory(atPath: buildLogs) else { continue }
            let name = String(proj.split(separator: "-").dropLast().joined(separator: "-"))
            for e in entries where e.hasSuffix(".xcresult") {
                let full = "\(buildLogs)/\(e)"
                let mtime = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? .distantPast
                found.append(BuildResult(path: full, name: name.isEmpty ? proj : name, mtime: mtime ?? .distantPast))
            }
        }
        guard !found.isEmpty else { return nil }

        // Prefer the project the user is in, if one of its builds is reasonably
        // recent; otherwise the globally newest build (what they just ran).
        if let hint = projectHint?.lowercased(), !hint.isEmpty {
            let matches = found.filter { $0.name.lowercased().contains(hint) || hint.contains($0.name.lowercased()) }
            if let best = matches.max(by: { $0.mtime < $1.mtime }) { return best }
        }
        return found.max(by: { $0.mtime < $1.mtime })
    }

    // MARK: - Helper

    private static func shell(_ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
