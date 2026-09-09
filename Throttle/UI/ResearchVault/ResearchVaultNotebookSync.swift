import Foundation

/// A per-notebook opt-in to re-run the NotebookLM export. Sync is never
/// implicit: a notebook syncs only while its own toggle is on, and what comes
/// back lands in quarantine like any other import.
///
/// The record keeps a security-scoped bookmark to the staging folder the reader
/// chose, so a later sync writes exactly where the first import did instead of
/// asking again — and cannot wander somewhere else.
struct ResearchVaultNotebookSyncRecord: Codable, Equatable, Identifiable {
    var id: String { notebookID }
    let notebookID: String
    var title: String
    var stagingBookmark: Data
    var lastSyncedAt: Date?
    /// Sources the last completed sync saw, so a reader can tell a quiet
    /// notebook from one that has never run.
    var lastSourceCount: Int?
}

enum ResearchVaultNotebookSyncStore {
    private static let key = "researchVault.notebookSync.v1"
    /// A person curates a handful of notebooks; a runaway list would turn one
    /// gesture into an unbounded amount of network work.
    static let maximumNotebooks = 24

    enum StoreError: Error, Equatable {
        case tooManyNotebooks
        case staleBookmark(String)
    }

    static func load(defaults: UserDefaults = .standard) -> [ResearchVaultNotebookSyncRecord] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([ResearchVaultNotebookSyncRecord].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return values.filter { seen.insert($0.notebookID).inserted }.prefix(maximumNotebooks).map { $0 }
    }

    static func save(
        _ values: [ResearchVaultNotebookSyncRecord],
        defaults: UserDefaults = .standard
    ) throws {
        guard values.count <= maximumNotebooks else { throw StoreError.tooManyNotebooks }
        var seen = Set<String>()
        let unique = values.filter { seen.insert($0.notebookID).inserted }
        defaults.set(try JSONEncoder().encode(unique), forKey: key)
    }

    /// Turning sync on records the folder; turning it off forgets it entirely,
    /// so a notebook that is off holds no path to anywhere on this Mac.
    static func setting(
        _ enabled: Bool, notebookID: String, title: String, folder: URL?,
        in values: [ResearchVaultNotebookSyncRecord]
    ) throws -> [ResearchVaultNotebookSyncRecord] {
        var next = values.filter { $0.notebookID != notebookID }
        guard enabled else { return next }
        guard let folder else { throw StoreError.staleBookmark(notebookID) }
        guard next.count < maximumNotebooks else { throw StoreError.tooManyNotebooks }
        let bookmark = try folder.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let previous = values.first { $0.notebookID == notebookID }
        next.append(ResearchVaultNotebookSyncRecord(
            notebookID: notebookID, title: title, stagingBookmark: bookmark,
            lastSyncedAt: previous?.lastSyncedAt, lastSourceCount: previous?.lastSourceCount
        ))
        return next.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Resolves the remembered folder. A bookmark that no longer points
    /// anywhere is refused rather than silently replaced by a default: the
    /// reader chose that folder, and sync must not write elsewhere.
    static func stagingFolder(for record: ResearchVaultNotebookSyncRecord) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: record.stagingBookmark, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        guard !stale else { throw StoreError.staleBookmark(record.notebookID) }
        return url
    }
}
