import Foundation
import MetricKit
import OSLog

/// Captures crash + hang diagnostics via Apple's MetricKit and persists them
/// alongside the app log. No third-party telemetry, no network calls — the
/// payloads stay in `~/Library/Application Support/com.lorislab.throttle/`
/// and are picked up by `DiagnosticsExporter` when the user runs Export.
///
/// MetricKit on macOS surfaces payloads on launch, ~24h after the
/// crash/hang occurred. We log a one-liner per payload so the user (and
/// support@lorislab.fr) can see *that* something happened and the file path,
/// without us having to ship a full crash UI in v1.x.
///
/// @unchecked Sendable: MetricKit's `receiveReports` callback is documented
/// as main-actor-isolated (per Apple's MetricKit docs). All state mutations
/// happen on MainActor via the callback, no cross-actor access.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()

    private let logger = Logger(subsystem: AppLogger.subsystem, category: "CrashReporter")

    /// Directory where MetricKit payloads are dumped as JSON for later
    /// inclusion in the diagnostics zip.
    static var payloadsDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("com.lorislab.throttle", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        logger.info("CrashReporter subscribed to MetricKit")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            persist(json: payload.jsonRepresentation(),
                    prefix: "metric",
                    timestamp: payload.timeStampEnd)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persist(json: payload.jsonRepresentation(),
                    prefix: "diagnostic",
                    timestamp: payload.timeStampEnd)
            // Emit a crisp app-log line so the user sees a flag in the log
            // viewer the first time they open Settings after a crash.
            let crashCount = payload.crashDiagnostics?.count ?? 0
            let hangCount = payload.hangDiagnostics?.count ?? 0
            let cpuCount = payload.cpuExceptionDiagnostics?.count ?? 0
            let summary = "MXDiagnostic: crashes=\(crashCount) hangs=\(hangCount) cpuExceptions=\(cpuCount)"
            logger.error("\(summary)")
            AppLogger.appendToFile("CrashReporter: \(summary)")
        }
    }

    private func persist(json: Data, prefix: String, timestamp: Date) {
        let stamp = ISO8601DateFormatter().string(from: timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.payloadsDirectory
            .appendingPathComponent("\(prefix)-\(stamp).json")
        try? json.write(to: url, options: .atomic)
    }
}
