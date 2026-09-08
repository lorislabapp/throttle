import AppKit
import GRDB
@testable import Throttle
import XCTest

@MainActor
final class AppTestHostIsolationTests: XCTestCase {
    func testHostedDelegateUsesMigratedMemoryDatabaseWithoutLicense() throws {
        XCTAssertTrue(AppDelegate.isRunningTests)
        let delegate = AppDelegate()
        let paths = try delegate.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA database_list").map { row -> String in
                row["file"]
            }
        }
        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(paths.allSatisfy(\.isEmpty), "A test host must not open a persistent database")
        XCTAssertFalse(delegate.appState.isPro)
        let hasUsageTable = try delegate.database.read { try $0.tableExists("usage_events") }
        XCTAssertTrue(hasUsageTable)
    }

    func testWorkbenchTestHostHasNoProductionClientOrFolderMonitor() {
        let model = ResearchVaultWorkbenchModel()
        XCTAssertTrue(model.isIsolatedHost)
        XCTAssertNil(model.client)
        XCTAssertNil(model.folderMonitor)
        XCTAssertNil(model.inboxFolderName)
        XCTAssertTrue(model.savedViews.isEmpty)
        XCTAssertTrue(model.folderSources.isEmpty)
        XCTAssertEqual(model.serviceState, .disabled)
        XCTAssertEqual(model.spaces.map(\.id), ["portfolio", "project:cheatcode", "project:throttle"])
    }

    func testActivationKeepsPreviewStateAndCannotConnectInstalledServices() async {
        let model = ResearchVaultWorkbenchModel()
        model.serviceState = .requiresApproval
        await model.refreshAfterActivation()
        XCTAssertEqual(model.serviceState, .requiresApproval)
        XCTAssertNil(model.client)
        XCTAssertNil(model.folderMonitor)
    }
}
