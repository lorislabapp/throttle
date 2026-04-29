import Foundation

/// Atomic file editing with backup + post-write verification + rollback.
/// Every write the user applies through the Optimizer tab passes through
/// this actor — never `String.write(to:)` directly. The contract:
///
///   1. Read the URL's current bytes (return error if missing).
///   2. Stage `<url>.bak.<unix-ts>` next to the original.
///   3. Atomic-replace the original with the new contents.
///   4. Read it back and verify byte-equality with what we wrote.
///   5. On verify mismatch: copy the .bak back over the original
///      and surface a `verificationFailed` error.
///
/// Backups also land in
/// `~/Library/Application Support/com.lorislab.throttle/backups/<encoded>/`
/// so the user has a single recovery folder even if their project lives
/// on an external volume that gets unmounted. Backups are GC'd after
/// 30 days by `pruneOldBackups()`.
actor FileEditor {
    static let shared = FileEditor()

    enum FileEditError: LocalizedError {
        case sourceMissing(URL)
        case verificationFailed(URL)
        case rollbackFailed(URL, underlying: Error)
        case writeFailed(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "File not found: \(url.lastPathComponent)"
            case .verificationFailed(let url):
                return "Wrote \(url.lastPathComponent), but the bytes on disk didn't match what we sent. Restored from backup."
            case .rollbackFailed(let url, let err):
                return "Failed to restore \(url.lastPathComponent) after a verify mismatch: \(err.localizedDescription)"
            case .writeFailed(let url, let err):
                return "Failed to write \(url.lastPathComponent): \(err.localizedDescription)"
            }
        }
    }

    struct EditResult: Sendable {
        let writtenURL: URL
        let backupURL: URL
        let timestamp: Date
    }

    /// Apply the new content. Returns the backup URL so the UI can offer
    /// "Rollback" until the user closes the window.
    func write(_ url: URL, contents: String) async throws -> EditResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw FileEditError.sourceMissing(url)
        }
        let timestamp = Date()
        let stamp = String(Int(timestamp.timeIntervalSince1970))
        let inlineBackup = url.appendingPathExtension("bak.\(stamp)")
        let centralBackup = try centralBackupURL(for: url, stamp: stamp)

        do {
            try fm.copyItem(at: url, to: inlineBackup)
            try? fm.copyItem(at: url, to: centralBackup)
        } catch {
            // Without a backup we refuse to write — this is the safety
            // contract the user agreed to via the Optimizer tab.
            throw FileEditError.writeFailed(url, underlying: error)
        }

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw FileEditError.writeFailed(url, underlying: error)
        }

        let written: String
        do {
            written = try String(contentsOf: url, encoding: .utf8)
        } catch {
            try? rollback(from: inlineBackup, to: url, fm: fm)
            throw FileEditError.verificationFailed(url)
        }
        guard written == contents else {
            do {
                try rollback(from: inlineBackup, to: url, fm: fm)
                throw FileEditError.verificationFailed(url)
            } catch {
                throw FileEditError.rollbackFailed(url, underlying: error)
            }
        }
        return EditResult(writtenURL: url, backupURL: inlineBackup, timestamp: timestamp)
    }

    /// User-triggered rollback from a previously-stashed `.bak` file.
    func rollback(_ backupURL: URL, to original: URL) throws {
        try rollback(from: backupURL, to: original, fm: FileManager.default)
    }

    private func rollback(from backupURL: URL, to original: URL, fm: FileManager) throws {
        if fm.fileExists(atPath: original.path) {
            try fm.removeItem(at: original)
        }
        try fm.copyItem(at: backupURL, to: original)
    }

    /// 30-day GC of central backups. Run from app launch (best-effort).
    func pruneOldBackups(olderThan days: Int = 30) {
        let fm = FileManager.default
        guard let root = try? centralRoot() else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if mtime < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    private func centralRoot() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support
            .appendingPathComponent("com.lorislab.throttle", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func centralBackupURL(for original: URL, stamp: String) throws -> URL {
        let root = try centralRoot()
        let safeName = original.path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return root.appendingPathComponent("\(safeName).\(stamp)")
    }
}
