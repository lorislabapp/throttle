import Foundation
import Testing
@testable import ThrottleShared

/// The mirror leaves this Mac. Its free-form names come from the machine and
/// the filesystem, so they are whatever a person once typed — including, one
/// day, a folder or a hostname with a token in it. Canaries here are
/// synthetic: shaped like credentials, never real ones.
@Suite("Mirror payload outbound policy")
struct MirrorOutboundPolicyTests {
    private let canary = "sk-ant-api03-SYNTHETICcanary0123456789"

    private func snapshot(
        deviceName: String = "Kevin's Mac", project: String = "Throttle",
        model: String? = "claude-opus-5", fallbackHost: String? = nil, edgeHost: String? = nil
    ) -> ThrottleMirrorSnapshot {
        ThrottleMirrorSnapshot(
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            deviceName: deviceName,
            fiveHour: WindowMirror(utilization: 40, resetsAt: nil),
            sevenDay: WindowMirror(utilization: 20, resetsAt: nil),
            sevenDaySonnet: WindowMirror(utilization: 10, resetsAt: nil),
            weeklyTokens: 1_000, weeklyCostEUR: 2.5, savedTokensThisWeek: 10,
            sessionCount: 1,
            tabs: [TabMirror(id: "t1", projectName: project, state: "working", model: model,
                         eur: 1.5, tokens: 900, isLive: true, needsInput: false,
                         rateLimitedUntil: nil)],
            peerPairingSecret: "pairing-secret-base64",
            peerFallbackHost: fallbackHost, edgeHost: edgeHost
        )
    }

    @Test("a credential in any name is masked by kind before the payload leaves")
    func credentialsAreMasked() throws {
        let scrubbed = snapshot(
            deviceName: "Mac " + canary, project: "/Users/synthetic/" + canary,
            model: canary, fallbackHost: "host-" + canary, edgeHost: "edge-" + canary
        ).scrubbedForPublication()

        let encoded = try #require(String(data: JSONEncoder().encode(scrubbed), encoding: .utf8))
        #expect(!encoded.contains("SYNTHETICcanary"), "no shape of the token survives anywhere")
        #expect(scrubbed.deviceName == "Mac [redacted:anthropic-key]")
        #expect(scrubbed.tabs.first?.projectName == "/Users/synthetic/[redacted:anthropic-key]")
        #expect(scrubbed.tabs.first?.model == "[redacted:anthropic-key]")
        #expect(scrubbed.peerFallbackHost == "host-[redacted:anthropic-key]")
        #expect(scrubbed.edgeHost == "edge-[redacted:anthropic-key]")
    }

    @Test("ordinary names, numbers and the pairing secret are left exactly as they are")
    func nothingElseIsRewritten() {
        let original = snapshot()
        let scrubbed = original.scrubbedForPublication()
        #expect(scrubbed.deviceName == original.deviceName)
        #expect(scrubbed.tabs.first?.projectName == "Throttle")
        #expect(scrubbed.tabs.first?.model == "claude-opus-5")
        #expect(scrubbed.weeklyCostEUR == original.weeklyCostEUR)
        #expect(scrubbed.tabs.first?.tokens == 900)
        #expect(scrubbed.schemaVersion == original.schemaVersion)
        #expect(scrubbed.publishedAt == original.publishedAt)
        #expect(scrubbed.peerPairingSecret == "pairing-secret-base64",
                "the pairing secret is deliberate, and masking it would break the LAN link")
        #expect(scrubbed.peerFallbackHost == nil && scrubbed.edgeHost == nil,
                "an absent host stays absent rather than becoming an empty string")
    }

    @Test("scrubbing is idempotent, so a re-published payload does not decay")
    func idempotent() {
        let once = snapshot(deviceName: "Mac " + canary).scrubbedForPublication()
        #expect(once.scrubbedForPublication() == once)
    }
}
