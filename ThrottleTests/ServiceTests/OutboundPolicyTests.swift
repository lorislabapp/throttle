@testable import Throttle
import ThrottleShared
import XCTest

/// Canaries are synthetic: shaped like real credentials, never real ones.
final class OutboundPolicyTests: XCTestCase {
    private let canaries: [(String, String)] = [
        ("sk-ant-api03-SYNTHETICcanary0123456789", "anthropic-key"),
        ("ghp_SYNTHETICcanary0123456789abcdefgh", "github-token"),
        ("github_pat_SYNTHETIC_canary0123456789abc", "github-token"),
        ("AuthKey_SYNTH3T1C.p8", "apple-auth-key"),
        ("AKIASYNTHETICCANARY1", "aws-access-key"),
        ("xoxb-1234567890-synthetic-canary", "slack-token"),
        ("Bearer synthetic.canary.token_0123456789", "bearer-token"),
        ("sk-SYNTHETICcanary0123456789", "secret-key"),
        ("-----BEGIN PRIVATE KEY-----\nMIIsynthetic\n-----END PRIVATE KEY-----", "private-key")
    ]

    func test_everyCredentialShapeIsMaskedByKindAndNeverEchoed() {
        for (canary, kind) in canaries {
            let text = "path /Users/synthetic/" + canary + "/notes"
            let scrubbed = OutboundPolicy.scrub(text)
            XCTAssertFalse(scrubbed.contains(canary), kind)
            XCTAssertTrue(scrubbed.contains("[redacted:" + kind + "]"), scrubbed)
            XCTAssertEqual(OutboundPolicy.findings(in: text), [kind], kind)
        }
    }

    func test_cleanTextAndOrdinaryPathsAreLeftUntouched() {
        let clean = ["/Users/synthetic/GitHub/Throttle", "claude-opus-5", "skateboard-2026", "sk-short",
                     "bearer of bad news", "ghp_tooShort", "12,345,\"quoted\"\n"]
        for text in clean {
            XCTAssertEqual(OutboundPolicy.scrub(text), text)
            XCTAssertEqual(OutboundPolicy.findings(in: text), [])
        }
    }

    func test_severalTokensInOneLineAreAllMasked() {
        let line = "sk-ant-api03-SYNTHETICcanary0123456789 then ghp_SYNTHETICcanary0123456789abcdefgh end"
        let scrubbed = OutboundPolicy.scrub(line)
        XCTAssertEqual(scrubbed, "[redacted:anthropic-key] then [redacted:github-token] end")
    }
}
