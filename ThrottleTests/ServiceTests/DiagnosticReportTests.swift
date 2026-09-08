@testable import Throttle
import XCTest

final class DiagnosticReportTests: XCTestCase {
    private var nominal: DiagnosticReport {
        DiagnosticReport(version: "3.6.0", build: "219", osVersion: "14.0",
                         usageEvents: 10, usageSnapshots: 2, savingsEvents: 0,
                         sessionHook: true, compactHook: false, killSwitch: false, exactState: .error)
    }

    func test_exportAllowsOnlySummary() {
        XCTAssertEqual(DiagnosticReport.exportedFiles, ["summary.txt"])
        XCTAssertTrue(nominal.text.contains("usage_events: 10"))
        XCTAssertTrue(nominal.text.contains("Exact mode: error"))
    }

    func test_privateCanariesCannotEnterVersionFields() {
        let canaries = ["/Users/synthetic/private", "sk-example-secret", "219\nsecret", "۲۱۹",
                        String(repeating: "1", count: 33)]
        for canary in canaries {
            var report = nominal
            report.version = canary
            report.build = canary
            report.osVersion = canary
            XCTAssertFalse(report.text.contains(canary))
            XCTAssertTrue(report.text.contains("App version: unknown"))
        }
    }

    func test_unavailableCountsAreNotZero() {
        var report = nominal
        report.usageEvents = nil
        report.usageSnapshots = -1
        XCTAssertTrue(report.text.contains("usage_events: unknown"))
        XCTAssertTrue(report.text.contains("usage_snapshots: unknown"))
        XCTAssertTrue(report.text.contains("tokopt_savings: 0"))
    }
}
