import Foundation
import Testing
@testable import Throttle

@Suite("NotebookLM per-notebook sync opt-in")
struct ResearchVaultNotebookSyncTests {
    private func defaults() throws -> UserDefaults {
        let suite = "throttle.tests." + UUID().uuidString
        return try #require(UserDefaults(suiteName: suite))
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notebook-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("enabling remembers the folder, disabling forgets it entirely")
    func toggle() throws {
        let staging = try folder()
        defer { try? FileManager.default.removeItem(at: staging) }

        let enabled = try ResearchVaultNotebookSyncStore.setting(
            true, notebookID: "nb-1", title: "Research", folder: staging, in: []
        )
        #expect(enabled.count == 1)
        let record = try #require(enabled.first)
        #expect(record.notebookID == "nb-1")
        #expect(!record.stagingBookmark.isEmpty)
        #expect(record.lastSyncedAt == nil, "a fresh opt-in has not run")
        #expect(try ResearchVaultNotebookSyncStore.stagingFolder(for: record)
            .resolvingSymlinksInPath() == staging.resolvingSymlinksInPath())

        let disabled = try ResearchVaultNotebookSyncStore.setting(
            false, notebookID: "nb-1", title: "Research", folder: nil, in: enabled
        )
        #expect(disabled.isEmpty, "a notebook that is off holds no path to anywhere")
    }

    @Test("enabling without a folder is refused rather than defaulting somewhere")
    func requiresFolder() {
        #expect(throws: ResearchVaultNotebookSyncStore.StoreError.staleBookmark("nb-1")) {
            try ResearchVaultNotebookSyncStore.setting(
                true, notebookID: "nb-1", title: "Research", folder: nil, in: []
            )
        }
    }

    @Test("history survives a re-enable, and the list stays bounded and unique")
    func persistence() throws {
        let staging = try folder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let store = try defaults()

        var records = try ResearchVaultNotebookSyncStore.setting(
            true, notebookID: "nb-1", title: "Research", folder: staging, in: []
        )
        records[0].lastSyncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        records[0].lastSourceCount = 12
        try ResearchVaultNotebookSyncStore.save(records, defaults: store)
        let loaded = ResearchVaultNotebookSyncStore.load(defaults: store)
        #expect(loaded.first?.lastSourceCount == 12)

        let again = try ResearchVaultNotebookSyncStore.setting(
            true, notebookID: "nb-1", title: "Renamed", folder: staging, in: loaded
        )
        #expect(again.count == 1, "the same notebook is never listed twice")
        #expect(again.first?.title == "Renamed")
        #expect(again.first?.lastSourceCount == 12, "re-enabling keeps what the last run reported")

        let many = try (0 ..< ResearchVaultNotebookSyncStore.maximumNotebooks).reduce(
            into: [ResearchVaultNotebookSyncRecord]()
        ) { list, index in
            list = try ResearchVaultNotebookSyncStore.setting(
                true, notebookID: "nb-\(index)", title: "N\(index)", folder: staging, in: list
            )
        }
        #expect(many.count == ResearchVaultNotebookSyncStore.maximumNotebooks)
        #expect(throws: ResearchVaultNotebookSyncStore.StoreError.tooManyNotebooks) {
            try ResearchVaultNotebookSyncStore.setting(
                true, notebookID: "one-too-many", title: "Extra", folder: staging, in: many
            )
        }
    }

    @Test("the row says what sync has actually done, never more")
    func standing() {
        #expect(ResearchVaultStandingText.sync(nil) == "Not synced")
        let never = ResearchVaultNotebookSyncRecord(
            notebookID: "nb", title: "N", stagingBookmark: Data([1]),
            lastSyncedAt: nil, lastSourceCount: nil
        )
        #expect(ResearchVaultStandingText.sync(never) == "On — never run yet")
        let ran = ResearchVaultNotebookSyncRecord(
            notebookID: "nb", title: "N", stagingBookmark: Data([1]),
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000), lastSourceCount: 7
        )
        #expect(ResearchVaultStandingText.sync(ran).contains("7 source(s)"))
    }
}
