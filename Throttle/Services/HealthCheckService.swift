import Foundation
import GRDB

/// "Throttle Health" — operational self-checks with a traffic-light verdict and,
/// where safe, a 1-click fix. On-doctrine: a cockpit that audits ITSELF (the same
/// instinct as auditing your Claude usage). Every check reads real state; nothing
/// is faked. Most checks are diagnostic; only provably-safe fixes are offered.
enum HealthStatus: Sendable, Equatable { case ok, warn, fail }

/// A safe, explicit remediation the UI can run on the main actor. Modeled as data
/// (not a closure) so the check can be computed off-main and stay Sendable.
enum HealthFix: Sendable, Equatable {
    case none
    case killOrphans([Int32])   // orphaned claude/node PIDs (the C01 RAM-leak class)
}

struct HealthItem: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let status: HealthStatus
    let detail: String
    var fix: HealthFix = .none
}

struct UsageTrackingSnapshot: Sendable, Equatable {
    let lastEvent: Int64?
    let sourceFileCount: Int
    let pendingFileCount: Int
    let newestSourceMtime: Int64?
}

enum HealthCheckService {

    /// Run every check. Main-actor state is sampled first, then the heavy work
    /// (DB reads, `ps`, statfs) runs off-main.
    static func run(appState: AppState) async -> [HealthItem] {
        let database = await MainActor.run { appState.database }
        let exact = await MainActor.run { appState.exactSnapshot }
        let isPro = await MainActor.run { appState.isPro }

        return await Task.detached(priority: .utility) {
            var items: [HealthItem] = []
            items.append(trackingLive(database, root: ClaudeCodePathProvider.projectsDirectory()))
            items.append(contentsOf: dbChecks(database))
            items.append(orphanedProcesses())
            items.append(memory())
            items.append(disk())
            items.append(exactMode(exact: exact, isPro: isPro))
            items.append(cacheHygiene())
            items.append(memoryIndexCap())
            return items
        }.value
    }

    /// Execute a fix and return a short result line for the UI.
    @MainActor
    static func apply(_ fix: HealthFix) -> String {
        switch fix {
        case .none: return ""
        case .killOrphans(let pids):
            for pid in pids { kill(pid, SIGKILL) }
            return pids.count == 1
                ? String(localized: "Terminated 1 orphaned process.")
                : String.localizedStringWithFormat(
                    String(localized: "Terminated %lld orphaned processes."), pids.count)
        }
    }

    // MARK: - Checks

