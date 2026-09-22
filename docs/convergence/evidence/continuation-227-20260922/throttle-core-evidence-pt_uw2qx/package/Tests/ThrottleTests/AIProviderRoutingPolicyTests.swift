@testable import Throttle
import XCTest

final class AIProviderRoutingPolicyTests: XCTestCase {
    private let cloud: Set<AIProviderKind> = [.claudeWebSession, .claudeAPIKey]
    private let network: Set<AIProviderKind> = [.selfHostedModel, .claudeWebSession, .claudeAPIKey]

    func testUntouchedPreferenceNeverUsesConfiguredCloudCredentials() {
        let candidates = AIProviderRoutingPolicy.initialCandidates(preferred: nil)
        XCTAssertEqual(candidates, [.appleIntelligence, .embeddedModel])
        XCTAssertNil(candidates.first(where: cloud.contains))
    }

    func testUnavailableExplicitChoiceDoesNotSwitchProviders() {
        for preferred in AIProviderKind.allCases {
            let available = Set(AIProviderKind.allCases.filter { $0 != preferred })
            let candidates = AIProviderRoutingPolicy.initialCandidates(preferred: preferred)
            XCTAssertEqual(candidates, [preferred])
            XCTAssertNil(candidates.first(where: available.contains), "Unexpected fallback for \(preferred)")
        }
    }

    func testAvailableExplicitChoiceIsUsedEvenWhenEveryOtherProviderIsAvailable() {
        for preferred in AIProviderKind.allCases {
            XCTAssertEqual(AIProviderRoutingPolicy.initialCandidates(preferred: preferred).first, preferred)
        }
    }

    func testLocalFailureCannotEscalateEvenIfPreferenceChangesToCloudDuringTurn() {
        for failed in [AIProviderKind.appleIntelligence, .embeddedModel] {
            for currentPreference in AIProviderKind.allCases {
                let candidates = AIProviderRoutingPolicy.fallbackCandidates(
                    preferred: currentPreference, excluding: [failed]
                )
                XCTAssertFalse(candidates.contains(failed))
                XCTAssertTrue(Set(candidates).isDisjoint(with: network))
            }
        }
    }

    func testCloudFailureCannotChangeProviderOrSpendAnotherAccount() {
        for failed in cloud {
            for currentPreference in AIProviderKind.allCases {
                let candidates = AIProviderRoutingPolicy.fallbackCandidates(
                    preferred: currentPreference, excluding: [failed]
                )
                XCTAssertEqual(candidates, [.appleIntelligence, .embeddedModel])
            }
        }
    }

    func testForceLocalRefinerExclusionsRemainEffectiveWithCloudPreference() {
        for preferred in cloud {
            let candidates = AIProviderRoutingPolicy.fallbackCandidates(
                preferred: preferred, excluding: cloud
            )
            XCTAssertEqual(candidates, [.appleIntelligence, .embeddedModel])
            XCTAssertTrue(AIProviderRoutingPolicy.fallbackCandidates(
                preferred: preferred, excluding: Set(AIProviderKind.allCases)
            ).isEmpty)
        }
    }

    func testAvailabilityMatrixCannotReviveAnExcludedOrUnselectedCloudProvider() {
        let kinds = AIProviderKind.allCases
        for mask in 0..<(1 << kinds.count) {
            let available = Set(kinds.enumerated().compactMap { index, kind in
                mask & (1 << index) == 0 ? nil : kind
            })
            for failed in kinds {
                let candidates = AIProviderRoutingPolicy.fallbackCandidates(
                    preferred: .claudeAPIKey, excluding: [failed]
                )
                if let selected = candidates.first(where: available.contains) {
                    XCTAssertNotEqual(selected, failed)
                    XCTAssertFalse(network.contains(selected))
                }
            }
        }
    }

    func testNoAttemptsAllowsOnlyExplicitCloudAlongsideLocalCandidates() {
        for preferred in cloud {
            let candidates = AIProviderRoutingPolicy.fallbackCandidates(preferred: preferred, excluding: [])
            XCTAssertEqual(Set(candidates).intersection(cloud), [preferred])
        }
        XCTAssertEqual(AIProviderRoutingPolicy.fallbackCandidates(preferred: nil, excluding: []),
                       [.appleIntelligence, .embeddedModel])
    }
    func testServerIsNeverAnImplicitDefaultOrFallback() {
        XCTAssertFalse(AIProviderRoutingPolicy.initialCandidates(preferred: nil).contains(.selfHostedModel))
        for failed in AIProviderKind.allCases {
            XCTAssertFalse(AIProviderRoutingPolicy.fallbackCandidates(
                preferred: .selfHostedModel, excluding: [failed]
            ).contains(.selfHostedModel))
        }
    }

    func testServerChoiceIsExactAndUnavailableServerDoesNotSelectEmbeddedProvider() {
        let candidates = AIProviderRoutingPolicy.initialCandidates(preferred: .selfHostedModel)
        XCTAssertEqual(candidates, [.selfHostedModel])
        XCTAssertEqual(candidates.first(where: { $0 == .selfHostedModel }), .selfHostedModel)
        let onlyEmbeddedAvailable: Set<AIProviderKind> = [.embeddedModel]
        XCTAssertNil(candidates.first(where: onlyEmbeddedAvailable.contains))
    }

    func testForceLocalRefinerNeverSelectsServerEvenWhenPreferred() {
        let candidates = AIProviderRoutingPolicy.fallbackCandidates(preferred: .selfHostedModel, excluding: cloud)
        XCTAssertEqual(candidates, [.appleIntelligence, .embeddedModel])
    }

}
