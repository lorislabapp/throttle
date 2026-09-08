import Foundation

/// Typed allowlist for support exports: no arbitrary log, error, path or provider
/// label enters this contract. Unknown counts are not silently reported as zero.
struct DiagnosticReport: Sendable {
    enum ExactState: String, Sendable { case unavailable, error, available }

    var version: String
    var build: String
    var osVersion: String
    var usageEvents: Int?
    var usageSnapshots: Int?
    var savingsEvents: Int?
    var sessionHook: Bool
    var compactHook: Bool
    var killSwitch: Bool
    var exactState: ExactState

    static let exportedFiles: Set<String> = ["summary.txt"]

    var text: String {
        [
            "Throttle diagnostics — summary only",
            "App version: \(Self.versionLabel(version))",
            "Build: \(Self.versionLabel(build))",
            "macOS: \(Self.versionLabel(osVersion))",
            "usage_events: \(Self.countLabel(usageEvents))",
            "usage_snapshots: \(Self.countLabel(usageSnapshots))",
            "tokopt_savings: \(Self.countLabel(savingsEvents))",
            "session-start-router: \(sessionHook ? "installed" : "missing")",
            "pre-compact: \(compactHook ? "installed" : "missing")",
            "kill switch: \(killSwitch ? "set" : "unset")",
            "Exact mode: \(exactState.rawValue)",
            "Excluded: logs, commands, paths, sessions, model labels, raw errors and crash payloads."
        ].joined(separator: "\n")
    }

    private static func versionLabel(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              value.utf8.contains(where: { (48...57).contains($0) }) else { return "unknown" }
        return value
    }

    private static func countLabel(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "unknown" }
        return String(value)
    }
}
