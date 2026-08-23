@testable import Throttle
import XCTest

final class HealthCheckServiceTests: XCTestCase {
    func testTrackingOldEventIsHealthyWhenTranscriptOffsetsAreCaughtUp() {
        let now = Date(timeIntervalSince1970: 200_000)
        let item = HealthCheckService.trackingItem(
            snapshot: UsageTrackingSnapshot(
                lastEvent: 20_000,
                sourceFileCount: 4,
                pendingFileCount: 0,
                newestSourceMtime: 199_000
            ),
            now: now
        )

        XCTAssertEqual(item.status, .ok)
        XCTAssertFalse(item.detail.isEmpty)
    }

    func testTrackingFailsOnlyWhenTranscriptBytesRemainPending() {
        let now = Date(timeIntervalSince1970: 200_000)
        let item = HealthCheckService.trackingItem(
            snapshot: UsageTrackingSnapshot(
                lastEvent: 20_000,
                sourceFileCount: 4,
                pendingFileCount: 2,
                newestSourceMtime: 190_000
            ),
            now: now
        )

        XCTAssertEqual(item.status, .fail)
        XCTAssertTrue(item.detail.contains("2"))
    }

    func testTrackingAllowsARecentWriteToSettle() {
        let now = Date(timeIntervalSince1970: 200_000)
        let item = HealthCheckService.trackingItem(
            snapshot: UsageTrackingSnapshot(
                lastEvent: 199_900,
                sourceFileCount: 1,
                pendingFileCount: 1,
                newestSourceMtime: 199_950
            ),
            now: now
        )

        XCTAssertEqual(item.status, .warn)
        XCTAssertTrue(item.detail.contains("1"))
    }

    func testOrphanClassifierRejectsUnrelatedNodeDaemons() {
        let processList = """
          101     1 /opt/homebrew/bin/node /srv/index.js
          102     1 /opt/homebrew/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js
          103     1 /Users/test/.local/share/claude/versions/2.1.0/claude
          104    22 /usr/local/bin/claude
        """

        XCTAssertEqual(HealthCheckService.orphanedClaudePIDs(from: processList), [102, 103])
    }

    func testCriticalCockpitLabelsHaveFrenchRuntimeTranslations() {
        let french = Locale(identifier: "fr")
        let expected: [(String.LocalizationValue, String)] = [
            ("Dashboard", "Tableau de bord"),
            ("Tabs", "Onglets"),
            ("Overview", "Vue d’ensemble"),
            ("Portfolio", "Portefeuille"),
            ("Keep Mac awake", "Garder le Mac éveillé"),
            ("Throttle Health", "État de Throttle"),
            ("Claude Code setup", "Configuration de Claude Code"),
            ("Usage tracking", "Suivi de l’utilisation"),
            ("Mission runtime", "Moteur d’exécution de mission"),
            ("Sort sessions", "Trier les sessions"),
            ("Terminal theme", "Thème du terminal"),
            ("On", "Activé"),
            ("Off", "Désactivé")
        ]

        for (key, translation) in expected {
            XCTAssertEqual(String(localized: key, locale: french), translation)
        }
    }
}
