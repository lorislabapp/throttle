@testable import Throttle
import XCTest

/// Any app or page can open a `throttle://` URL. These tests pin that a URL
/// alone only navigates; anything that changes state waits for the user.
final class DeepLinkRouteTests: XCTestCase {
    private func route(_ string: String) -> DeepLinkRoute {
        guard let url = URL(string: string) else { return .ignored(reason: "unparseable test URL") }
        return DeepLinkRoute.parse(url)
    }

    func test_sessionAndQuietCommands_requireConfirmation() {
        let expected: [String: ThrottleAction] = [
            "throttle://pause": .pauseAll,
            "throttle://resume": .resumeAll,
            "throttle://quiet": .quietOn,
            "throttle://unquiet": .quietOff,
            "THROTTLE://PAUSE": .pauseAll
        ]
        for (url, action) in expected {
            let parsed = route(url)
            XCTAssertEqual(parsed, .command(action), url)
            XCTAssertTrue(parsed.requiresConfirmation, url)
            XCTAssertNotNil(parsed.confirmationPrompt, url)
        }
    }

    func test_licenceActivation_requiresConfirmationAndMasksTheKey() {
        let parsed = route("throttle://activate?key=throttle-abcd-efgh-ijkl-mnop")
        XCTAssertEqual(parsed, .activate(key: "THROTTLE-ABCD-EFGH-IJKL-MNOP"))
        XCTAssertTrue(parsed.requiresConfirmation)
        let prompt = parsed.confirmationPrompt ?? ""
        XCTAssertTrue(prompt.contains("THROTTLE-…-MNOP"))
        XCTAssertFalse(prompt.contains("ABCD"))
    }

    func test_navigationRoutes_runWithoutConfirmation() {
        XCTAssertEqual(route("throttle://cockpit"), .cockpit)
        XCTAssertEqual(route("throttle://research-vault"), .researchVault(connectLibrary: false))
        XCTAssertEqual(route("throttle://research-vault/library"), .researchVault(connectLibrary: true))
        for url in ["throttle://cockpit", "throttle://research-vault", "throttle://research-vault/library"] {
            XCTAssertFalse(route(url).requiresConfirmation, url)
            XCTAssertNil(route(url).confirmationPrompt, url)
        }
    }

    func test_unknownOrMalformedURLs_areIgnored() {
        for url in [
            "https://pause",
            "throttle://delete-everything",
            "throttle://activate",
            "throttle://activate?key=NOT-A-KEY",
            "throttle://"
        ] {
            guard case .ignored = route(url) else { return XCTFail("\(url) should be ignored") }
            XCTAssertFalse(route(url).requiresConfirmation, url)
        }
    }

    func test_everyStateChangingRouteHasAPrompt() {
        let routes: [DeepLinkRoute] = [
            .activate(key: "THROTTLE-A-B-C-D"),
            .command(.pauseAll), .command(.resumeAll), .command(.quietOn), .command(.quietOff),
            .cockpit, .researchVault(connectLibrary: true), .ignored(reason: "x")
        ]
        for candidate in routes {
            XCTAssertEqual(candidate.requiresConfirmation, candidate.confirmationPrompt != nil, "\(candidate)")
        }
    }
}
