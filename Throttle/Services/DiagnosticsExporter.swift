import AppKit
import Foundation
import GRDB

/// Bundles a small, anonymized diagnostics report for support requests.
/// Contains: app version, macOS version, log file, anonymized DB stats,
/// hook installation status, last exact-mode error. NO usage-event content
/// or model details — token counts only.
@MainActor
enum DiagnosticsExporter {
    static func exportToDesktop(database: any DatabaseReader) -> URL? {
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let folder = fm.temporaryDirectory.appendingPathComponent("throttle-diagnostics-\(timestamp)")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // 1. Summary text file.
        let summary = buildSummary(database: database)
        let summaryURL = folder.appendingPathComponent("summary.txt")
        try? summary.write(to: summaryURL, atomically: true, encoding: .utf8)

        // 2. App log file (already exists).
        let logSrc = AppLogger.logFileURL
        if fm.fileExists(atPath: logSrc.path) {
            let logDst = folder.appendingPathComponent("throttle.log")
            try? fm.copyItem(at: logSrc, to: logDst)
        }

        // 3. Hook savings JSONL (just the most recent 200 lines).
        let savingsSrc = SavingsIngester.logFileURL
        if fm.fileExists(atPath: savingsSrc.path),
           let raw = try? String(contentsOf: savingsSrc, encoding: .utf8) {
            let lines = raw.split(separator: "\n").suffix(200).joined(separator: "\n")
            let dst = folder.appendingPathComponent("savings.jsonl")
            try? lines.write(to: dst, atomically: true, encoding: .utf8)
        }

        // 4. MetricKit crash + hang payloads (if any).
        let crashDir = CrashReporter.payloadsDirectory
        if let entries = try? fm.contentsOfDirectory(at: crashDir,
                                                    includingPropertiesForKeys: nil),
           !entries.isEmpty {
            let crashDst = folder.appendingPathComponent("crash-payloads", isDirectory: true)
            try? fm.createDirectory(at: crashDst, withIntermediateDirectories: true)
            for src in entries {
                try? fm.copyItem(at: src, to: crashDst.appendingPathComponent(src.lastPathComponent))
            }
        }

        // 5. Zip the folder onto the Desktop.
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let zipURL = desktop.appendingPathComponent("throttle-diagnostics-\(timestamp).zip")
        return zipFolder(folder, to: zipURL) ? zipURL : nil
    }

    private static func buildSummary(database: any DatabaseReader) -> String {
        var lines: [String] = []
        lines.append("Throttle diagnostics — \(Date().ISO8601Format())")
        lines.append("")
        lines.append("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        lines.append("Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")
        lines.append("--- Database stats ---")

        let stats: [String] = (try? database.read { db in
            var out: [String] = []
            let eventCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events")) ?? 0
            out.append("usage_events: \(eventCount)")
            let snapCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_snapshots")) ?? 0
            out.append("usage_snapshots: \(snapCount)")
            let savingsCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tokopt_savings")) ?? 0
            out.append("tokopt_savings: \(savingsCount)")
            let cals = (try? Row.fetchAll(db, sql: "SELECT window_kind, cap_tokens, source FROM calibration ORDER BY window_kind")) ?? []
            for row in cals {
                let kind: String = row["window_kind"] ?? "?"
                let cap: Int = row["cap_tokens"] ?? 0
                let src: String = row["source"] ?? "?"
                out.append("calibration[\(kind)]: cap=\(cap) source=\(src)")
            }
            return out
        }) ?? ["(database unreadable)"]
        lines.append(contentsOf: stats)

        lines.append("")
        lines.append("--- Hook status ---")
        let h = HookStatusService.currentStatus()
        lines.append("session-start-router: \(h.sessionStartRouterInstalled ? "installed" : "missing")")
        lines.append("pre-compact: \(h.preCompactExtractorInstalled ? "installed" : "missing")")
        lines.append("kill switch (CLAUDE_DISABLE_TOKOPT_HOOKS): \(h.killSwitchSet ? "set" : "unset")")

        lines.append("")
        lines.append("--- Exact mode ---")
        if let err = ExactModeService.shared.lastError {
            lines.append("Last error: \(err)")
        } else if let snap = ExactModeService.shared.lastSnapshot {
            lines.append("Last snapshot: \(snap.fetchedAt.ISO8601Format()) — 5h=\(snap.fiveHour.utilization)%, 7d=\(snap.sevenDay.utilization)%, sonnet=\(snap.sevenDaySonnet.utilization)%")
        } else {
            lines.append("Never polled.")
        }

        return lines.joined(separator: "\n")
    }

    private static func zipFolder(_ folder: URL, to zipURL: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--keepParent", folder.path, zipURL.path]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
