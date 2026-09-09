import Foundation

/// One-line summaries the Workbench shows beside a source or a notebook. Pure
/// text, deliberately not on the view: they are what the tests assert, and a
/// sentence a reader relies on should not need a window to exist.
enum ResearchVaultStandingText {
    /// What a source is worth to the vault: how many claims rest on it, and
    /// whether it still reads as it did when they were made.
    static func source(claims: Int, hasMoved: Bool) -> String {
        let rest = claims == 0
            ? String(localized: "No claim rests on it")
            : String(localized: "\(claims) claim(s) rest on it")
        return hasMoved ? rest + " · " + String(localized: "content changed since") : rest
    }

    /// What sync has actually done for a notebook — never more than that.
    static func sync(_ record: ResearchVaultNotebookSyncRecord?) -> String {
        guard let record else { return String(localized: "Not synced") }
        guard let last = record.lastSyncedAt else { return String(localized: "On — never run yet") }
        let when = last.formatted(date: .abbreviated, time: .shortened)
        guard let count = record.lastSourceCount else { return String(localized: "On — last run \(when)") }
        return String(localized: "On — \(count) source(s) at \(when)")
    }
}
