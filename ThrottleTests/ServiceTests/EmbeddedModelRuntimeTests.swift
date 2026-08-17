import XCTest
@testable import Throttle

final class EmbeddedModelRuntimeTests: XCTestCase {
    func testModelMetadataIsPinnedToHTTPS() {
        XCTAssertEqual(EmbeddedModelRuntime.modelID, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(EmbeddedModelRuntime.modelURL.scheme, "https")
        XCTAssertEqual(EmbeddedModelRuntime.modelURL.host, "huggingface.co")
    }

    func testEndToEndInferenceWhenExplicitlyEnabled() async throws {
        let explicitFlag = ProcessInfo.processInfo.environment["THROTTLE_RUN_EMBEDDED_MODEL_TEST"] == "1"
            || FileManager.default.fileExists(atPath: "/private/tmp/throttle-run-embedded-model-test")
        guard explicitFlag else {
            throw XCTSkip("Set THROTTLE_RUN_EMBEDDED_MODEL_TEST=1 for the 968 MB model download and live MLX inference test.")
        }

        try await EmbeddedModelRuntime.shared.install { _ in }
        let context = ProjectChatContext(
            projectName: "Embedded model acceptance",
            projectPath: nil,
            claudeMd: nil,
            settingsJSON: nil,
            weeklyTokens: 0,
            modelSplit: [],
            hookScripts: [:],
            mcpServers: [],
            costEUR: 0
        )
        let provider = EmbeddedModelProvider()
        let stream = try await provider.streamChat(
            messages: [ChatMessage(role: .user, content: "Reply with one short sentence confirming local inference works.")],
            context: context
        )

        var response = ""
        for try await chunk in stream {
            response += chunk
            if response.count >= 20 { break }
        }
        XCTAssertFalse(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
