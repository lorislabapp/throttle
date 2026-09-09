@testable import Throttle
import XCTest

/// Synthetic payloads only: the shape of a MetricKit diagnostic, never a real one.
final class ProductSignalsTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("product-signals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, daysAgo: Double, crashes: Int = 0, hangs: Int = 0, cpu: Int = 0) throws {
        let delivered = now.addingTimeInterval(-daysAgo * 86_400)
        let payload: [String: Any] = [
            "timeStampEnd": ISO8601DateFormatter().string(from: delivered),
            "crashDiagnostics": Array(repeating: ["synthetic": true], count: crashes),
            "hangDiagnostics": Array(repeating: ["synthetic": true], count: hangs),
            "cpuExceptionDiagnostics": Array(repeating: ["synthetic": true], count: cpu)
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(name))
    }

    func test_countsDeliveriesOnceAndMeasuresFreshnessAndCoverage() throws {
        try write("diagnostic-a.json", daysAgo: 1, crashes: 2)
        try write("diagnostic-b.json", daysAgo: 1, crashes: 2)          // byte-identical duplicate
        try write("diagnostic-c.json", daysAgo: 3, hangs: 1)
        try write("diagnostic-d.json", daysAgo: 3, hangs: 0, cpu: 1)    // same delivery, different content
        try write("diagnostic-e.json", daysAgo: 20, crashes: 5)          // outside the window, still counted
        try write("metric-f.json", daysAgo: 0, crashes: 9)               // metrics are not diagnostics
        try "not json".write(to: directory.appendingPathComponent("diagnostic-z.json"),
                             atomically: true, encoding: .utf8)

        let summary = ProductSignals.diagnostics(in: directory, now: now, windowDays: 14)
        XCTAssertEqual(summary.payloads, 3)
        XCTAssertEqual(summary.duplicatesDropped, 2)
        XCTAssertEqual(summary.unreadable, 1)
        XCTAssertEqual(summary.crashes, 7)
        XCTAssertEqual(summary.hangs, 1)
        XCTAssertEqual(summary.cpuExceptions, 0)
        XCTAssertEqual(summary.freshnessSeconds ?? -1, 86_400, accuracy: 1)
        XCTAssertEqual(summary.coverageDays, 2)
        XCTAssertEqual(summary.coverage, 2.0 / 14, accuracy: 1e-9)
    }

    func test_emptyOrMissingDirectoryIsNotASignal() {
        let summary = ProductSignals.diagnostics(in: directory.appendingPathComponent("absent"), now: now)
        XCTAssertEqual(summary, ProductSignals.DiagnosticSummary(windowDays: 14))
        XCTAssertNil(summary.freshnessSeconds)
        XCTAssertEqual(summary.coverage, 0)
    }

    func test_metricKitTimestampFormatIsAccepted() {
        let date = ProductSignals.deliveryDate(["timeStampEnd": "2026-09-08 10:00:00 +0000"])
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-09-08T10:00:00Z"))
        XCTAssertNil(ProductSignals.deliveryDate(["timeStampEnd": "yesterday"]))
    }
}
