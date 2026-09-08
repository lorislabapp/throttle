import AppKit
import Foundation
import GRDB

/// Support exports contain only allowlisted facts. Raw diagnostic sources remain
/// on this Mac and are never copied into the archive.
@MainActor
enum DiagnosticsExporter {
    /// Called only after the user confirms the frozen preview. Do not reread the
    /// database here: the exported payload must be the one the user reviewed.
    static func exportToDesktop(report: DiagnosticReport) async -> URL? {
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else { return nil }
        return await Task.detached(priority: .utility) {
            try? DiagnosticArchive.write(report, to: desktop)
        }.value
    }

    /// The same typed payload can back the support preview.
    static func buildReport(database: any DatabaseReader) -> DiagnosticReport {
        let counts: [Int?] = (try? database.read { connection in
            [try? Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM usage_events"),
             try? Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM usage_snapshots"),
             try? Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM tokopt_savings")]
        }) ?? [nil, nil, nil]
        let hooks = HookStatusService.currentStatus()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticReport(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            usageEvents: counts[0], usageSnapshots: counts[1], savingsEvents: counts[2],
            sessionHook: hooks.sessionStartRouterInstalled,
            compactHook: hooks.preCompactExtractorInstalled, killSwitch: hooks.killSwitchSet,
            exactState: ExactModeService.shared.lastError != nil ? .error
                : (ExactModeService.shared.lastSnapshot == nil ? .unavailable : .available))
    }

}
