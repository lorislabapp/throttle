import Foundation
import GRDB

/// "Throttle Health" — operational self-checks with a traffic-light verdict and,
/// where safe, a 1-click fix. On-doctrine: a cockpit that audits ITSELF (the same
/// instinct as auditing your Claude usage). Every check reads real state; nothing
/// is faked. Most checks are diagnostic; only provably-safe fixes are offered.
enum HealthStatus: Sendable { case ok, warn, fail }

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

enum HealthCheckService {

    /// Run every check. Main-actor state is sampled first, then the heavy work
    /// (DB reads, `ps`, statfs) runs off-main.
    static func run(appState: AppState) async -> [HealthItem] {
        let database = await MainActor.run { appState.database }
        let exact = await MainActor.run { appState.exactSnapshot }
        let isPro = await MainActor.run { appState.isPro }

        return await Task.detached(priority: .utility) {
            var items: [HealthItem] = []
            items.append(trackingLive(database))
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
            return "Killed \(pids.count) orphaned process\(pids.count == 1 ? "" : "es")."
        }
    }

    // MARK: - Checks

    private static func trackingLive(_ db: any DatabaseReader) -> HealthItem {
        let last: Int64? = try? db.read { try Int64.fetchOne($0, sql: "SELECT MAX(timestamp) FROM usage_events") }
        guard let last else {
            return HealthItem(title: "Usage tracking", status: .warn, detail: "No usage events recorded yet.")
        }
        let age = Date().timeIntervalSince1970 - Double(last)
        if age < 600 { return HealthItem(title: "Usage tracking", status: .ok, detail: "Live — last event \(rel(age)) ago.") }
        if age < 3600 { return HealthItem(title: "Usage tracking", status: .warn, detail: "Last event \(rel(age)) ago — quiet, or ingestion stalled.") }
        return HealthItem(title: "Usage tracking", status: .fail, detail: "No events for \(rel(age)) — ingestion likely stopped. Check the hook/agent.")
    }

    private static func dbChecks(_ db: any DatabaseReader) -> [HealthItem] {
        var out: [HealthItem] = []

        // Dedup UNIQUE index (the H03 double-count guard).
        let hasIdx = (try? db.read {
            try Bool.fetchOne($0, sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_usage_natural'") ?? false
        }) ?? false
        out.append(hasIdx
            ? HealthItem(title: "Dedup index", status: .ok, detail: "UNIQUE idx_usage_natural present — re-scans can't double-count.")
            : HealthItem(title: "Dedup index", status: .fail, detail: "Missing UNIQUE idx_usage_natural — metrics may inflate on re-scan."))

        // Integrity + size.
        let integrity = (try? db.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }) ?? "unknown"
        let sizeBytes = (try? DatabaseManager.databaseURL())
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 } ?? 0
        let sizeMB = Double(sizeBytes) / 1_048_576
        if integrity == "ok" {
            out.append(HealthItem(title: "Database integrity", status: sizeMB > 800 ? .warn : .ok,
                                  detail: "quick_check OK · \(String(format: "%.0f", sizeMB)) MB\(sizeMB > 800 ? " — large, consider a prune" : "")."))
        } else {
            out.append(HealthItem(title: "Database integrity", status: .fail, detail: "quick_check: \(integrity)"))
        }
        return out
    }

    /// Orphaned claude/node processes (ppid==1 = their parent session died without
    /// reaping them) — the C01 RAM-leak class. Offers a 1-click kill.
    private static func orphanedProcesses() -> HealthItem {
        let out = shell(["/bin/ps", "-axo", "pid=,ppid=,comm="])
        var orphans: [Int32] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            let comm = f[2].lowercased()
            if ppid == 1 && (comm.contains("/node") || comm.hasSuffix("node") || comm.contains("claude")) {
                orphans.append(pid)
            }
        }
        if orphans.isEmpty {
            return HealthItem(title: "Orphaned processes", status: .ok, detail: "No stranded claude/node processes.")
        }
        return HealthItem(title: "Orphaned processes", status: .warn,
                          detail: "\(orphans.count) stranded claude/node process\(orphans.count == 1 ? "" : "es") holding RAM.",
                          fix: .killOrphans(orphans))
    }

    private static func memory() -> HealthItem {
        let m = SystemMemoryService.sample()
        let pct = Int(m.usedFraction * 100)
        let swapGB = String(format: "%.1f", Double(m.swapUsedBytes) / 1_073_741_824)
        if m.critical { return HealthItem(title: "Memory", status: .fail, detail: "Critical — \(pct)% used, \(swapGB) GB swap. Hibernate idle sessions.") }
        if m.underPressure { return HealthItem(title: "Memory", status: .warn, detail: "Under pressure — \(pct)% used, \(swapGB) GB swap.") }
        return HealthItem(title: "Memory", status: .ok, detail: "\(pct)% used, \(swapGB) GB swap.")
    }

    private static func disk() -> HealthItem {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? Int64,
              let total = attrs[.systemSize] as? Int64, total > 0 else {
            return HealthItem(title: "Disk", status: .warn, detail: "Couldn't read free space.")
        }
        let freeGB = Double(free) / 1_073_741_824
        let freePct = Double(free) / Double(total) * 100
        if freeGB < 5 { return HealthItem(title: "Disk", status: .fail, detail: String(format: "Only %.0f GB free (%.0f%%) — builds/notarize will fail.", freeGB, freePct)) }
        if freeGB < 15 { return HealthItem(title: "Disk", status: .warn, detail: String(format: "%.0f GB free (%.0f%%) — tight for archives.", freeGB, freePct)) }
        return HealthItem(title: "Disk", status: .ok, detail: String(format: "%.0f GB free (%.0f%%).", freeGB, freePct))
    }

    private static func exactMode(exact: ExactSnapshot?, isPro: Bool) -> HealthItem {
        guard isPro else { return HealthItem(title: "Exact mode", status: .ok, detail: "Estimate mode (Pro adds exact claude.ai sync).") }
        guard let exact else { return HealthItem(title: "Exact mode", status: .warn, detail: "No claude.ai snapshot yet.") }
        return exact.isFresh()
            ? HealthItem(title: "Exact mode", status: .ok, detail: "Fresh claude.ai snapshot.")
            : HealthItem(title: "Exact mode", status: .warn, detail: "Snapshot is stale — falling back to the local estimate.")
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
            return HealthItem(title: "Memory index size", status: .ok,
                              detail: "All MEMORY.md indexes under the 200-line / 25 KB auto-load cap.")
        }
        return HealthItem(title: "Memory index size", status: .warn,
                          detail: "\(over.count) MEMORY.md over the 200-line/25 KB cap — content past it is silently truncated and never reaches context: \(over.joined(separator: " · "))")
    }

    private static func cacheHygiene() -> HealthItem {
        let report = CacheHygieneService.scan()
        if report.highCount == 0 { return HealthItem(title: "Prompt-cache hooks", status: .ok, detail: "No cache-busting hooks detected.") }
        return HealthItem(title: "Prompt-cache hooks", status: .warn,
                          detail: "\(report.highCount) hook(s) inject volatile content into the cached prefix — busts the cache.")
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
