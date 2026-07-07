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

    // MARK: - Trampoline (throttle-hook.sh) fail-open

    /// The trampoline's whole reason to exist: it must NEVER inject an error or
    /// alter output when anything is off (binary gone, kill-switch set). It only
    /// hands stdin through to a present binary. These run the real generated
    /// script under /bin/bash so we test the shipped bytes, not a mock.

    func test_trampoline_noopWhenBinaryMissing() {
        // App deleted/moved → BIN not executable → exit 0, no stdout, so Claude
        // Code keeps the original Bash output. This is the case reconcile() can't
        // cover (it lives in the now-missing app).
        let r = runTrampoline(execPath: "/nonexistent/throttle-\(UUID().uuidString)",
                              stdin: #"{"tool_name":"Bash","tool_response":{"stdout":"x"}}"#)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.isEmpty, "missing binary must emit nothing")
    }

    func test_trampoline_disabledByEnv_neverCallsBinary() {
        let dir = tmpDir()
        let sentinel = dir.appendingPathComponent("called")
        let fake = makeExecutable(at: dir.appendingPathComponent("fakebin"),
                                  body: "touch '\(sentinel.path)'\n")
        let r = runTrampoline(execPath: fake.path, stdin: "{}",
                              env: ["CLAUDE_DISABLE_TOKOPT_HOOKS": "1"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path),
                       "kill-switch must short-circuit before the binary runs")
    }

    func test_trampoline_passesStdinThroughToPresentBinary() {
        // Fake BIN ignores the --tokopt-hook arg and echoes a sentinel + its
        // stdin → proves exec hands the JSON payload straight through unmangled.
        let fake = makeExecutable(at: tmpDir().appendingPathComponent("fakebin"),
                                  body: "printf 'SENTINEL:'\ncat\n")
        let r = runTrampoline(execPath: fake.path, stdin: "PAYLOAD123")
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, "SENTINEL:PAYLOAD123")
    }

    func test_scriptContents_hasFailOpenInvariants() {
        let s = TokoptHookInstaller.scriptContents(execPath: "/Applications/Throttle.app/Contents/MacOS/Throttle")
        XCTAssertTrue(s.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(s.contains("CLAUDE_DISABLE_TOKOPT_HOOKS"), "kill-switch honored")
        XCTAssertTrue(s.contains(#"[ -x "$BIN" ] || exit 0"#), "guards a missing binary")
        XCTAssertTrue(s.contains("exec \"$BIN\" --tokopt-hook"), "hands off to the binary")
        XCTAssertFalse(s.contains("set -e"), "no set -e — must not turn a no-op into a nonzero exit")
    }

    // MARK: - Trampoline test helpers

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeExecutable(at url: URL, body: String) -> URL {
        try! ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func runTrampoline(execPath: String, stdin: String,
                               env: [String: String] = [:]) -> (code: Int32, out: String) {
        let script = tmpDir().appendingPathComponent("throttle-hook.sh")
        try! TokoptHookInstaller.scriptContents(execPath: execPath)
            .write(to: script, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let inPipe = Pipe(); let outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
        try! p.run()
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: outData, encoding: .utf8) ?? "")
    }
}
