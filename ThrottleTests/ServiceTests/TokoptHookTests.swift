import XCTest
@testable import Throttle

/// Tests for the PostToolUse(Bash) token-optimization hook, focused on the
/// test-runner recipe. The cardinal invariant: a FAILING run is never altered
/// (no line dropped, no rewrite) — only green runs get their passing chatter
/// collapsed, and even then no diagnostic line may be removed.
final class TokoptHookTests: XCTestCase {

    // MARK: - Command detection

    func test_isTestCommand_recognizesRunners() {
        for c in ["cargo test", "go test ./...", "swift test", "pytest -q",
                  "npm test", "yarn test", "npx jest", "python3 -m pytest tests/",
                  "./gradlew test", "mvn test", "make check", "deno test", "bun test",
                  "cd app && cargo test"] {
            XCTAssertTrue(TokoptHook.isTestCommand(c), "should detect: \(c)")
        }
    }

    func test_isTestCommand_rejectsNonTests() {
        for c in ["cargo build", "go build", "npm run dev", "git status",
                  "swift build", "make", "python3 app.py", "yarn lint"] {
            XCTAssertFalse(TokoptHook.isTestCommand(c), "should NOT detect: \(c)")
        }
    }

    // MARK: - Green run collapse

    func test_testRunnerRecipe_collapsesGreenCargo() {
        let out = """
        running 3 tests
        test tests::a ... ok
        test tests::b ... ok
        test tests::c ... ok

        test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
        """
        let r = TokoptHook.testRunnerRecipe(out)
        XCTAssertNotNil(r)
        XCTAssertFalse(r!.contains("test tests::a ... ok"), "passing lines dropped")
        XCTAssertTrue(r!.contains("test result: ok. 3 passed"), "summary kept")
        XCTAssertTrue(r!.contains("[Throttle: collapsed passing test lines"), "breadcrumb added")
    }

    func test_compress_endToEnd_greenCargoShrinks() {
        let out = (0..<200).map { "test mod::case_\($0) ... ok" }.joined(separator: "\n")
            + "\n\ntest result: ok. 200 passed; 0 failed; 0 ignored; finished in 0.10s\n"
        let c = TokoptHook.compress(out, command: "cargo test")
        XCTAssertLessThan(c.utf8.count, out.utf8.count / 2, "should shrink a large green suite")
        XCTAssertTrue(c.contains("200 passed"))
        XCTAssertFalse(c.contains("case_100 ... ok"))
    }

    // MARK: - Failure safety (the cardinal rule)

    func test_testRunnerRecipe_noopOnFailure() {
        let out = """
        running 2 tests
        test tests::a ... ok
        test tests::b ... FAILED

        failures:

        ---- tests::b stdout ----
        thread 'tests::b' panicked at 'boom'

        test result: FAILED. 1 passed; 1 failed; finished in 0.01s
        """
        XCTAssertNil(TokoptHook.testRunnerRecipe(out), "any failure → verbatim (nil)")
    }

    func test_testRunnerRecipe_noopOnGoFail() {
        let out = """
        === RUN   TestFoo
        --- FAIL: TestFoo (0.00s)
            foo_test.go:12: want 1 got 2
        FAIL
        FAIL    example.com/foo 0.123s
        """
        XCTAssertNil(TokoptHook.testRunnerRecipe(out))
    }

    func test_testRunnerRecipe_keepsWarnings() {
        let out = """
        running 1 test
        test a ... ok
        warning: unused variable `x`
        test result: ok. 1 passed; 0 failed; finished in 0.00s
        """
        let r = TokoptHook.testRunnerRecipe(out)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("warning: unused variable"), "warnings are never dropped")
    }

    // MARK: - No-collapse cases return nil

    func test_testRunnerRecipe_nilWhenNoSummary() {
        // Plain `go test` green output is only "ok pkg" lines — dropping them
        // leaves no summary, so we bail rather than emit an empty blob.
        let out = """
        ok   example.com/foo   0.123s
        ok   example.com/bar   0.456s
        """
        XCTAssertNil(TokoptHook.testRunnerRecipe(out))
    }
}
