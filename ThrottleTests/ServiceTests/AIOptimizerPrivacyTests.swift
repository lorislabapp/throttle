@testable import Throttle
import XCTest

@MainActor
final class AIOptimizerPrivacyTests: XCTestCase {
    private let validResponse = """
    ===THROTTLE-FILE===
    Run the documented tests. Keep safety checks.
    ===THROTTLE-ENDFILE===
    ===THROTTLE-WHY===
    - Removed a duplicate instruction.
    """

    func testNetworkProvidersReceiveNoInstructionBytes() async throws {
        for kind in [AIProviderKind.selfHostedModel, .claudeWebSession, .claudeAPIKey] {
            let probe = OptimizerRequestProbe()
            let provider = OptimizerFixtureProvider(kind: kind, response: validResponse, probe: probe)
            do {
                _ = try await optimize("SYNTHETIC_PRIVATE_INSTRUCTION", provider: provider)
                XCTFail("Network provider must be refused")
            } catch AIOptimizerService.OptimizerError.localModelRequired {
                let requests = await probe.messages
                XCTAssertTrue(requests.isEmpty)
            }
        }
    }

    func testSettingsNeverReachAnyModelIncludingOnDevice() async throws {
        for kind in AIProviderKind.allCases {
            let probe = OptimizerRequestProbe()
            let provider = OptimizerFixtureProvider(kind: kind, response: validResponse, probe: probe)
            let labels = [".claude/settings.json", ".claude/settings.local.json", "settings.local.json", "../CLAUDE.md"]
            for label in labels {
                do {
                    _ = try await optimize(
                        #"{"env":{"KEY":"SYNTHETIC_SECRET"},"hooks":{"command":"SYNTHETIC_PRIVATE_COMMAND"}}"#,
                        file: label, provider: provider
                    )
                    XCTFail("Settings must use deterministic checks")
                } catch AIOptimizerService.OptimizerError.settingsUseLocalChecks { }
            }
            let requests = await probe.messages
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testBothOnDeviceProvidersCanProposeInstructions() async throws {
        for kind in [AIProviderKind.appleIntelligence, .embeddedModel] {
            let probe = OptimizerRequestProbe()
            let provider = OptimizerFixtureProvider(kind: kind, response: validResponse, probe: probe)
            let result = try await optimize("SYNTHETIC_LOCAL_INSTRUCTIONS", provider: provider)
            XCTAssertEqual(result.proposed, "Run the documented tests. Keep safety checks.")
            XCTAssertTrue(result.changed)
            XCTAssertEqual(result.why, ["Removed a duplicate instruction."])
            let requests = await probe.messages
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(requests[0].contains("SYNTHETIC_LOCAL_INSTRUCTIONS"))
        }
    }

    func testIncompleteAmbiguousEmptyAndOversizedProposalsAreRefused() async throws {
        let responses = [
            "", "Looks optimal", "===THROTTLE-FILE===\npartial",
            "===THROTTLE-FILE===\n\n===THROTTLE-ENDFILE===\n===THROTTLE-WHY===\n- Empty",
            "===THROTTLE-FILE===\n```\n===THROTTLE-ENDFILE===\n===THROTTLE-WHY===\n- Incomplete fence",
            validResponse + validResponse, String(repeating: "x", count: 262_145)
        ]
        for response in responses {
            let provider = OptimizerFixtureProvider(response: response)
            do {
                _ = try await optimize("Original instructions", provider: provider)
                XCTFail("Malformed output must not become an unchanged/successful proposal")
            } catch AIOptimizerService.OptimizerError.invalidOutput { }
        }
    }

    func testUnchangedProposalPreservesOriginalWhitespace() async throws {
        let original = "Run the documented tests. Keep safety checks.\n\n"
        let result = try await optimize(original, provider: OptimizerFixtureProvider(response: validResponse))
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.proposed, original)
    }

    func testFailedStreamCannotPublishPartialProposalOrRetry() async throws {
        let probe = OptimizerRequestProbe()
        let provider = OptimizerFixtureProvider(response: validResponse, failAfterOutput: true, probe: probe)
        do {
            _ = try await optimize("Original", provider: provider)
            XCTFail("A failed stream must never deliver a proposal")
        } catch OptimizerFixtureProvider.Failure.interrupted { }
        let requests = await probe.messages
        XCTAssertEqual(requests.count, 1)
    }

    func testCancelledRequestDoesNotCallProvider() async throws {
        let probe = OptimizerRequestProbe()
        let provider = OptimizerFixtureProvider(response: validResponse, probe: probe)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AIOptimizerService.optimize(
                fileLabel: "CLAUDE.md", content: "Original", projectName: "Fixture",
                projectPath: nil, provider: provider
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled request must fail before streaming")
        } catch is CancellationError { }
        let requests = await probe.messages
        XCTAssertTrue(requests.isEmpty)
    }

    private func optimize(_ content: String, file: String = "CLAUDE.md",
                          provider: any AIProvider) async throws -> AIOptimizerService.Proposal {
        try await AIOptimizerService.optimize(fileLabel: file, content: content,
                                              projectName: "Fixture", projectPath: nil, provider: provider)
    }
}

private actor OptimizerRequestProbe {
    var messages: [String] = []
    func record(_ values: [ChatMessage]) { messages.append(values.map(\.content).joined(separator: "\n")) }
}

private struct OptimizerFixtureProvider: AIProvider {
    enum Failure: Error { case interrupted }
    var kind: AIProviderKind = .appleIntelligence
    let response: String
    var failAfterOutput = false
    var probe = OptimizerRequestProbe()
    let displayName = "Fixture model"
    var isAvailable: Bool { get async { true } }

    func streamChat(messages: [ChatMessage], context: ProjectChatContext) async throws
        -> AsyncThrowingStream<String, Error> {
        await probe.record(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(response)
            if failAfterOutput { continuation.finish(throwing: Failure.interrupted) } else { continuation.finish() }
        }
    }
}
