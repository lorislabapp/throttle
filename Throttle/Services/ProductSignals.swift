import CryptoKit
import Foundation

/// Product signals start as read-only imports of what Throttle already holds
/// about itself; connectors that need a credential come later and only per
/// user. The first signal is the MetricKit diagnostics `CrashReporter`
/// persists locally: nothing is collected that was not already on disk, and
/// nothing leaves the machine.
enum ProductSignals {
    struct DiagnosticSummary: Equatable, Sendable {
        /// Distinct payloads after dropping byte-identical duplicates and
        /// payloads sharing a delivery timestamp — one delivery is one signal.
        var payloads = 0
        var duplicatesDropped = 0
        var unreadable = 0
        var crashes = 0
        var hangs = 0
        var cpuExceptions = 0
        /// Seconds since the newest payload was delivered; nil without payloads.
        var freshnessSeconds: TimeInterval?
        /// Distinct days with a payload inside the window, over the window.
        var coverageDays = 0
        var windowDays: Int
        var coverage: Double { windowDays > 0 ? Double(coverageDays) / Double(windowDays) : 0 }
    }

    /// Reads `diagnostic-*.json` files as written by `CrashReporter`. A file
    /// that does not parse counts as unreadable rather than as zero crashes.
    static func diagnostics(in directory: URL, now: Date = Date(), windowDays: Int = 14) -> DiagnosticSummary {
        var summary = DiagnosticSummary(windowDays: windowDays)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("diagnostic-") && $0.hasSuffix(".json") }.sorted()
        var contentDigests = Set<String>()
        var deliveries = Set<Date>()
        var days = Set<String>()
        let calendar = Calendar(identifier: .iso8601)
        let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: now) ?? now
        var newest: Date?
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                summary.unreadable += 1
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard contentDigests.insert(digest).inserted else { summary.duplicatesDropped += 1; continue }
            let delivered = deliveryDate(object) ?? modificationDate(url) ?? now
            guard deliveries.insert(delivered).inserted else { summary.duplicatesDropped += 1; continue }
            summary.payloads += 1
            summary.crashes += count(object["crashDiagnostics"])
            summary.hangs += count(object["hangDiagnostics"])
            summary.cpuExceptions += count(object["cpuExceptionDiagnostics"])
            newest = max(newest ?? delivered, delivered)
            if delivered >= windowStart {
                let parts = calendar.dateComponents([.year, .month, .day], from: delivered)
                days.insert("\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)")
            }
        }
        summary.freshnessSeconds = newest.map { now.timeIntervalSince($0) }
        summary.coverageDays = days.count
        return summary
    }

    private static func count(_ value: Any?) -> Int {
        (value as? [Any])?.count ?? 0
    }

    /// MetricKit writes `timeStampEnd` as "yyyy-MM-dd HH:mm:ss Z"; ISO 8601 is
    /// accepted too so a synthetic payload can be authored by hand.
    static func deliveryDate(_ object: [String: Any]) -> Date? {
        guard let text = object["timeStampEnd"] as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: text)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