    private static func trackingLive(_ db: any DatabaseReader, root: URL?) -> HealthItem {
        let last: Int64? = try? db.read { try Int64.fetchOne($0, sql: "SELECT MAX(timestamp) FROM usage_events") }
        guard let root else {
            return HealthItem(title: String(localized: "Usage tracking"), status: .warn,
                              detail: String(localized: "Claude Code project transcripts were not found."))
        }
        let files = ColdStartScanner.discoverJsonlFiles(under: root)
        let offsets: [String: Int64] = (try? db.read { database in
            Dictionary(uniqueKeysWithValues: try FileState.fetchAll(database).map { ($0.path, $0.lastOffset) })
        }) ?? [:]

        var pending = 0
        var newestMtime: Int64?
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            let path = file.standardizedFileURL.path
            let size = Int64(values.fileSize ?? 0)
            if size > (offsets[path] ?? 0) { pending += 1 }
            if let mtime = values.contentModificationDate {
                let seconds = Int64(mtime.timeIntervalSince1970)
                newestMtime = max(newestMtime ?? seconds, seconds)
            }
        }
        return trackingItem(snapshot: UsageTrackingSnapshot(
            lastEvent: last,
            sourceFileCount: files.count,
            pendingFileCount: pending,
            newestSourceMtime: newestMtime
        ))
    }

    static func trackingItem(snapshot: UsageTrackingSnapshot, now: Date = Date()) -> HealthItem {
        if snapshot.sourceFileCount == 0 {
            return HealthItem(title: String(localized: "Usage tracking"), status: .warn,
                              detail: String(localized: "No top-level Claude Code transcripts found yet."))
        }
        if snapshot.pendingFileCount > 0 {
            let sourceAge = snapshot.newestSourceMtime.map {
                max(0, now.timeIntervalSince1970 - Double($0))
            } ?? .infinity
            if sourceAge < 600 {
                let detail = snapshot.pendingFileCount == 1
                    ? String(localized: "Ingesting 1 updated transcript.")
                    : String.localizedStringWithFormat(
                        String(localized: "Ingesting %lld updated transcripts."),
                        snapshot.pendingFileCount)
                return HealthItem(title: String(localized: "Usage tracking"), status: .warn,
                                  detail: detail)
            }
            let detail = snapshot.pendingFileCount == 1
                ? String.localizedStringWithFormat(
                    String(localized: "1 transcript is still pending after %@ — ingestion is stalled."),
                    rel(sourceAge))
                : String.localizedStringWithFormat(
                    String(localized: "%lld transcripts are still pending after %@ — ingestion is stalled."),
                    snapshot.pendingFileCount, rel(sourceAge))
            return HealthItem(title: String(localized: "Usage tracking"), status: .fail,
                              detail: detail)
        }
        guard let last = snapshot.lastEvent else {
            return HealthItem(title: String(localized: "Usage tracking"), status: .ok,
                              detail: String(localized: "Caught up — no billable assistant event recorded yet."))
        }
        let eventAge = max(0, now.timeIntervalSince1970 - Double(last))
        return HealthItem(title: String(localized: "Usage tracking"), status: .ok,
                          detail: String.localizedStringWithFormat(
                            String(localized: "Caught up — last billable event %@ ago."),
                            rel(eventAge)))
    }

    private static func dbChecks(_ db: any DatabaseReader) -> [HealthItem] {
        var out: [HealthItem] = []

        // Dedup UNIQUE index (the H03 double-count guard).
        let hasIdx = (try? db.read {
            try Bool.fetchOne($0, sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_usage_natural'") ?? false
        }) ?? false
        out.append(hasIdx
            ? HealthItem(title: String(localized: "Dedup index"), status: .ok,
                         detail: String(localized: "UNIQUE idx_usage_natural present — re-scans can't double-count."))
            : HealthItem(title: String(localized: "Dedup index"), status: .fail,
                         detail: String(localized: "Missing UNIQUE idx_usage_natural — metrics may inflate on re-scan.")))

        // Integrity + size.
        let integrity = (try? db.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }) ?? "unknown"
        let sizeBytes = (try? DatabaseManager.databaseURL())
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 } ?? 0
        let sizeMB = Double(sizeBytes) / 1_048_576
        if integrity == "ok" {
            let detail = sizeMB > 800
                ? String.localizedStringWithFormat(
                    String(localized: "quick_check OK · %.0f MB — large, consider a prune."), sizeMB)
                : String.localizedStringWithFormat(
                    String(localized: "quick_check OK · %.0f MB."), sizeMB)
            out.append(HealthItem(title: String(localized: "Database integrity"),
                                  status: sizeMB > 800 ? .warn : .ok, detail: detail))
        } else {
            out.append(HealthItem(title: String(localized: "Database integrity"), status: .fail,
                                  detail: String.localizedStringWithFormat(
                                    String(localized: "quick_check: %@"), integrity)))
        }
        return out
    }

    /// Orphaned claude/node processes (ppid==1 = their parent session died without
    /// reaping them) — the C01 RAM-leak class. Offers a 1-click kill.
    private static func orphanedProcesses() -> HealthItem {
        let out = shell(["/bin/ps", "-axo", "pid=,ppid=,command="])
        let orphans = orphanedClaudePIDs(from: out)
        if orphans.isEmpty {
            return HealthItem(title: String(localized: "Orphaned processes"), status: .ok,
                              detail: String(localized: "No stranded Claude Code processes."))
        }
        let detail = orphans.count == 1
            ? String(localized: "1 stranded Claude Code process is holding RAM.")
            : String.localizedStringWithFormat(
                String(localized: "%lld stranded Claude Code processes are holding RAM."), orphans.count)
        return HealthItem(title: String(localized: "Orphaned processes"), status: .warn,
                          detail: detail,
                          fix: .killOrphans(orphans))
    }

    static func orphanedClaudePIDs(from processList: String) -> [Int32] {
        var orphans: [Int32] = []
        for line in processList.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            let command = f[2].lowercased()
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let basename = (executable as NSString).lastPathComponent
            let isClaudeCode = basename == "claude"
                || executable.contains("/.local/share/claude/")
                || command.contains("/@anthropic-ai/claude-code/")
            if ppid == 1 && isClaudeCode {
                orphans.append(pid)
            }
        }
        return orphans
    }

    private static func memory() -> HealthItem {
        let m = SystemMemoryService.sample()
        let pct = Int(m.usedFraction * 100)
        let swapGB = String(format: "%.1f", Double(m.swapUsedBytes) / 1_073_741_824)
        if m.critical {
            return HealthItem(title: String(localized: "Memory"), status: .fail,
                              detail: String.localizedStringWithFormat(
                                String(localized: "Critical — %lld%% used, %@ GB swap. Hibernate idle sessions."), pct, swapGB))
        }
        if m.underPressure {
            return HealthItem(title: String(localized: "Memory"), status: .warn,
                              detail: String.localizedStringWithFormat(
                                String(localized: "Under pressure — %lld%% used, %@ GB swap."), pct, swapGB))
        }
        return HealthItem(title: String(localized: "Memory"), status: .ok,
                          detail: String.localizedStringWithFormat(
                            String(localized: "%lld%% used, %@ GB swap."), pct, swapGB))
    }

    private static func disk() -> HealthItem {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? Int64,
              let total = attrs[.systemSize] as? Int64, total > 0 else {
            return HealthItem(title: String(localized: "Disk"), status: .warn,
                              detail: String(localized: "Couldn't read free space."))
        }
        let freeGB = Double(free) / 1_073_741_824
        let freePct = Double(free) / Double(total) * 100
        if freeGB < 5 {
            return HealthItem(title: String(localized: "Disk"), status: .fail,
                              detail: String.localizedStringWithFormat(
                                String(localized: "Only %.0f GB free (%.0f%%) — builds/notarize will fail."), freeGB, freePct))
        }
        if freeGB < 15 {
            return HealthItem(title: String(localized: "Disk"), status: .warn,
                              detail: String.localizedStringWithFormat(
                                String(localized: "%.0f GB free (%.0f%%) — tight for archives."), freeGB, freePct))
        }
        return HealthItem(title: String(localized: "Disk"), status: .ok,
                          detail: String.localizedStringWithFormat(
                            String(localized: "%.0f GB free (%.0f%%)."), freeGB, freePct))
    }

    private static func exactMode(exact: ExactSnapshot?, isPro: Bool) -> HealthItem {
        guard isPro else {
            return HealthItem(title: String(localized: "Exact mode"), status: .ok,
                              detail: String(localized: "Estimate mode (Pro adds exact claude.ai sync)."))
        }
        guard let exact else {
            return HealthItem(title: String(localized: "Exact mode"), status: .warn,
                              detail: String(localized: "No claude.ai snapshot yet."))
        }
        return exact.isFresh()
            ? HealthItem(title: String(localized: "Exact mode"), status: .ok,
                         detail: String(localized: "Fresh claude.ai snapshot."))
            : HealthItem(title: String(localized: "Exact mode"), status: .warn,
                         detail: String(localized: "Snapshot is stale — falling back to the local estimate."))
    }

    /// MEMORY.md hard-cap audit (verified 2026-07-12 against docs.claude.com/memory):
    /// the auto-loaded memory index silently truncates at 200 lines / 25 KB — content
    /// past that never reaches context, so memories the user thinks are live are
    /// silently dead. CLAUDE.md is NOT truncated (200 lines is only a soft guideline
    /// there), so this check scopes to MEMORY.md files only. Warn-only per doctrine:
    /// segmentation rewrites live memory content, that stays the user's call.
    static func memoryIndexCap() -> HealthItem {
        let maxLines = 200, maxBytes = 25 * 1024
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        var over: [String] = []
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for proj in projects {
            let index = proj.appendingPathComponent("memory/MEMORY.md")
            guard let text = try? String(contentsOf: index, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let bytes = text.utf8.count
            if lines > maxLines || bytes > maxBytes {
                over.append("\(proj.lastPathComponent) (\(lines) lines, \(bytes / 1024) KB)")
            }
        }
        if over.isEmpty {
            return HealthItem(title: String(localized: "Memory index size"), status: .ok,
                              detail: String(localized: "All MEMORY.md indexes under the 200-line / 25 KB auto-load cap."))
        }
        return HealthItem(title: String(localized: "Memory index size"), status: .warn,
                          detail: String.localizedStringWithFormat(
                            String(localized: "%lld MEMORY.md over the 200-line/25 KB cap — content past it is silently truncated and never reaches context: %@"),
                            over.count, over.joined(separator: " · ")))
    }

    private static func cacheHygiene() -> HealthItem {
        let report = CacheHygieneService.scan()
        if report.highCount == 0 {
            return HealthItem(title: String(localized: "Prompt-cache hooks"), status: .ok,
                              detail: String(localized: "No cache-busting hooks detected."))
        }
        return HealthItem(title: String(localized: "Prompt-cache hooks"), status: .warn,
                          detail: String.localizedStringWithFormat(
                            String(localized: "%lld hook(s) inject volatile content into the cached prefix — busts the cache."),
                            report.highCount))
    }

    // MARK: - Helpers

    private static func shell(_ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func rel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 90 { return "\(s)s" }
        if s < 5400 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
