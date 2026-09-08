import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    /// Tabs already associated with the same checkout. Canonicalizing both sides
    /// catches `/tmp/link/project` vs `/Users/me/project` and trailing-slash
    /// variants before the UI asks whether to focus or intentionally duplicate.
    func sessions(inProjectAt cwd: String) -> [CockpitTab] {
        let target = Self.canonicalCWD(cwd)
        return sessions
            .filter { Self.canonicalCWD($0.cwd) == target }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    nonisolated static func canonicalCWD(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    // MARK: - Project picker (existing projects only)

    struct Project: Identifiable, Hashable { let id = UUID(); let name: String; let cwd: String }

    /// Distinct project working dirs from past sessions whose cwd still exists,
    /// most-recent first. Light: reads ≤64 KB of one transcript per project.
    func recentProjects(limit: Int = 12) -> [Project] {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard
            let dirs = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        let sorted = dirs.sorted {
            let firstDate =
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let secondDate =
                (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return firstDate > secondDate
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var out: [Project] = []
        for dir in sorted {
            guard let cwd = Self.projectCwd(dir), !seen.contains(cwd) else { continue }
            // Skip the home dir itself and obvious non-projects (temp/hidden).
            guard cwd != home, !cwd.hasPrefix("/private/"), !cwd.hasPrefix("/tmp"),
                  !(cwd as NSString).lastPathComponent.hasPrefix(".") else { continue }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { continue }
            seen.insert(cwd)
            out.append(Project(name: (cwd as NSString).lastPathComponent, cwd: cwd))
            if out.count >= limit { break }
        }
        return out
    }

    static func projectCwd(_ projectDir: URL) -> String? {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil)
        else { return nil }
        for url in entries.filter({ $0.pathExtension == "jsonl" }).prefix(2) {
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            let chunk = (try? fh.read(upToCount: 65_536)) ?? Data()
            guard let text = String(data: chunk, encoding: .utf8),
                  let r = text.range(of: "\"cwd\":\"") ?? text.range(of: "\"cwd\": \"") else { continue }
            let rest = text[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[..<end]).replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(
                of: "\\\\", with: "\\")
        }
        return nil
    }
}
