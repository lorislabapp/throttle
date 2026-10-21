@testable import Throttle
import XCTest

/// Throttle uses only the AI provider the user explicitly chose. These tests
/// pin that it never picks one itself or switches to another (2026-10-21
/// audit: silent cloud fallback).
final class AIProviderSelectionTests: XCTestCase {
    func test_noChoice_isReportedNotDefaulted() {
        for available in [true, false] {
            XCTAssertEqual(
                AIProviderSelection.resolve(preferred: nil, preferredIsAvailable: available),
                .notChosen
            )
        }
        XCTAssertNotNil(AIProviderSelection.notChosen.message)
    }

    func test_availableChoice_isUsedAsIs() {
        for kind in AIProviderKind.allCases {
            XCTAssertEqual(
                AIProviderSelection.resolve(preferred: kind, preferredIsAvailable: true),
                .ready(kind)
            )
        }
        XCTAssertNil(AIProviderSelection.ready(.claudeAPIKey).message)
    }

    func test_unavailableChoice_isReportedNeverSwitched() {
        for kind in AIProviderKind.allCases {
            XCTAssertEqual(
                AIProviderSelection.resolve(preferred: kind, preferredIsAvailable: false),
                .chosenUnavailable(kind)
            )
        }
        let message = AIProviderSelection.chosenUnavailable(.claudeWebSession).message ?? ""
        XCTAssertTrue(message.contains("Claude (claude.ai)"))
        XCTAssertTrue(message.contains("won't switch"))
    }

    func test_localOnly_rejectsANetworkChoiceInsteadOfSwappingToLocal() {
        for kind in [AIProviderKind.claudeWebSession, .claudeAPIKey] {
            XCTAssertEqual(
                AIProviderSelection.resolve(preferred: kind, preferredIsAvailable: true, localOnly: true),
                .chosenNotLocal(kind)
            )
        }
        XCTAssertEqual(
            AIProviderSelection.resolve(preferred: .embeddedModel, preferredIsAvailable: true, localOnly: true),
            .ready(.embeddedModel)
        )
        XCTAssertEqual(
            AIProviderSelection.resolve(preferred: .appleIntelligence, preferredIsAvailable: false, localOnly: true),
            .chosenUnavailable(.appleIntelligence)
        )
        XCTAssertEqual(AIProviderSelection.localKinds, [.appleIntelligence, .embeddedModel])
    }

    func test_noCallerWalksAProviderChain() throws {
        // The silent-fallback entry point must not come back.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in [
            "Throttle/Services/AIProviderRegistry.swift",
            "Throttle/Services/AIOptimizerService.swift",
            "Throttle/Services/PromptRefinerService.swift",
            "Throttle/UI/ProjectWindow/ProjectAssistantTab.swift"
        ] {
            let path = root.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw XCTSkip("Source inspection requires the checkout")
            }
            let source = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertFalse(source.contains("firstAvailable"), file)
        }
    }
}
