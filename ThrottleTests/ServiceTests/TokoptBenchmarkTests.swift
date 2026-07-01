import XCTest
@testable import Throttle

/// The golden-dataset benchmark must MEASURE real savings on compressible outputs
/// AND prove the safety invariants (failing run + JSON array = no-op). A regression
/// that stops compressing, or starts mangling structured output, fails here.
final class TokoptBenchmarkTests: XCTestCase {

    func test_benchmark_compressesGreenTestAndBuildOutputs() {
        let report = TokoptBenchmark.run()
        func sample(_ name: String) -> TokoptBenchmark.Sample { report.samples.first { $0.name == name }! }

        // The reliable recipes: green test-runner + build-progress both shrink a lot.
        XCTAssertTrue(sample("cargo test (green)").compressed)
        XCTAssertGreaterThan(sample("cargo test (green)").reductionPct, 30)
        XCTAssertTrue(sample("npm install").compressed)
        XCTAssertGreaterThan(sample("npm install").reductionPct, 30)
        // NB: git status legitimately no-ops when the hint lines are a small fraction
        // of a big file list (<15% gain) — the benchmark measures that honestly rather
        // than overclaiming, so we don't assert a direction for it.
    }

    func test_benchmark_safetyInvariants_failuresAndJsonAreNoOps() {
        let report = TokoptBenchmark.run()
        func sample(_ name: String) -> TokoptBenchmark.Sample { report.samples.first { $0.name == name }! }

        // Failing test run: never touched.
        XCTAssertFalse(sample("cargo test (fail)").compressed)
        XCTAssertEqual(sample("cargo test (fail)").reductionPct, 0)
        // JSON array: never corrupted.
        XCTAssertFalse(sample("json array").compressed)
        XCTAssertEqual(sample("json array").compressedBytes, sample("json array").baselineBytes)
    }

    func test_report_aggregate_isMeasured() {
        let report = TokoptBenchmark.run()
        XCTAssertEqual(report.samples.count, 5)
        XCTAssertGreaterThan(report.overallReductionPct, 0)
        XCTAssertGreaterThan(report.estTokensSaved, 0)
        XCTAssertGreaterThanOrEqual(report.compressedCount, 2)
        // Sanity: compressed total never exceeds baseline (no negative "savings").
        XCTAssertLessThanOrEqual(report.totalCompressed, report.totalBaseline)
    }
}
