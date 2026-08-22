import Foundation
import os

/// Deletes what Throttle keeps and no longer needs.
///
/// Measured 2026-08-22 on this Mac, while the disk hit **zero bytes free twice
/// in one day**:
///
/// ```
/// semindex             3.0 GB   46 per-repo indexes, none ever removed
/// throttle-backups     372 MB   9 transcript backups, all older than 30 days
/// transcript-index.db  209 MB
/// usage.db             204 MB
/// ```
///
/// Nothing in the codebase deleted any of it. The tool that reports memory
/// pressure and swap was itself holding ~3.8 GB of never-expiring caches, and
/// the oldest trim backup dated from 2 June.
///
/// Two rules, both conservative:
///   • a trim backup exists to undo a trim; its usefulness is measured in days,
///     not months, so anything past the window goes;
///   • a semantic index for a repository that no longer exists on disk cannot be
///     searched, so it is dead weight by definition.
///
/// Nothing here touches data that could still be wanted: indexes for live repos
/// stay whatever their size, and recent backups stay whatever their age.
enum RetentionService {

    private static let log = Logger(subsystem: "com.lorislab.throttle", category: "retention")

    /// How long a trim backup stays useful. Long enough to notice a bad trim and
    /// undo it; short enough that months of them do not fill the disk.
    static let backupRetentionDays = 14

    struct Result: Sendable, Equatable {
        var backupsDeleted = 0
        var indexesDeleted = 0
        var bytesReclaimed = 0

        var isEmpty: Bool { backupsDeleted == 0 && indexesDeleted == 0 }
    }

    /// Sweep now, then once a day for as long as the app runs.
    ///
    /// This used to be a single call at launch. Throttle is a menu-bar app that
    /// stays open for weeks, so on the Mac where the disk hit zero twice in one
    /// day the sweep had last run three weeks earlier — the cleanup existed and
    /// was almost never reached.
    static func startPeriodicSweeps() {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                sweep()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    /// Run both sweeps. Never throws: reclaiming disk is best-effort, and a
    /// failure here must not take anything else down with it.
    @discardableResult
    static func sweep(now: Date = Date()) -> Result {
        var result = Result()
        result.bytesReclaimed += pruneTrimBackups(now: now, into: &result)
        result.bytesReclaimed += pruneOrphanIndexes(into: &result)
        if !result.isEmpty {
            log.info("retention: freed \(result.bytesReclaimed / 1_048_576, privacy: .public) MB")
        }
        return result
    }

    // MARK: - Trim backups

    private static var backupsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/throttle-backups", isDirectory: true)
    }

    private static func pruneTrimBackups(now: Date, into result: inout Result) -> Int {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return 0 }

        let cutoff = now.addingTimeInterval(-Double(backupRetentionDays) * 86_400)
        var freed = 0
        for url in entries where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            let size = values.fileSize ?? 0
            guard (try? files.removeItem(at: url)) != nil else { continue }
            freed += size
            result.backupsDeleted += 1
        }
        return freed
    }

    // MARK: - Semantic indexes

    private static var indexRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle/semindex", isDirectory: true)
    }

    /// Remove indexes whose repository is gone.
    ///
    /// Each index directory is named after a hash of the repo's absolute path, so
    /// the path itself is not recoverable from the name — the manifest inside
    /// carries it. An index we cannot resolve to a path is LEFT ALONE: deleting
    /// on "I could not tell" is how a retention sweep becomes data loss.
    private static func pruneOrphanIndexes(into result: inout Result) -> Int {
        let files = FileManager.default
        guard let dirs = try? files.contentsOfDirectory(at: indexRoot, includingPropertiesForKeys: nil)
        else { return 0 }

        var freed = 0
        for dir in dirs {
            guard let repoPath = repoPath(ofIndexAt: dir) else { continue }
            guard !files.fileExists(atPath: repoPath) else { continue }
            let size = directorySize(dir)
            guard (try? files.removeItem(at: dir)) != nil else { continue }
            freed += size
            result.indexesDeleted += 1
            log.info("retention: dropped index for missing repo")
        }
        return freed
    }

    /// The repo path recorded inside an index directory, if it says.
    private static func repoPath(ofIndexAt dir: URL) -> String? {
        for name in ["manifest.json", "corpus.json", "meta.json"] {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for key in ["repoPath", "repo_path", "root", "path"] {
                if let value = object[key] as? String, value.hasPrefix("/") { return value }
            }
        }
        return nil
    }

    private static func directorySize(_ dir: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
